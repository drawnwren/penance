{
  ghcWasm,
  haskellNix,
  forAllSystems,
  pkgsFor,
  stackageResolver,
  hackageStateVarVersion,
  ...
}:
forAllSystems (
  system:
  let
    groupScope = builtins.foldl' (scope: group: scope // group) { };

    groups = rec {
      foundation = import ./packages/foundation {
        inherit
          ghcWasm
          haskellNix
          hackageStateVarVersion
          pkgsFor
          stackageResolver
          system
          ;
      };

      tooling = import ./packages/tooling (groupScope [
        foundation
      ]);

      penance = import ./packages/penance (groupScope [
        foundation
        tooling
      ]);

      haskellNixBaselines = import ./packages/haskell-nix (groupScope [
        foundation
        tooling
        penance
      ]);

      repent = import ./packages/repent (groupScope [
        foundation
        tooling
        penance
        haskellNixBaselines
      ]);

      primitiveProbes = import ./packages/primitive-probes (groupScope [
        foundation
        tooling
        penance
        haskellNixBaselines
        repent
      ]);

      dynamicDerivations = import ./packages/dynamic-derivations (groupScope [
        foundation
        tooling
        penance
        haskellNixBaselines
        repent
        primitiveProbes
      ]);

      deployment = import ./packages/deployment (groupScope [
        foundation
        tooling
        penance
        haskellNixBaselines
        repent
        primitiveProbes
        dynamicDerivations
      ]);
    };

  in
  {
    inherit (groups.tooling)
      penanceLowererEquality
      penanceLowererWasmProvenance
      penanceComponentQualifiedDependencies
      penanceUnitCacheIsolation
      plannerBin
      penanceDocs
      penanceIfaceCanonicalizerProof
      ghcWasmIfaceCanonicalizer
      ghcWasmIfaceCanonicalizerBuilt
      ghcWasmPlanner
      plannerNormalizerNative
      ;

    inherit (groups.penance)
      backpackMultiInstanceModule
      backpackSignaturesModule
      cSourcesExecutable
      penanceBackpackReal
      penanceBenchChecks
      penanceBenchDevShell
      penanceBenchShellGhc
      penanceBenchSurface
      penanceBenchBenchmarkViaLock
      penanceBenchLibViaLock
      penanceBenchO0ViaLock
      penanceBenchShell
      penanceBenchTestViaLock
      penanceBenchViaLock
      penanceCSources
      penanceDependencyInputs
      penanceHackageStateVar
      penanceHaskellAarch64LinuxReal
      penanceLockExternalViaLock
      penanceLocalThDependency
      penanceMultiInstanceExternal
      penanceBenchComponent
      penanceBenchModule
      penanceSimpleLibViaLock
      penanceStackageStateVar
      simpleLibComponent
      ;

    inherit (groups.haskellNixBaselines)
      haskellNixBackpackExe
      haskellNixBenchChecks
      haskellNixBenchExe
      haskellNixBenchPlan
      haskellNixBenchPlanMaterialized
      haskellNixBenchShell
      haskellNixBenchSurface
      haskellNixHackageStateVar
      haskellNixHsBootThExe
      haskellNixHsBootThSmoke
      haskellNixModuleCutoff30Exe
      haskellNixProjectCrossAarch64
      haskellNixSimpleLib
      haskellNixStackageStateVar
      ;

    inherit (groups.repent)
      repentBench
      repentBenchPlan
      ;

    inherit (groups.primitiveProbes)
      haskellNixPrimitiveProbes
      penancePrimitiveProbes
      ;

    inherit (groups.dynamicDerivations)
      penanceAddPathConsumer
      penanceAddPathPlanner
      penanceBenchDyndrv
      penanceBenchDyndrvPlanner
      penanceBenchDyndrvPlannerRepeat
      penanceDyndrvEmissionProof
      penanceModuleCutoff30Dyndrv
      penanceModuleCutoff30DyndrvPlanner
      penanceCaCutoffToy
      penanceCaCutoffToyA
      penanceCaCutoffToyB
      penanceCaCutoffToyC
      penanceHsBootThClassificationProof
      penanceHsBootThDyndrv
      penanceHsBootThDyndrvPlanner
      penanceModuleGranularBench
      penanceProbePlanner
      penanceProbePlannerConsumer
      penanceProbePlannerCorrupt
      penanceProbePlannerDeterminismA
      penanceProbePlannerDeterminismB
      penanceProbePlannerDeterminismBadA
      penanceProbePlannerDeterminismBadB
      penanceProbePlannerNondeterministic
      ;

    inherit (groups.deployment)
      haskellNixMscBundle
      haskellNixProjectVariants
      haskellNixWarpBaseline
      penanceLockCacheManifest
      penanceMscBundle
      penanceProjectVariants
      penanceWarpLoop
      ;

    default = groups.tooling.plannerNormalizerNative;
    docs = groups.tooling.penanceDocs;
    repent = groups.tooling.repentTool;
  }
)
