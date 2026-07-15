module Penance.LockLowerer
  ( lowerLockInput
  )
where

import Data.List (sortOn)
import qualified Data.Set as Set
import Penance.Json (Json (..))
import qualified Penance.Json as Json
import Penance.Json.Decode
  ( asArray
  , asObject
  , field
  , rejectUnknown
  , requiredString
  , requiredBool
  )

data LoweredPackage = LoweredPackage
  { loweredPackageName :: String
  , loweredPackageVersion :: String
  , loweredPackagePath :: String
  , loweredPackageCabalFile :: String
  , loweredPackageSetupType :: String
  , loweredPackageComponents :: [LoweredComponent]
  }

data LoweredComponent = LoweredComponent
  { loweredComponentName :: String
  , loweredComponentUnitId :: String
  , loweredComponentKind :: String
  , loweredComponentSourceDirs :: [String]
  , loweredComponentModules :: [String]
  , loweredComponentMain :: Json
  , loweredComponentSignatures :: [String]
  , loweredComponentDependencies :: [String]
  , loweredComponentExternalDepends :: [String]
  , loweredComponentExternalExeDepends :: [String]
  , loweredComponentDefaultExtensions :: [String]
  , loweredComponentNeedsFullDb :: Bool
  }

data LoweredExternal = LoweredExternal
  { loweredExternalUnitId :: String
  , loweredExternalName :: String
  , loweredExternalVersion :: String
  , loweredExternalFlags :: Json
  , loweredExternalComponent :: Json
  , loweredExternalStyle :: String
  , loweredExternalSource :: String
  , loweredExternalDepends :: [String]
  , loweredExternalExeDepends :: [String]
  , loweredExternalInstantiatedWith :: [(String, String)]
  , loweredExternalSdist :: Maybe Json
  , loweredExternalFlagHash :: Maybe String
  , loweredExternalNixExpression :: Maybe String
  }

lowerLockInput :: String -> Either String String
lowerLockInput inputText = do
  input <- Json.parseJson inputText >>= asObject "lowerer input"
  rejectUnknown "lowerer input" ["operation", "lock"] input
  operation <- requiredString "operation" input
  if operation /= "lower-lock"
    then Left ("unsupported planner operation `" ++ operation ++ "`")
    else pure ()
  lock <- field "lock" input >>= asObject "lock"
  schema <- requiredString "schema" lock
  if schema /= "penance/lock/2"
    then Left ("unsupported lock schema `" ++ schema ++ "`")
    else pure ()
  compiler <- requiredString "compiler" lock
  indexState <- requiredString "indexState" lock
  packageSetHash <- optionalString "packageSetHash" lock
  packages <- field "packages" lock >>= asArray "lock.packages" >>= traverse decodePackage
  externalUnits <- field "externalUnits" lock >>= asArray "lock.externalUnits" >>= traverse decodeExternal
  validateUnitGraph packages externalUnits
  pure . Json.renderJson . Json.object $
    [ ("schema", Json.string "penance/lowered-lock/2")
    , ("compiler", Json.string compiler)
    , ("indexState", Json.string indexState)
    , ("packages", Json.array (map encodePackage (sortOn loweredPackageName packages)))
    , ("externalUnits", Json.array (map encodeExternal (sortOn loweredExternalUnitId externalUnits)))
    ]
      ++ maybe [] (\hash -> [("packageSetHash", Json.string hash)]) packageSetHash

decodePackage :: Json -> Either String LoweredPackage
decodePackage value = do
  fields <- asObject "lock package" value
  components <- field "components" fields >>= asArray "package.components" >>= traverse decodeComponent
  LoweredPackage
    <$> requiredString "name" fields
    <*> requiredString "version" fields
    <*> requiredString "path" fields
    <*> requiredString "cabalFile" fields
    <*> requiredString "setupType" fields
    <*> pure (sortOn loweredComponentName components)

decodeComponent :: Json -> Either String LoweredComponent
decodeComponent value = do
  fields <- asObject "lock component" value
  LoweredComponent
    <$> requiredString "name" fields
    <*> requiredString "unitId" fields
    <*> requiredString "kind" fields
    <*> stringList "sourceDirs" fields
    <*> stringList "modules" fields
    <*> field "main" fields
    <*> stringList "signatures" fields
    <*> stringList "dependencies" fields
    <*> stringList "externalDepends" fields
    <*> stringList "externalExeDepends" fields
    <*> stringList "defaultExtensions" fields
    <*> requiredBool "needsFullDb" fields

decodeExternal :: Json -> Either String LoweredExternal
decodeExternal value = do
  fields <- asObject "external unit" value
  source <- requiredString "source" fields
  sdist <- pure (lookup "sdist" fields)
  flagHash <- optionalString "flagHash" fields
  expression <- optionalString "nixExpression" fields
  case source of
    "ghc-boot"
      | sdist == Nothing && flagHash == Nothing && expression == Nothing -> pure ()
      | otherwise -> Left "ghc-boot external unit must not carry Hackage fields"
    "hackage"
      | sdist /= Nothing && flagHash /= Nothing && expression /= Nothing -> pure ()
      | otherwise -> Left "hackage external unit requires sdist, flagHash, and nixExpression"
    _ -> Left ("unsupported external unit source `" ++ source ++ "`")
  LoweredExternal
    <$> requiredString "unitId" fields
    <*> requiredString "name" fields
    <*> requiredString "version" fields
    <*> field "flags" fields
    <*> field "component" fields
    <*> requiredString "style" fields
    <*> pure source
    <*> stringList "depends" fields
    <*> stringList "exeDepends" fields
    <*> stringMap "instantiatedWith" fields
    <*> pure sdist
    <*> pure flagHash
    <*> pure expression

optionalString :: String -> [(String, Json)] -> Either String (Maybe String)
optionalString name fields =
  case lookup name fields of
    Nothing -> Right Nothing
    Just (JsonString value) -> Right (Just value)
    Just other -> Left (name ++ " must be a string, got " ++ show other)

validateUnitGraph :: [LoweredPackage] -> [LoweredExternal] -> Either String ()
validateUnitGraph packages externalUnits = do
  let identifiers = map loweredExternalUnitId externalUnits
      identifierSet = Set.fromList identifiers
      edges =
        concatMap
          ( \unit ->
              loweredExternalDepends unit
                ++ loweredExternalExeDepends unit
                ++ map snd (loweredExternalInstantiatedWith unit)
          )
          externalUnits
          ++ concatMap
            ( concatMap
                (\component -> loweredComponentExternalDepends component ++ loweredComponentExternalExeDepends component)
                . loweredPackageComponents
            )
            packages
      dangling = filter (`Set.notMember` identifierSet) edges
  if length identifiers /= Set.size identifierSet
    then Left "externalUnits contains duplicate unitId values"
    else case dangling of
      identifier : _ -> Left ("lock references missing external unit `" ++ identifier ++ "`")
      [] -> Right ()

stringList :: String -> [(String, Json)] -> Either String [String]
stringList name fields = do
  values <- field name fields >>= asArray name
  traverse decode values
  where
    decode (JsonString value) = Right value
    decode other = Left (name ++ " must contain strings, got " ++ show other)

encodePackage :: LoweredPackage -> Json
encodePackage package =
  Json.object
    [ ("name", Json.string (loweredPackageName package))
    , ("version", Json.string (loweredPackageVersion package))
    , ("path", Json.string (loweredPackagePath package))
    , ("cabalFile", Json.string (loweredPackageCabalFile package))
    , ("setupType", Json.string (loweredPackageSetupType package))
    , ("components", Json.array (map encodeComponent (loweredPackageComponents package)))
    ]

encodeComponent :: LoweredComponent -> Json
encodeComponent component =
  Json.object
    [ ("name", Json.string (loweredComponentName component))
    , ("unitId", Json.string (loweredComponentUnitId component))
    , ("kind", Json.string (loweredComponentKind component))
    , ("sourceDirs", Json.stringArray (loweredComponentSourceDirs component))
    , ("modules", Json.stringArray (loweredComponentModules component))
    , ("main", loweredComponentMain component)
    , ("signatures", Json.stringArray (loweredComponentSignatures component))
    , ("dependencies", Json.stringArray (loweredComponentDependencies component))
    , ("externalDepends", Json.stringArray (loweredComponentExternalDepends component))
    , ("externalExeDepends", Json.stringArray (loweredComponentExternalExeDepends component))
    , ("defaultExtensions", Json.stringArray (loweredComponentDefaultExtensions component))
    , ("needsFullDb", Json.bool (loweredComponentNeedsFullDb component))
    ]

encodeExternal :: LoweredExternal -> Json
encodeExternal external =
  Json.object
    ( [ ("unitId", Json.string (loweredExternalUnitId external))
      , ("name", Json.string (loweredExternalName external))
      , ("version", Json.string (loweredExternalVersion external))
      , ("flags", loweredExternalFlags external)
      , ("component", loweredExternalComponent external)
      , ("style", Json.string (loweredExternalStyle external))
      , ("source", Json.string (loweredExternalSource external))
      , ("depends", Json.stringArray (loweredExternalDepends external))
      , ("exeDepends", Json.stringArray (loweredExternalExeDepends external))
      , ("instantiatedWith", Json.object [(name, Json.string unitId) | (name, unitId) <- loweredExternalInstantiatedWith external])
      ]
        ++ maybe [] (\sdist -> [("sdist", sdist)]) (loweredExternalSdist external)
        ++ maybe [] (\value -> [("flagHash", Json.string value)]) (loweredExternalFlagHash external)
        ++ maybe [] (\value -> [("nixExpression", Json.string value)]) (loweredExternalNixExpression external)
    )


stringMap :: String -> [(String, Json)] -> Either String [(String, String)]
stringMap name fields = do
  entries <- field name fields >>= asObject name
  traverse decode entries
  where
    decode (key, JsonString value) = Right (key, value)
    decode (key, other) = Left (name ++ "." ++ key ++ " must be a string, got " ++ show other)
