module Penance.Graph.Package
  ( emitBootstrap
  , packagePlanEntries
  )
where

import qualified Penance.Json as Json
import Penance.Json (array, object, string)
import Penance.Skeleton
  ( LocalComponent (..)
  , LocalPackage (..)
  , ProjectSkeleton (..)
  , renderComponentId
  , renderModuleName
  , renderPkgName
  )
import Penance.Plan (drvFileFor, writeJsonFile)
import Penance.Types
  ( PlanArtifactKind (..)
  , PlanStatus (..)
  , renderComponentKind
  , renderGranularity
  , renderPlanArtifactKind
  , renderPlanStatus
  )
import System.Directory (createDirectoryIfMissing)
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
  writeJsonFile (dir </> "package-graph.json") (packageGraphJson skeleton)
  mapM_ (writePackagePlan out) (packageEntries skeleton)

packageEntries :: ProjectSkeleton -> [PackageEntry]
packageEntries skeleton =
  [ PackageEntry
      { entryName = renderPkgName (packageName pkg)
      , entryVersion = packageVersion pkg
      , entryComponents = packageComponentDetails pkg
      , entryProvidedModules = map renderModuleName (packageProvidedModules pkg)
      , entrySignatures = map renderModuleName (packageSignatures pkg)
      , entryRequiredSignatures = map renderModuleName (packageRequiredSignatures pkg)
      , entryPath = "packages" </> renderPkgName (packageName pkg) </> drvFileFor "package"
      }
  | pkg <- localPackages skeleton
  ]

packageGraphJson :: ProjectSkeleton -> Json.Json
packageGraphJson skeleton =
  object
    [ ("kind", string (renderPlanArtifactKind PackageGraphArtifact))
    , ("status", string (renderPlanStatus Planned))
    , ("granularity", string (renderGranularity (granularity skeleton)))
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
    [ ("component", string (renderComponentId (componentName component)))
    , ("kind", string (renderComponentKind (componentKind component)))
    , ("providedModules", array (map (string . renderModuleName) (componentProvidedModules component)))
    , ("signatures", array (map (string . renderModuleName) (componentSignatures component)))
    , ("requiredSignatures", array (map (string . renderModuleName) (componentRequiredSignatures component)))
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
        [ ("kind", string (renderPlanArtifactKind PackagePlanArtifact))
        , ("status", string (renderPlanStatus Planned))
        , ("package", string (entryName entry))
        , ("version", string (entryVersion entry))
        , ("components", array (map componentJson (entryComponents entry)))
        , ("providedModules", array (map string (entryProvidedModules entry)))
        , ("signatures", array (map string (entrySignatures entry)))
        , ("requiredSignatures", array (map string (entryRequiredSignatures entry)))
        ]
    )
