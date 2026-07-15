module Penance.Emit.Drv (writeBootstrapIndex) where

import qualified Penance.Graph.Backpack as Backpack
import qualified Penance.Graph.Component as Component
import qualified Penance.Graph.Module as Module
import qualified Penance.Graph.Package as Package
import qualified Penance.Json as Json
import Penance.Json (array, bool, object, string)
import Penance.Plan (writeJsonFile)
import Penance.Skeleton (ExpectedOutputs (..), ProjectSkeleton (..))
import Penance.Types
  ( PlanArtifactKind (..)
  , PlanStatus (..)
  , renderGranularity
  , renderPlanArtifactKind
  , renderPlanStatus
  )
import System.FilePath ((</>))

writeBootstrapIndex :: ProjectSkeleton -> FilePath -> IO ()
writeBootstrapIndex skeleton out = do
  writeJsonFile (out </> "drv-index.json") (indexJson skeleton)
  writeJsonFile (out </> "graph-plan.json") (graphPlanJson skeleton)

indexJson :: ProjectSkeleton -> Json.Json
indexJson skeleton =
  object
    [ ("kind", string (renderPlanArtifactKind DrvIndexArtifact))
    , ("status", string (renderPlanStatus Planned))
    , ("granularity", string (renderGranularity (granularity skeleton)))
    , ("packages", entryArray (Package.packagePlanEntries skeleton))
    , ("components", entryArray (Component.componentDrvEntries skeleton))
    , ("modules", entryArray (Module.moduleDrvEntries skeleton))
    , ("backpack", entryArray (Backpack.backpackDrvEntries skeleton))
    ]

graphPlanJson :: ProjectSkeleton -> Json.Json
graphPlanJson skeleton =
  object
    [ ("kind", string (renderPlanArtifactKind GraphPlanArtifact))
    , ("status", string (renderPlanStatus Planned))
    , ("granularity", string (renderGranularity (granularity skeleton)))
    , ("rootFiles", rootFilesJson)
    , ("expectedOutputs", expectedOutputsJson (expectedOutputs skeleton))
    , ("packages", entryArray (Package.packagePlanEntries skeleton))
    , ("components", entryArray (Component.componentDrvEntries skeleton))
    , ("modules", entryArray (Module.moduleDrvEntries skeleton))
    , ("backpack", entryArray (Backpack.backpackDrvEntries skeleton))
    ]

rootFilesJson :: Json.Json
rootFilesJson =
  object
    [ ("projectSkeleton", string "project-skeleton.json")
    , ("plannerInput", string "planner-input.json")
    , ("packageGraph", string ("packages" </> "package-graph.json"))
    , ("componentGraph", string ("components" </> "component-graph.json"))
    , ("moduleGraph", string ("modules" </> "module-graph.json"))
    , ("backpackGraph", string ("signatures" </> "backpack-graph.json"))
    , ("drvIndex", string "drv-index.json")
    ]

expectedOutputsJson :: ExpectedOutputs -> Json.Json
expectedOutputsJson outputs =
  object
    [ ("componentGraphDrv", bool (componentGraphDrv outputs))
    , ("moduleGraphDrv", bool (moduleGraphDrv outputs))
    , ("backpackGraphDrv", bool (backpackGraphDrv outputs))
    ]

entryArray :: [(String, FilePath)] -> Json.Json
entryArray entries =
  array
    [ object
        [ ("key", string key)
        , ("drvPlan", string path)
        ]
    | (key, path) <- entries
    ]
