module Penance.Types
  ( CompilerId (..)
  , IndexState (..)
  , Granularity (..)
  , parseGranularity
  , renderGranularity
  , MaterializationMode (..)
  , parseMaterializationMode
  , renderMaterializationMode
  , ComponentKind (..)
  , parseComponentKind
  , renderComponentKind
  , SourceKind (..)
  , parseSourceKind
  , renderSourceKind
  , PenanceSchema (..)
  , renderPenanceSchema
  , ProjectPathBase (..)
  , renderProjectPathBase
  , PlanStatus (..)
  , renderPlanStatus
  , PlanArtifactKind (..)
  , renderPlanArtifactKind
  , PackageDbKind (..)
  , parsePackageDbKind
  , renderPackageDbKind
  , PhaseStatus (..)
  , parsePhaseStatus
  , renderPhaseStatus
  , BenchmarkBackend (..)
  , renderBenchmarkBackend
  , BenchmarkAction (..)
  , renderBenchmarkAction
  , BenchmarkStatus (..)
  , benchmarkStatusFromExit
  , benchmarkStatusSucceeded
  , renderBenchmarkStatus
  ) where

newtype CompilerId = CompilerId {renderCompilerId :: String}
  deriving (Eq, Ord, Show)

newtype IndexState = IndexState {renderIndexState :: String}
  deriving (Eq, Ord, Show)

data Granularity
  = ComponentGranularity
  | ModuleGranularity
  deriving (Eq, Ord, Show)

parseGranularity :: String -> Either String Granularity
parseGranularity value =
  case value of
    "component" -> Right ComponentGranularity
    "module" -> Right ModuleGranularity
    _ -> Left ("unsupported granularity `" ++ value ++ "`; expected `component` or `module`")

renderGranularity :: Granularity -> String
renderGranularity granularity =
  case granularity of
    ComponentGranularity -> "component"
    ModuleGranularity -> "module"

data MaterializationMode = DynamicMaterialization
  deriving (Eq, Ord, Show)

parseMaterializationMode :: String -> Either String MaterializationMode
parseMaterializationMode value =
  case value of
    "dynamic" -> Right DynamicMaterialization
    _ -> Left ("unsupported materializationMode `" ++ value ++ "`; expected `dynamic`")

renderMaterializationMode :: MaterializationMode -> String
renderMaterializationMode DynamicMaterialization = "dynamic"

data ComponentKind
  = LibraryKind
  | ExecutableKind
  | TestSuiteKind
  | BenchmarkKind
  deriving (Eq, Ord, Show)

parseComponentKind :: String -> Either String ComponentKind
parseComponentKind value =
  case value of
    "library" -> Right LibraryKind
    "executable" -> Right ExecutableKind
    "test-suite" -> Right TestSuiteKind
    "benchmark" -> Right BenchmarkKind
    _ -> Left ("unsupported component kind `" ++ value ++ "`")

renderComponentKind :: ComponentKind -> String
renderComponentKind kind =
  case kind of
    LibraryKind -> "library"
    ExecutableKind -> "executable"
    TestSuiteKind -> "test-suite"
    BenchmarkKind -> "benchmark"

data SourceKind = RegularSource
  deriving (Eq, Ord, Show)

parseSourceKind :: String -> Either String SourceKind
parseSourceKind value =
  case value of
    "regular" -> Right RegularSource
    _ -> Left ("unsupported source kind `" ++ value ++ "`; expected `regular`")

renderSourceKind :: SourceKind -> String
renderSourceKind RegularSource = "regular"

data PenanceSchema
  = LockSchemaV1
  | ModulePlanSchemaV1
  | ArchitecturePhaseMatrixSchemaV1
  | ArchitecturePhaseBenchSchemaV1
  | RebuildScenariosSchemaV1
  | RebuildBenchSchemaV1
  deriving (Eq, Ord, Show)

renderPenanceSchema :: PenanceSchema -> String
renderPenanceSchema schema =
  case schema of
    LockSchemaV1 -> "penance/lock/1"
    ModulePlanSchemaV1 -> "penance/module-plan/1"
    ArchitecturePhaseMatrixSchemaV1 -> "penance/architecture-phase-matrix/1"
    ArchitecturePhaseBenchSchemaV1 -> "penance/architecture-phase-bench/1"
    RebuildScenariosSchemaV1 -> "penance/rebuild-scenarios/1"
    RebuildBenchSchemaV1 -> "penance/rebuild-bench/1"

data ProjectPathBase = ProjectRootPathBase
  deriving (Eq, Ord, Show)

renderProjectPathBase :: ProjectPathBase -> String
renderProjectPathBase ProjectRootPathBase = "project-root"

data PlanStatus = Planned
  deriving (Eq, Ord, Show)

renderPlanStatus :: PlanStatus -> String
renderPlanStatus Planned = "planned"

data PlanArtifactKind
  = DrvIndexArtifact
  | GraphPlanArtifact
  | PackageGraphArtifact
  | PackagePlanArtifact
  | ModuleGraphArtifact
  | ModuleDrvArtifact
  | ComponentGraphArtifact
  | ComponentDrvArtifact
  | BackpackGraphArtifact
  | SignatureTypecheckDrvArtifact
  | SignatureDrvArtifact
  | InstantiationDrvArtifact
  deriving (Eq, Ord, Show)

renderPlanArtifactKind :: PlanArtifactKind -> String
renderPlanArtifactKind kind =
  case kind of
    DrvIndexArtifact -> "drvIndex"
    GraphPlanArtifact -> "graphPlan"
    PackageGraphArtifact -> "packageGraph"
    PackagePlanArtifact -> "packagePlan"
    ModuleGraphArtifact -> "moduleGraph"
    ModuleDrvArtifact -> "moduleDrv"
    ComponentGraphArtifact -> "componentGraph"
    ComponentDrvArtifact -> "componentDrv"
    BackpackGraphArtifact -> "backpackGraph"
    SignatureTypecheckDrvArtifact -> "signatureTypecheckDrv"
    SignatureDrvArtifact -> "signatureDrv"
    InstantiationDrvArtifact -> "instantiationDrv"

data PackageDbKind
  = InterfacePackageDb
  | FullPackageDb
  deriving (Eq, Ord, Show)

parsePackageDbKind :: String -> Either String PackageDbKind
parsePackageDbKind value =
  case value of
    "dbIface" -> Right InterfacePackageDb
    "dbFull" -> Right FullPackageDb
    _ -> Left ("unsupported package database kind `" ++ value ++ "`")

renderPackageDbKind :: PackageDbKind -> String
renderPackageDbKind kind =
  case kind of
    InterfacePackageDb -> "dbIface"
    FullPackageDb -> "dbFull"

data PhaseStatus
  = ComparisonPhase
  | FailingPhase
  deriving (Eq, Ord, Show)

parsePhaseStatus :: String -> Either String PhaseStatus
parsePhaseStatus value =
  case value of
    "comparison" -> Right ComparisonPhase
    "failing" -> Right FailingPhase
    _ -> Left ("unsupported phase status `" ++ value ++ "`")

renderPhaseStatus :: PhaseStatus -> String
renderPhaseStatus status =
  case status of
    ComparisonPhase -> "comparison"
    FailingPhase -> "failing"

data BenchmarkBackend
  = PenanceBackend
  | HaskellNixBackend
  | PhaseBackend
  deriving (Eq, Ord, Show)

renderBenchmarkBackend :: BenchmarkBackend -> String
renderBenchmarkBackend backend =
  case backend of
    PenanceBackend -> "penance"
    HaskellNixBackend -> "haskell.nix"
    PhaseBackend -> "phase"

data BenchmarkAction
  = ArchitectureFailureAction
  | SkippedAction
  | EvalDrvPathAction
  | BuildAction
  | BuildDryRunAction
  | RebuildDryRunAction
  | DyndrvBuildLogAction
  deriving (Eq, Ord, Show)

renderBenchmarkAction :: BenchmarkAction -> String
renderBenchmarkAction action =
  case action of
    ArchitectureFailureAction -> "architecture_failure"
    SkippedAction -> "skipped"
    EvalDrvPathAction -> "eval_drv_path"
    BuildAction -> "build"
    BuildDryRunAction -> "build_dry_run"
    RebuildDryRunAction -> "rebuild_dry_run"
    DyndrvBuildLogAction -> "dyndrv_build_log"

data BenchmarkStatus
  = BenchmarkSucceeded
  | BenchmarkNotImplemented
  | BenchmarkUnsupported
  | BenchmarkFailed String
  deriving (Eq, Ord, Show)

benchmarkStatusFromExit :: Int -> BenchmarkStatus
benchmarkStatusFromExit code =
  if code == 0 then BenchmarkSucceeded else BenchmarkFailed (show code)

benchmarkStatusSucceeded :: BenchmarkStatus -> Bool
benchmarkStatusSucceeded BenchmarkSucceeded = True
benchmarkStatusSucceeded _ = False

renderBenchmarkStatus :: BenchmarkStatus -> String
renderBenchmarkStatus status =
  case status of
    BenchmarkSucceeded -> "0"
    BenchmarkNotImplemented -> "not_implemented"
    BenchmarkUnsupported -> "unsupported"
    BenchmarkFailed message -> message
