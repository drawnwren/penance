module Penance.Graph.Module
  ( emitBootstrap
  , moduleDrvEntries
  )
where

import qualified Penance.Json as Json
import Penance.Json (array, object, string)
import Penance.Skeleton
  ( LocalComponent (..)
  , LocalPackage (..)
  , ProjectSkeleton (..)
  )
import Penance.Plan (drvFileFor, writeJsonFile)
import Penance.Types
  ( PlanArtifactKind (..)
  , PlanStatus (..)
  , renderGranularity
  , renderPlanArtifactKind
  , renderPlanStatus
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

data ModuleEntry = ModuleEntry
  { entryPackage :: String
  , entryComponent :: String
  , entryModule :: String
  , entryUnit :: String
  , entryPath :: FilePath
  }
  deriving (Eq, Show)

moduleDrvEntries :: ProjectSkeleton -> [(String, FilePath)]
moduleDrvEntries skeleton =
  [ (entryUnit entry ++ ":" ++ entryModule entry, entryPath entry)
  | entry <- moduleEntries skeleton
  ]

emitBootstrap :: ProjectSkeleton -> FilePath -> IO ()
emitBootstrap skeleton out = do
  let dir = out </> "modules"
  createDirectoryIfMissing True dir
  writeJsonFile (dir </> "module-graph.json") (moduleGraphJson skeleton)
  mapM_ (writeModulePlan out) (moduleEntries skeleton)

moduleEntries :: ProjectSkeleton -> [ModuleEntry]
moduleEntries skeleton =
  [ ModuleEntry
      { entryPackage = packageName pkg
      , entryComponent = componentName component
      , entryModule = moduleName
      , entryUnit = packageName pkg ++ ":" ++ componentName component
      , entryPath =
          "modules"
            </> packageName pkg
            </> drvFileFor (componentName component ++ ":" ++ moduleName)
      }
  | pkg <- localPackages skeleton
  , component <- packageComponentDetails pkg
  , moduleName <- componentProvidedModules component
  ]

moduleGraphJson :: ProjectSkeleton -> Json.Json
moduleGraphJson skeleton =
  object
    [ ("kind", string (renderPlanArtifactKind ModuleGraphArtifact))
    , ("status", string (renderPlanStatus Planned))
    , ("projectKey", string (projectKey skeleton))
    , ("planCacheKey", string (planCacheKey skeleton))
    , ("granularity", string (renderGranularity (granularity skeleton)))
    , ("modules", array (map moduleEntryJson (moduleEntries skeleton)))
    ]

moduleEntryJson :: ModuleEntry -> Json.Json
moduleEntryJson entry =
  object
    [ ("package", string (entryPackage entry))
    , ("component", string (entryComponent entry))
    , ("module", string (entryModule entry))
    , ("unit", string (entryUnit entry))
    , ("drvPlan", string (entryPath entry))
    ]

writeModulePlan :: FilePath -> ModuleEntry -> IO ()
writeModulePlan out entry = do
  let dir = out </> "modules" </> entryPackage entry
  createDirectoryIfMissing True dir
  writeJsonFile
    (out </> entryPath entry)
    ( object
        [ ("kind", string (renderPlanArtifactKind ModuleDrvArtifact))
        , ("status", string (renderPlanStatus Planned))
        , ("package", string (entryPackage entry))
        , ("component", string (entryComponent entry))
        , ("module", string (entryModule entry))
        , ("unit", string (entryUnit entry))
        ]
    )
