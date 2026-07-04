module Penance.Graph.Component
  ( componentDrvEntries
  , emitBootstrap
  )
where

import qualified Penance.Json as Json
import Penance.Json (array, object, string)
import Penance.Plan
  ( LocalComponent (..)
  , LocalPackage (..)
  , ProjectSkeleton (..)
  , drvFileFor
  , skeletonPath
  , writeJsonFile
  )
import System.Directory (copyFile, createDirectoryIfMissing)
import System.FilePath ((</>))

data ComponentEntry = ComponentEntry
  { entryPackage :: String
  , entryVersion :: String
  , entryComponent :: String
  , entryKind :: String
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
  copyFile (skeletonPath skeleton) (dir </> "component-graph.bootstrap.json")
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
    [ ("kind", string "componentGraph")
    , ("status", string "planned")
    , ("projectKey", string (projectKey skeleton))
    , ("planCacheKey", string (planCacheKey skeleton))
    , ("granularity", string (granularity skeleton))
    , ("components", array (map componentEntryJson (componentEntries skeleton)))
    ]

componentEntryJson :: ComponentEntry -> Json.Json
componentEntryJson entry =
  object
    [ ("package", string (entryPackage entry))
    , ("version", string (entryVersion entry))
    , ("component", string (entryComponent entry))
    , ("componentKind", string (entryKind entry))
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
        [ ("kind", string "componentDrv")
        , ("status", string "planned")
        , ("package", string (entryPackage entry))
        , ("version", string (entryVersion entry))
        , ("component", string (entryComponent entry))
        , ("componentKind", string (entryKind entry))
        , ("unit", string (entryUnit entry))
        ]
    )
