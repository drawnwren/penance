module Penance.Repent.Lock
  ( lockJson
  , externalUnitExpressionName
  )
where

import Data.List (sort, sortOn)
import Distribution.PackageDescription
  ( BuildInfo (..)
  , PackageDescription (..)
  , buildType
  , pkgName
  , pkgVersion
  )
import Distribution.Pretty (prettyShow)
import Penance.Blake3 (hashHex)
import Penance.CabalPlan
  ( ExternalSource (..)
  , ExternalUnit (..)
  , LocalComponentUnit (..)
  , ResolvedPlan (..)
  , renderFlagAssignment
  , renderUnitId
  )
import qualified Penance.CabalPlan as CabalPlan
import Penance.Json (Json)
import qualified Penance.Json as Json
import Penance.Repent.Project
  ( LockComponent (..)
  , LockComponentName (..)
  , PackageLock (..)
  )
import Penance.Types
  ( CompilerId
  , IndexState
  , PenanceSchema (..)
  , ProjectPathBase (..)
  , renderCompilerId
  , renderComponentKind
  , renderIndexState
  , renderPenanceSchema
  , renderProjectPathBase
  )

lockJson :: CompilerId -> IndexState -> Maybe String -> [PackageLock] -> ResolvedPlan -> Either String Json
lockJson compiler indexState packageSetHash packages plan = do
  packageValues <- traverse (packageJson plan) packages
  pure . Json.object $
    [ ("schema", Json.string (renderPenanceSchema LockSchemaV2))
    , ("compiler", Json.string (renderCompilerId compiler))
    , ("indexState", Json.string (renderIndexState indexState))
    , ( "project"
      , Json.object
          [ ("root", Json.string ".")
          , ("pathBase", Json.string (renderProjectPathBase ProjectRootPathBase))
          , ("cabalProject", Json.string "cabal.project")
          , ("packages", Json.array (map (Json.string . lockPackagePath) packages))
          ]
      )
    , ("packages", Json.array packageValues)
    , ("externalUnits", Json.array (map externalUnitJson (resolvedExternalUnits plan)))
    ]
      ++ maybe [] (\hash -> [("packageSetHash", Json.string hash)]) packageSetHash

packageJson :: ResolvedPlan -> PackageLock -> Either String Json
packageJson plan packageLock = do
  let desc = lockDescription packageLock
      packageName = prettyShow (pkgName (package desc))
  components <- componentsJson plan packageName (lockComponents packageLock)
  pure . Json.object $
    [ ("name", Json.string packageName)
    , ("version", Json.string (prettyShow (pkgVersion (package desc))))
    , ("path", Json.string (lockPackagePath packageLock))
    , ("cabalFile", Json.string (lockCabalFile packageLock))
    , ("setupType", Json.string (prettyShow (buildType desc)))
    , ("components", Json.array components)
    ]

componentsJson :: ResolvedPlan -> String -> [LockComponent] -> Either String [Json]
componentsJson plan packageName components =
  traverse (componentJson plan packageName) (sortOn lockComponentName components)

componentJson :: ResolvedPlan -> String -> LockComponent -> Either String Json
componentJson plan packageName component = do
  planned <- localComponentPlan plan packageName (renderLockComponentName (lockComponentName component))
  pure . Json.object $
    [ ("name", Json.string (renderLockComponentName (lockComponentName component)))
    , ("unitId", Json.string (renderUnitId (localUnitId planned)))
    , ("kind", Json.string (renderComponentKind (lockComponentKind component)))
    , ("sourceDirs", Json.stringArray (sort (map prettyShow (hsSourceDirs buildInfo'))))
    , ("modules", Json.stringArray (sort (lockComponentModules component)))
    , ("main", maybe Json.JsonNull Json.string (lockComponentMain component))
    , ("signatures", Json.stringArray (sort (lockComponentSignatures component)))
    , ("dependencies", Json.stringArray (sort (map prettyShow (targetBuildDepends buildInfo'))))
    , ("externalDepends", unitIdArray (localUnitExternalDepends planned))
    , ("externalExeDepends", unitIdArray (localUnitExternalExeDepends planned))
    , ("defaultExtensions", Json.stringArray (sort (map prettyShow (defaultExtensions buildInfo'))))
    , ("needsFullDb", Json.bool (lockComponentNeedsFullDb component))
    ]
      ++ optionalStringArray "cSources" (cSources buildInfo')
      ++ optionalStringArray "includeDirs" (includeDirs buildInfo')
      ++ optionalStringArray "includes" (includes buildInfo')
      ++ optionalStringArray "installIncludes" (installIncludes buildInfo')
      ++ optionalStringArray "ccOptions" (ccOptions buildInfo')
      ++ optionalStringArray "ldOptions" (ldOptions buildInfo')
      ++ optionalStringArray "extraLibs" (extraLibs buildInfo')
      ++ optionalStringArray "extraLibDirs" (extraLibDirs buildInfo')
      ++ optionalStringArray "frameworks" (frameworks buildInfo')
      ++ optionalStringArray "extraFrameworkDirs" (extraFrameworkDirs buildInfo')
  where
    buildInfo' = lockComponentBuildInfo component

optionalStringArray :: String -> [String] -> [(String, Json)]
optionalStringArray name values =
  if null values
    then []
    else [(name, Json.stringArray values)]

localComponentPlan :: ResolvedPlan -> String -> String -> Either String LocalComponentUnit
localComponentPlan plan packageName componentName =
  case
      [ unit
      | unit <- resolvedLocalComponents plan
      , prettyShow (localUnitPackageName unit) == packageName
      , localUnitComponent unit == componentName
      ]
    of
      [unit] -> Right unit
      [] -> Left ("plan.json has no local unit for `" ++ packageName ++ ":" ++ componentName ++ "`")
      _ -> Left ("plan.json has multiple local units for `" ++ packageName ++ ":" ++ componentName ++ "`")

externalUnitJson :: ExternalUnit -> Json
externalUnitJson unit =
  Json.object $
    [ ("unitId", Json.string (renderUnitId (externalUnitId unit)))
    , ("name", Json.string (prettyShow (externalUnitName unit)))
    , ("version", Json.string (prettyShow (externalUnitVersion unit)))
    , ("flags", flagAssignmentJson (externalUnitFlags unit))
    , ("component", maybe Json.JsonNull Json.string (externalUnitComponent unit))
    , ("style", Json.string (externalUnitStyle unit))
    , ("depends", unitIdArray (externalUnitDepends unit))
    , ("exeDepends", unitIdArray (externalUnitExeDepends unit))
    , ("instantiatedWith", unitIdMap (externalUnitInstantiatedWith unit))
    ]
      ++ case externalUnitSource unit of
        GhcBoot -> [("source", Json.string "ghc-boot")]
        HackageSdist url sha256 ->
          [ ("source", Json.string "hackage")
          , ("flagHash", Json.string (externalUnitFlagHash unit))
          , ("nixExpression", Json.string (externalUnitExpressionName unit))
          , ( "sdist"
            , Json.object
                [ ("url", Json.string (CabalPlan.renderHackageUrl url))
                , ("sha256", Json.string (CabalPlan.renderSdistHash sha256))
                ]
            )
          ]

externalUnitFlagHash :: ExternalUnit -> String
externalUnitFlagHash = take 12 . hashHex . Json.renderJson . flagAssignmentJson . externalUnitFlags

externalUnitExpressionName :: ExternalUnit -> FilePath
externalUnitExpressionName unit =
  prettyShow (externalUnitName unit)
    ++ "-"
    ++ prettyShow (externalUnitVersion unit)
    ++ "-"
    ++ externalUnitFlagHash unit
    ++ ".nix"

flagAssignmentJson :: CabalPlan.FlagAssignment -> Json
flagAssignmentJson assignment =
  Json.object [(name, Json.bool enabled) | (name, enabled) <- renderFlagAssignment assignment]

unitIdArray :: [CabalPlan.UnitId] -> Json
unitIdArray = Json.stringArray . map renderUnitId

unitIdMap :: [(String, CabalPlan.UnitId)] -> Json
unitIdMap entries = Json.object [(name, Json.string (renderUnitId unit)) | (name, unit) <- entries]
