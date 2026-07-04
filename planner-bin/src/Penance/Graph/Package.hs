module Penance.Graph.Package
  ( emitBootstrap
  , packagePlanEntries
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

data PackageEntry = PackageEntry
  { entryName :: String
  , entryVersion :: String
  , entryComponents :: [LocalComponent]
  , entryProvidedModules :: [String]
  , entrySignatures :: [String]
  , entryRequiredSignatures :: [String]
  , entryPath :: FilePath
  }
  deriving (Eq, Show)

packagePlanEntries :: ProjectSkeleton -> [(String, FilePath)]
packagePlanEntries skeleton =
  [ (entryName entry, entryPath entry)
  | entry <- packageEntries skeleton
  ]

emitBootstrap :: ProjectSkeleton -> FilePath -> IO ()
emitBootstrap skeleton out = do
  let dir = out </> "packages"
  createDirectoryIfMissing True dir
  copyFile (skeletonPath skeleton) (dir </> "package-graph.bootstrap.json")
  writeJsonFile (dir </> "package-graph.json") (packageGraphJson skeleton)
  mapM_ (writePackagePlan out) (packageEntries skeleton)

packageEntries :: ProjectSkeleton -> [PackageEntry]
packageEntries skeleton =
  [ PackageEntry
      { entryName = packageName pkg
      , entryVersion = packageVersion pkg
      , entryComponents = packageComponentDetails pkg
      , entryProvidedModules = packageProvidedModules pkg
      , entrySignatures = packageSignatures pkg
      , entryRequiredSignatures = packageRequiredSignatures pkg
      , entryPath = "packages" </> packageName pkg </> drvFileFor "package"
      }
  | pkg <- localPackages skeleton
  ]

packageGraphJson :: ProjectSkeleton -> Json.Json
packageGraphJson skeleton =
  object
    [ ("kind", string "packageGraph")
    , ("status", string "planned")
    , ("projectKey", string (projectKey skeleton))
    , ("planCacheKey", string (planCacheKey skeleton))
    , ("granularity", string (granularity skeleton))
    , ("packages", array (map packageEntryJson (packageEntries skeleton)))
    ]

packageEntryJson :: PackageEntry -> Json.Json
packageEntryJson entry =
  object
    [ ("package", string (entryName entry))
    , ("version", string (entryVersion entry))
    , ("components", array (map componentJson (entryComponents entry)))
    , ("providedModules", array (map string (entryProvidedModules entry)))
    , ("signatures", array (map string (entrySignatures entry)))
    , ("requiredSignatures", array (map string (entryRequiredSignatures entry)))
    , ("drvPlan", string (entryPath entry))
    ]

componentJson :: LocalComponent -> Json.Json
componentJson component =
  object
    [ ("component", string (componentName component))
    , ("kind", string (componentKind component))
    , ("providedModules", array (map string (componentProvidedModules component)))
    , ("signatures", array (map string (componentSignatures component)))
    , ("requiredSignatures", array (map string (componentRequiredSignatures component)))
    , ("mixins", array (map string (componentMixins component)))
    , ("reexportedModules", array (map string (componentReexportedModules component)))
    ]

writePackagePlan :: FilePath -> PackageEntry -> IO ()
writePackagePlan out entry = do
  let dir = out </> "packages" </> entryName entry
  createDirectoryIfMissing True dir
  writeJsonFile
    (out </> entryPath entry)
    ( object
        [ ("kind", string "packagePlan")
        , ("status", string "planned")
        , ("package", string (entryName entry))
        , ("version", string (entryVersion entry))
        , ("components", array (map componentJson (entryComponents entry)))
        , ("providedModules", array (map string (entryProvidedModules entry)))
        , ("signatures", array (map string (entrySignatures entry)))
        , ("requiredSignatures", array (map string (entryRequiredSignatures entry)))
        ]
    )
