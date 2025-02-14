// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/type_inference/nullability_suffix.dart'
    show NullabilitySuffix;
import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer_operations.dart'
    as shared
    show
        TypeConstraintGenerator,
        TypeConstraintGeneratorMixin,
        TypeConstraintGeneratorState;
import 'package:_fe_analyzer_shared/src/types/shared_type.dart';
import 'package:kernel/ast.dart';
import 'package:kernel/type_algebra.dart';

import 'type_inference_engine.dart';
import 'type_schema.dart';
import 'type_schema_environment.dart';

/// Creates a collection of [TypeConstraint]s corresponding to type parameters,
/// based on an attempt to make one type schema a subtype of another.
class TypeConstraintGatherer extends shared.TypeConstraintGenerator<
        DartType,
        NamedType,
        VariableDeclaration,
        StructuralParameter,
        TypeDeclarationType,
        TypeDeclaration,
        TreeNode>
    with
        shared.TypeConstraintGeneratorMixin<
            DartType,
            NamedType,
            VariableDeclaration,
            StructuralParameter,
            TypeDeclarationType,
            TypeDeclaration,
            TreeNode> {
  final List<GeneratedTypeConstraint> _protoConstraints = [];

  final List<StructuralParameter> _parametersToConstrain;

  final OperationsCfe typeOperations;

  final TypeSchemaEnvironment _environment;

  final TypeInferenceResultForTesting? _inferenceResultForTesting;

  TypeConstraintGatherer(
      this._environment, Iterable<StructuralParameter> typeParameters,
      {required OperationsCfe typeOperations,
      required TypeInferenceResultForTesting? inferenceResultForTesting,
      required super.inferenceUsingBoundsIsEnabled})
      : typeOperations = typeOperations,
        _parametersToConstrain =
            new List<StructuralParameter>.of(typeParameters),
        _inferenceResultForTesting = inferenceResultForTesting;

  @override
  bool get enableDiscrepantObliviousnessOfNullabilitySuffixOfFutureOr => true;

  @override
  shared.TypeConstraintGeneratorState get currentState {
    return new shared.TypeConstraintGeneratorState(_protoConstraints.length);
  }

  @override
  void restoreState(shared.TypeConstraintGeneratorState state) {
    _protoConstraints.length = state.count;
  }

  @override
  OperationsCfe get typeAnalyzerOperations => typeOperations;

  @override
  (DartType, DartType, {List<StructuralParameter> typeParametersToEliminate})
      instantiateFunctionTypesAndProvideFreshTypeParameters(
          covariant FunctionType p, covariant FunctionType q,
          {required bool leftSchema}) {
    FunctionType instantiatedP;
    FunctionType instantiatedQ;
    if (leftSchema) {
      List<DartType> typeParametersForAlphaRenaming =
          new List<DartType>.generate(
              p.typeFormals.length,
              (int i) => new StructuralParameterType.forAlphaRenaming(
                  q.typeParameters[i], p.typeParameters[i]));
      instantiatedP = p.withoutTypeParameters;
      instantiatedQ = FunctionTypeInstantiator.instantiate(
          q, typeParametersForAlphaRenaming);
    } else {
      // Coverage-ignore-block(suite): Not run.
      List<DartType> typeParametersForAlphaRenaming =
          new List<DartType>.generate(
              p.typeFormals.length,
              (int i) => new StructuralParameterType.forAlphaRenaming(
                  p.typeParameters[i], q.typeParameters[i]));
      instantiatedP = FunctionTypeInstantiator.instantiate(
          p, typeParametersForAlphaRenaming);
      instantiatedQ = q.withoutTypeParameters;
    }

    return (
      instantiatedP,
      instantiatedQ,
      typeParametersToEliminate: leftSchema
          ? p.typeParameters
          :
          // Coverage-ignore(suite): Not run.
          q.typeParameters
    );
  }

  @override
  void eliminateTypeParametersInGeneratedConstraints(
      covariant List<StructuralParameter> typeParametersToEliminate,
      shared.TypeConstraintGeneratorState eliminationStartState,
      {required TreeNode? astNodeForTesting}) {
    List<GeneratedTypeConstraint> constraints =
        _protoConstraints.sublist(eliminationStartState.count);
    _protoConstraints.length = eliminationStartState.count;
    for (GeneratedTypeConstraint constraint in constraints) {
      if (constraint.isUpper) {
        addUpperConstraintForParameter(
            constraint.typeParameter,
            typeOperations.leastClosureOfTypeInternal(
                constraint.constraint.unwrapTypeSchemaView(),
                typeParametersToEliminate),
            nodeForTesting: astNodeForTesting);
      } else {
        addLowerConstraintForParameter(
            constraint.typeParameter,
            typeOperations.greatestClosureOfTypeInternal(
                constraint.constraint.unwrapTypeSchemaView(),
                typeParametersToEliminate),
            nodeForTesting: astNodeForTesting);
      }
    }
  }

  /// Applies all the argument constraints implied by trying to make
  /// [actualTypes] assignable to [formalTypes].
  void constrainArguments(
      List<DartType> formalTypes, List<DartType> actualTypes,
      {required TreeNode? treeNodeForTesting}) {
    assert(formalTypes.length == actualTypes.length);
    for (int i = 0; i < formalTypes.length; i++) {
      // Try to pass each argument to each parameter, recording any type
      // parameter bounds that were implied by this assignment.
      tryConstrainLower(formalTypes[i], actualTypes[i],
          treeNodeForTesting: treeNodeForTesting);
    }
  }

  // Coverage-ignore(suite): Not run.
  Member? getInterfaceMember(Class class_, Name name, {bool setter = false}) {
    return _environment.hierarchy
        .getInterfaceMember(class_, name, setter: setter);
  }

  @override
  List<DartType>? getTypeArgumentsAsInstanceOf(
      TypeDeclarationType type, TypeDeclaration typeDeclaration) {
    return _environment.getTypeArgumentsAsInstanceOf(type, typeDeclaration);
  }

  /// Returns the set of type constraints that was gathered.
  Map<StructuralParameter, MergedTypeConstraint> computeConstraints() {
    Map<StructuralParameter, MergedTypeConstraint> result = {};
    for (StructuralParameter parameter in _parametersToConstrain) {
      result[parameter] = new MergedTypeConstraint(
          lower: new SharedTypeSchemaView(const UnknownType()),
          upper: new SharedTypeSchemaView(const UnknownType()),
          origin: const UnknownTypeConstraintOrigin());
    }
    for (GeneratedTypeConstraint protoConstraint in _protoConstraints) {
      result[protoConstraint.typeParameter]!
          .mergeIn(protoConstraint, typeOperations);
    }
    return result;
  }

  /// Tries to constrain type parameters in [type], so that [bound] <: [type].
  ///
  /// Doesn't change the already accumulated set of constraints if [bound] isn't
  /// a subtype of [type] under any set of constraints.
  bool tryConstrainLower(DartType type, DartType bound,
      {required TreeNode? treeNodeForTesting}) {
    return _isNullabilityAwareSubtypeMatch(bound, type,
        constrainSupertype: true, treeNodeForTesting: treeNodeForTesting);
  }

  /// Tries to constrain type parameters in [type], so that [type] <: [bound].
  ///
  /// Doesn't change the already accumulated set of constraints if [type] isn't
  /// a subtype of [bound] under any set of constraints.
  bool tryConstrainUpper(DartType type, DartType bound,
      {required TreeNode? treeNodeForTesting}) {
    return _isNullabilityAwareSubtypeMatch(type, bound,
        constrainSupertype: false, treeNodeForTesting: treeNodeForTesting);
  }

  @override
  void addLowerConstraintForParameter(
      StructuralParameter parameter, DartType lower,
      {required TreeNode? nodeForTesting}) {
    GeneratedTypeConstraint generatedTypeConstraint =
        new GeneratedTypeConstraint.lower(
            parameter, new SharedTypeSchemaView(lower));
    if (nodeForTesting != null && _inferenceResultForTesting != null) {
      // Coverage-ignore-block(suite): Not run.
      (_inferenceResultForTesting.generatedTypeConstraints[nodeForTesting] ??=
              [])
          .add(generatedTypeConstraint);
    }
    _protoConstraints.add(generatedTypeConstraint);
  }

  @override
  void addUpperConstraintForParameter(
      StructuralParameter parameter, DartType upper,
      {required TreeNode? nodeForTesting}) {
    GeneratedTypeConstraint generatedTypeConstraint =
        new GeneratedTypeConstraint.upper(
            parameter, new SharedTypeSchemaView(upper));
    if (nodeForTesting != null && _inferenceResultForTesting != null) {
      // Coverage-ignore-block(suite): Not run.
      (_inferenceResultForTesting.generatedTypeConstraints[nodeForTesting] ??=
              [])
          .add(generatedTypeConstraint);
    }
    _protoConstraints.add(generatedTypeConstraint);
  }

  @override
  bool performSubtypeConstraintGenerationInternal(DartType p, DartType q,
      {required bool leftSchema, required TreeNode? astNodeForTesting}) {
    return _isNullabilityAwareSubtypeMatch(p, q,
        constrainSupertype: leftSchema, treeNodeForTesting: astNodeForTesting);
  }

  /// Matches [p] against [q] as a subtype against supertype.
  ///
  /// If [p] is a subtype of [q] under some constraints, the constraints making
  /// the relation possible are recorded to [_protoConstraints], and `true` is
  /// returned. Otherwise, [_protoConstraints] is left unchanged (or rolled
  /// back), and `false` is returned.
  ///
  /// If [constrainSupertype] is true, the type parameters to constrain occur in
  /// [supertype]; otherwise, they occur in [subtype].  If one type contains the
  /// type parameters to constrain, the other one isn't allowed to contain them.
  /// The type that contains the type parameters isn't allowed to also contain
  /// [UnknownType], that is, to be a type schema.
  bool _isNullabilityAwareSubtypeMatch(DartType p, DartType q,
      {required bool constrainSupertype,
      required TreeNode? treeNodeForTesting}) {
    // If the type parameters being constrained occur in the supertype (that is,
    // [q]), the subtype (that is, [p]) is not allowed to contain them.  To
    // check that, the assert below uses the equivalence of the following: X ->
    // Y  <=>  !X || Y.
    assert(
        !constrainSupertype ||
            !containsStructuralParameter(p, _parametersToConstrain.toSet(),
                unhandledTypeHandler: (DartType type, ignored) =>
                    type is UnknownType
                        ? false
                        :
                        // Coverage-ignore(suite): Not run.
                        throw new UnsupportedError(
                            "Unsupported type '${type.runtimeType}'.")),
        "Failed implication check: "
        "constrainSupertype -> !containsStructuralParameter(q)");

    // If the type parameters being constrained occur in the supertype (that is,
    // [q]), the supertype is not allowed to contain [UnknownType] as its part,
    // that is, the supertype should be fully known.  To check that, the assert
    // below uses the equivalence of the following: X -> Y  <=>  !X || Y.
    assert(
        !constrainSupertype || isKnown(q),
        "Failed implication check: "
        "constrainSupertype -> isKnown(q)");

    // If the type parameters being constrained occur in the subtype (that is,
    // [p]), the subtype is not allowed to contain [UnknownType] as its part,
    // that is, the subtype should be fully known.  To check that, the assert
    // below uses the equivalence of the following: X -> Y  <=>  !X || Y.
    assert(
        constrainSupertype || isKnown(p),
        "Failed implication check: "
        "!constrainSupertype -> isKnown(p)");

    // If the type parameters being constrained occur in the subtype (that is,
    // [p]), the supertype (that is, [q]) is not allowed to contain them.  To
    // check that, the assert below uses the equivalence of the following: X ->
    // Y  <=>  !X || Y.
    assert(
        constrainSupertype ||
            !containsStructuralParameter(q, _parametersToConstrain.toSet(),
                unhandledTypeHandler: (DartType type, ignored) =>
                    type is UnknownType
                        ? false
                        :
                        // Coverage-ignore(suite): Not run.
                        throw new UnsupportedError(
                            "Unsupported type '${type.runtimeType}'.")),
        "Failed implication check: "
        "!constrainSupertype -> !containsStructuralParameter(q)");

    if (p is InvalidType || q is InvalidType) return false;

    // If P is _ then the match holds with no constraints.
    if (p is SharedUnknownTypeStructure) return true;

    // If Q is _ then the match holds with no constraints.
    if (q is SharedUnknownTypeStructure) return true;

    // If P is a type parameter X in L, then the match holds:
    //
    // Under constraint _ <: X <: Q.
    NullabilitySuffix pNullability = p.nullabilitySuffix;
    if (typeOperations.matchInferableParameter(new SharedTypeView(p))
        case StructuralParameter pParameter?
        when pNullability == NullabilitySuffix.none &&
            _parametersToConstrain.contains(pParameter)) {
      addUpperConstraintForParameter(pParameter, q,
          nodeForTesting: treeNodeForTesting);
      return true;
    }

    // If Q is a type parameter X in L, then the match holds:
    //
    // Under constraint P <: X <: _.
    NullabilitySuffix qNullability = q.nullabilitySuffix;
    if (typeOperations.matchInferableParameter(new SharedTypeView(q))
        case StructuralParameter qParameter?
        when qNullability == NullabilitySuffix.none &&
            _parametersToConstrain.contains(qParameter) &&
            (!inferenceUsingBoundsIsEnabled ||
                typeOperations.isSubtypeOfInternal(
                    p,
                    typeOperations.greatestClosureOfTypeInternal(
                        qParameter.bound, _parametersToConstrain)))) {
      addLowerConstraintForParameter(qParameter, p,
          nodeForTesting: treeNodeForTesting);
      return true;
    }

    // If P and Q are identical types, then the subtype match holds under no
    // constraints.
    //
    // We're only checking primitive types for equality, because the algorithm
    // will recurse over non-primitive types anyway.
    if (identical(p, q) ||
        isPrimitiveDartType(p) && isPrimitiveDartType(q) && p == q) {
      return true;
    }

    if (performSubtypeConstraintGenerationForRightFutureOr(p, q,
        leftSchema: constrainSupertype,
        astNodeForTesting: treeNodeForTesting)) {
      return true;
    }

    // If Q is Q0? the match holds under constraint set C:
    //
    // If P is P0? and P0 is a subtype match for Q0 under constraint set C.
    // Or if P is dynamic or void and Object is a subtype match for Q0 under
    // constraint set C.
    // Or if P is a subtype match for Q0 under non-empty constraint set C.
    // Or if P is a subtype match for Null under constraint set C.
    // Or if P is a subtype match for Q0 under empty constraint set C.
    if (performSubtypeConstraintGenerationForRightNullableType(p, q,
        leftSchema: constrainSupertype,
        astNodeForTesting: treeNodeForTesting)) {
      return true;
    }

    // If P is FutureOr<P0> the match holds under constraint set C1 + C2:
    //
    // If Future<P0> is a subtype match for Q under constraint set C1.
    // And if P0 is a subtype match for Q under constraint set C2.
    if (performSubtypeConstraintGenerationForLeftFutureOr(p, q,
        leftSchema: constrainSupertype,
        astNodeForTesting: treeNodeForTesting)) {
      return true;
    }

    // If P is P0? the match holds under constraint set C1 + C2:
    //
    // If P0 is a subtype match for Q under constraint set C1.
    // And if Null is a subtype match for Q under constraint set C2.
    if (performSubtypeConstraintGenerationForLeftNullableType(p, q,
        leftSchema: constrainSupertype,
        astNodeForTesting: treeNodeForTesting)) {
      return true;
    }

    // If Q is dynamic, Object?, or void then the match holds under no
    // constraints.
    if (q is SharedDynamicTypeStructure ||
        q is SharedVoidTypeStructure ||
        q == typeOperations.objectQuestionType.unwrapTypeView()) {
      return true;
    }

    // If P is Never then the match holds under no constraints.
    if (typeOperations.isNever(new SharedTypeView(p))) {
      return true;
    }

    // If Q is Object, then the match holds under no constraints:
    //
    // Only if P is non-nullable.
    if (q == typeOperations.objectType.unwrapTypeView()) {
      return typeOperations.isNonNullable(new SharedTypeSchemaView(p));
    }

    // If P is Null, then the match holds under no constraints:
    //
    // Only if Q is nullable.
    if (typeOperations.isNull(new SharedTypeView(p))) {
      return q.nullability == Nullability.nullable;
    }

    // If P is a type parameter X with bound B (or a promoted type parameter X &
    // B), the match holds with constraint set C:
    //
    // If B is a subtype match for Q with constraint set C.  Note that we have
    // already eliminated the case that X is a variable in L.
    if (typeAnalyzerOperations.matchTypeParameterBoundInternal(p)
        case DartType bound?) {
      if (performSubtypeConstraintGenerationInternal(bound, q,
          leftSchema: constrainSupertype,
          astNodeForTesting: treeNodeForTesting)) {
        return true;
      }
    }

    bool? constraintGenerationResult =
        performSubtypeConstraintGenerationForTypeDeclarationTypes(p, q,
            leftSchema: constrainSupertype,
            astNodeForTesting: treeNodeForTesting);
    if (constraintGenerationResult != null) {
      return constraintGenerationResult;
    }

    // If Q is Function then the match holds under no constraints:
    //
    // If P is a function type.
    if (typeOperations.isDartCoreFunction(new SharedTypeView(q)) &&
        // Coverage-ignore(suite): Not run.
        p is FunctionType) {
      return true;
    }

    if (performSubtypeConstraintGenerationForFunctionTypes(p, q,
        leftSchema: constrainSupertype,
        astNodeForTesting: treeNodeForTesting)) {
      return true;
    }

    // A type P is a subtype match for Record with respect to L under no
    // constraints:
    //
    // If P is a record type or Record.
    if (typeOperations.isDartCoreRecord(new SharedTypeView(q)) &&
        p is RecordType) {
      return true;
    }

    if (performSubtypeConstraintGenerationForRecordTypes(p, q,
        leftSchema: constrainSupertype,
        astNodeForTesting: treeNodeForTesting)) {
      return true;
    }

    return false;
  }
}
