module Penance.Graph.Component
  ( componentDrvEntries
  , emitBootstrap
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
  ( ComponentKind
  , PlanArtifactKind (..)
  , PlanStatus (..)
  , renderComponentKind
  , renderGranularity
  , renderPlanArtifactKind
  , renderPlanStatus
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

data ComponentEntry = ComponentEntry
  { entryPackage :: String
  , entryVersion :: String
  , entryComponent :: String
  , entryKind :: ComponentKind
  , entryUnit :: String
  , entryPath :: FilePath
  }
  deriving (Eq, Show)

componentDrvEntries :: ProjectSkeleton -> [(String, FilePath)]
componentDrvEntries skeleton =
  [ (entryUnit entry, entryPath entry)
  | entry <- componentEntries skeleton
  ]

emitBootstrap :: ProjectSkeleton -> FilePath -> IO ()
emitBootstrap skeleton out = do
  let dir = out </> "components"
  createDirectoryIfMissing True dir
  writeJsonFile (dir </> "component-graph.json") (componentGraphJson skeleton)
  mapM_ (writeComponentPlan out) (componentEntries skeleton)

componentEntries :: ProjectSkeleton -> [ComponentEntry]
componentEntries skeleton =
  [ ComponentEntry
      { entryPackage = packageName pkg
      , entryVersion = packageVersion pkg
      , entryComponent = componentName component
      , entryKind = componentKind component
      , entryUnit = packageName pkg ++ ":" ++ componentName component
      , entryPath = "components" </> packageName pkg </> drvFileFor (componentName component)
      }
  | pkg <- localPackages skeleton
  , component <- packageComponentDetails pkg
  ]

componentGraphJson :: ProjectSkeleton -> Json.Json
componentGraphJson skeleton =
  object
    [ ("kind", string (renderPlanArtifactKind ComponentGraphArtifact))
    , ("status", string (renderPlanStatus Planned))
    , ("projectKey", string (projectKey skeleton))
    , ("planCacheKey", string (planCacheKey skeleton))
    , ("granularity", string (renderGranularity (granularity skeleton)))
    , ("components", array (map componentEntryJson (componentEntries skeleton)))
    ]

componentEntryJson :: ComponentEntry -> Json.Json
componentEntryJson entry =
  object
    [ ("package", string (entryPackage entry))
    , ("version", string (entryVersion entry))
    , ("component", string (entryComponent entry))
    , ("componentKind", string (renderComponentKind (entryKind entry)))
    , ("unit", string (entryUnit entry))
    , ("drvPlan", string (entryPath entry))
    ]

writeComponentPlan :: FilePath -> ComponentEntry -> IO ()
writeComponentPlan out entry = do
  let path = out </> entryPath entry
  createDirectoryIfMissing True (out </> "components" </> entryPackage entry)
  writeJsonFile
    path
    ( object
        [ ("kind", string (renderPlanArtifactKind ComponentDrvArtifact))
        , ("status", string (renderPlanStatus Planned))
        , ("package", string (entryPackage entry))
        , ("version", string (entryVersion entry))
        , ("component", string (entryComponent entry))
        , ("componentKind", string (renderComponentKind (entryKind entry)))
        , ("unit", string (entryUnit entry))
        ]
    )
