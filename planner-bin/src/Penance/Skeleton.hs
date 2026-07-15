module Penance.Skeleton
  ( ProjectSkeleton (..)
  , ProjectKey
  , PlanCacheKey
  , projectKeyFromDigest
  , planCacheKeyFromDigest
  , renderProjectKey
  , renderPlanCacheKey
  , PkgName
  , ComponentId
  , ModuleName
  , UnitKey
  , mkPkgName
  , mkComponentId
  , mkModuleName
  , parseUnitKey
  , componentUnitKey
  , moduleUnitKey
  , renderPkgName
  , renderComponentId
  , renderModuleName
  , renderUnitKey
  , LocalPackage (..)
  , LocalComponent (..)
  , BackpackSkeleton (..)
  , IndefiniteUnit (..)
  , ExpectedInstantiation (..)
  , ExpectedOutputs (..)

  , encodeProjectSkeleton
  , decodeProjectSkeleton
  , encodeLocalPackage
  ) where

import Data.List (sort, stripPrefix)
import Penance.Blake3 (Blake3Digest, parseBlake3Digest, renderBlake3Digest)
import Penance.Json (Json (..))
import qualified Penance.Json.Decode as Decode
import Penance.Types
  ( ComponentKind
  , Granularity
  , parseComponentKind
  , parseGranularity
  , renderComponentKind
  , renderGranularity
  )

data ProjectSkeleton = ProjectSkeleton
  { skeletonPath :: FilePath
  , projectKey :: ProjectKey
  , localPackages :: [LocalPackage]
  , sourceRepos :: [[(String, String)]]
  , planCacheKey :: PlanCacheKey
  , plannerDrvInputs :: [String]
  , granularity :: Granularity
  , backpack :: BackpackSkeleton
  , expectedOutputs :: ExpectedOutputs
  }
  deriving (Eq, Show)

newtype ProjectKey = ProjectKey Blake3Digest
  deriving (Eq, Ord, Show)

newtype PlanCacheKey = PlanCacheKey Blake3Digest
  deriving (Eq, Ord, Show)

projectKeyFromDigest :: Blake3Digest -> ProjectKey
projectKeyFromDigest = ProjectKey

planCacheKeyFromDigest :: Blake3Digest -> PlanCacheKey
planCacheKeyFromDigest = PlanCacheKey

renderProjectKey :: ProjectKey -> String
renderProjectKey (ProjectKey digest) = "blake3:" ++ renderBlake3Digest digest

renderPlanCacheKey :: PlanCacheKey -> String
renderPlanCacheKey (PlanCacheKey digest) = "blake3:" ++ renderBlake3Digest digest

data LocalPackage = LocalPackage
  { packageName :: PkgName
  , packageVersion :: String
  , packageComponents :: [ComponentId]
  , packageComponentDetails :: [LocalComponent]
  , packageSignatures :: [ModuleName]
  , packageRequiredSignatures :: [ModuleName]
  , packageProvidedModules :: [ModuleName]
  }
  deriving (Eq, Ord, Show)

data LocalComponent = LocalComponent
  { componentName :: ComponentId
  , componentKind :: ComponentKind
  , componentProvidedModules :: [ModuleName]
  , componentSignatures :: [ModuleName]
  , componentRequiredSignatures :: [ModuleName]
  , componentMixins :: [String]
  , componentReexportedModules :: [String]
  }
  deriving (Eq, Ord, Show)

data BackpackSkeleton = BackpackSkeleton
  { indefiniteUnits :: [IndefiniteUnit]
  , expectedInstantiations :: [ExpectedInstantiation]
  }
  deriving (Eq, Show)

data IndefiniteUnit = IndefiniteUnit
  { indefiniteUnit :: UnitKey
  , indefinitePackage :: PkgName
  , indefiniteComponent :: ComponentId
  , indefiniteSignatures :: [ModuleName]
  , indefiniteRequiredSignatures :: [ModuleName]
  , indefiniteMixins :: [String]
  , indefiniteReexportedModules :: [String]
  }
  deriving (Eq, Ord, Show)

data ExpectedInstantiation = ExpectedInstantiation
  { instantiationUnit :: UnitKey
  , instantiationHoles :: [(ModuleName, String)]
  }
  deriving (Eq, Ord, Show)

data ExpectedOutputs = ExpectedOutputs
  { componentGraphDrv :: Bool
  , moduleGraphDrv :: Bool
  , backpackGraphDrv :: Bool
  }
  deriving (Eq, Show)

newtype PkgName = PkgName String
  deriving (Eq, Ord, Show)

newtype ComponentId = ComponentId String
  deriving (Eq, Ord, Show)

newtype ModuleName = ModuleName String
  deriving (Eq, Ord, Show)

newtype UnitKey = UnitKey String
  deriving (Eq, Ord, Show)

mkPkgName :: String -> Either String PkgName
mkPkgName = fmap PkgName . validateName "package name"

mkComponentId :: String -> Either String ComponentId
mkComponentId = fmap ComponentId . validateName "component ID"

mkModuleName :: String -> Either String ModuleName
mkModuleName = fmap ModuleName . validateName "module name"

parseUnitKey :: String -> Either String UnitKey
parseUnitKey = fmap UnitKey . validateName "unit key"

componentUnitKey :: PkgName -> ComponentId -> UnitKey
componentUnitKey package component =
  UnitKey (renderPkgName package ++ ":" ++ renderComponentId component)

moduleUnitKey :: UnitKey -> ModuleName -> UnitKey
moduleUnitKey unit moduleName =
  UnitKey (renderUnitKey unit ++ ":" ++ renderModuleName moduleName)

renderPkgName :: PkgName -> String
renderPkgName (PkgName name) = name

renderComponentId :: ComponentId -> String
renderComponentId (ComponentId component) = component

renderModuleName :: ModuleName -> String
renderModuleName (ModuleName moduleName) = moduleName

renderUnitKey :: UnitKey -> String
renderUnitKey (UnitKey key) = key

validateName :: String -> String -> Either String String
validateName label value
  | null value = Left (label ++ " must not be empty")
  | '\0' `elem` value = Left (label ++ " must not contain NUL")
  | otherwise = Right value

encodeProjectSkeleton :: ProjectSkeleton -> Json
encodeProjectSkeleton = JsonObject . codecEnc projectSkeletonCodec

decodeProjectSkeleton :: FilePath -> Json -> Either String ProjectSkeleton
decodeProjectSkeleton path value = do
  fields <- Decode.asObject "ProjectSkeleton" value
  mk <- codecDec projectSkeletonCodec fields
  Right (mk path)

encodeLocalPackage :: LocalPackage -> Json
encodeLocalPackage = JsonObject . codecEnc localPackageCodec

data Codec o a = Codec
  { codecEnc :: o -> [(String, Json)]
  , codecDec :: [(String, Json)] -> Either String a
  }

instance Functor (Codec o) where
  fmap f (Codec e d) = Codec e (fmap f . d)

instance Applicative (Codec o) where
  pure x = Codec (const []) (const (Right x))
  Codec ef df <*> Codec ex dx =
    Codec (\o -> ef o ++ ex o) (\fields -> df fields <*> dx fields)

data Value a = Value (a -> Json) (String -> Json -> Either String a)

field :: String -> (o -> a) -> Value a -> Codec o a
field key get (Value venc vdec) =
  Codec
    (\o -> [(key, venc (get o))])
    ( \fields ->
        case lookup key fields of
          Just value -> vdec key value
          Nothing -> Left ("missing required JSON field `" ++ key ++ "`")
    )

vstring :: Value String
vstring =
  Value JsonString $ \key value ->
    case value of
      JsonString s -> Right s
      other -> Left ("expected JSON string for `" ++ key ++ "`, got " ++ show other)

vstringVia :: (a -> String) -> (String -> Either String a) -> Value a
vstringVia render parse =
  Value (JsonString . render) $ \key value ->
    case value of
      JsonString text ->
        case parse text of
          Left err -> Left (key ++ ": " ++ err)
          Right parsed -> Right parsed
      other -> Left ("expected JSON string for `" ++ key ++ "`, got " ++ show other)

vgranularity :: Value Granularity
vgranularity = vstringVia renderGranularity parseGranularity

vcomponentKind :: Value ComponentKind
vcomponentKind = vstringVia renderComponentKind parseComponentKind

vpkgName :: Value PkgName
vpkgName = vstringVia renderPkgName mkPkgName

vcomponentId :: Value ComponentId
vcomponentId = vstringVia renderComponentId mkComponentId

vmoduleName :: Value ModuleName
vmoduleName = vstringVia renderModuleName mkModuleName

vunitKey :: Value UnitKey
vunitKey = vstringVia renderUnitKey parseUnitKey

vbool :: Value Bool
vbool =
  Value JsonBool $ \key value ->
    case value of
      JsonBool b -> Right b
      other -> Left ("expected JSON bool for `" ++ key ++ "`, got " ++ show other)

vlist :: Value a -> Value [a]
vlist (Value venc vdec) =
  Value (JsonArray . map venc) $ \key value ->
    case value of
      JsonArray values -> traverse (vdec key) values
      other -> Left ("expected JSON array for `" ++ key ++ "`, got " ++ show other)

-- | An object whose values are all strings, e.g. Backpack holes and source
-- repos. Entries are sorted on encode so output stays canonical.
vstringMap :: Value [(String, String)]
vstringMap =
  Value encodePairs $ \key value ->
    case value of
      JsonObject entries -> traverse decodeEntry entries
      other -> Left ("expected JSON object for `" ++ key ++ "`, got " ++ show other)
  where
    encodePairs pairs =
      JsonObject [(name, JsonString v) | (name, v) <- sort pairs]
    decodeEntry (name, JsonString v) = Right (name, v)
    decodeEntry (name, _) = Left ("expected string value in object field `" ++ name ++ "`")

vmoduleStringMap :: Value [(ModuleName, String)]
vmoduleStringMap =
  Value encodePairs $ \key value ->
    case value of
      JsonObject entries -> traverse decodeEntry entries
      other -> Left ("expected JSON object for `" ++ key ++ "`, got " ++ show other)
  where
    encodePairs pairs =
      JsonObject [(renderModuleName name, JsonString value) | (name, value) <- sort pairs]
    decodeEntry (name, JsonString value) = do
      moduleName <- mkModuleName name
      Right (moduleName, value)
    decodeEntry (name, _) = Left ("expected string value in object field `" ++ name ++ "`")

nested :: Codec a a -> Value a
nested codec =
  Value (JsonObject . codecEnc codec) $ \key value ->
    case value of
      JsonObject fields -> codecDec codec fields
      other -> Left ("expected JSON object for `" ++ key ++ "`, got " ++ show other)

-- | Decodes to a @FilePath -> ProjectSkeleton@ because @skeletonPath@ is
-- supplied out of band rather than read from JSON.
projectSkeletonCodec :: Codec ProjectSkeleton (FilePath -> ProjectSkeleton)
projectSkeletonCodec =
  assemble
    <$> field "projectKey" projectKey vprojectKey
    <*> field "localPackages" localPackages (vlist (nested localPackageCodec))
    <*> field "sourceRepos" sourceRepos (vlist vstringMap)
    <*> field "planCacheKey" planCacheKey vplanCacheKey
    <*> field "plannerDrvInputs" plannerDrvInputs (vlist vstring)
    <*> field "granularity" granularity vgranularity
    <*> field "backpack" backpack (nested backpackCodec)
    <*> field "expectedOutputs" expectedOutputs (nested expectedOutputsCodec)
  where
    assemble pk lps repos cacheKey drvInputs gran bp outs path =
      ProjectSkeleton path pk lps repos cacheKey drvInputs gran bp outs

vprojectKey :: Value ProjectKey
vprojectKey = vstringVia renderProjectKey (fmap ProjectKey . parseDigest "projectKey")

vplanCacheKey :: Value PlanCacheKey
vplanCacheKey = vstringVia renderPlanCacheKey (fmap PlanCacheKey . parseDigest "planCacheKey")

parseDigest :: String -> String -> Either String Blake3Digest
parseDigest label text =
  case stripPrefix "blake3:" text of
    Just digest ->
      case parseBlake3Digest digest of
        Left err -> Left (label ++ ": " ++ err)
        Right value -> Right value
    _ -> Left (label ++ " must be `blake3:` followed by 64 hexadecimal digits")

localPackageCodec :: Codec LocalPackage LocalPackage
localPackageCodec =
  LocalPackage
    <$> field "name" packageName vpkgName
    <*> field "version" packageVersion vstring
    <*> field "components" packageComponents (vlist vcomponentId)
    <*> field "componentDetails" packageComponentDetails (vlist (nested localComponentCodec))
    <*> field "signatures" packageSignatures (vlist vmoduleName)
    <*> field "requiredSignatures" packageRequiredSignatures (vlist vmoduleName)
    <*> field "providedModules" packageProvidedModules (vlist vmoduleName)

localComponentCodec :: Codec LocalComponent LocalComponent
localComponentCodec =
  LocalComponent
    <$> field "component" componentName vcomponentId
    <*> field "kind" componentKind vcomponentKind
    <*> field "providedModules" componentProvidedModules (vlist vmoduleName)
    <*> field "signatures" componentSignatures (vlist vmoduleName)
    <*> field "requiredSignatures" componentRequiredSignatures (vlist vmoduleName)
    <*> field "mixins" componentMixins (vlist vstring)
    <*> field "reexportedModules" componentReexportedModules (vlist vstring)

backpackCodec :: Codec BackpackSkeleton BackpackSkeleton
backpackCodec =
  BackpackSkeleton
    <$> field "indefiniteUnits" indefiniteUnits (vlist (nested indefiniteUnitCodec))
    <*> field "expectedInstantiations" expectedInstantiations (vlist (nested expectedInstantiationCodec))

indefiniteUnitCodec :: Codec IndefiniteUnit IndefiniteUnit
indefiniteUnitCodec =
  IndefiniteUnit
    <$> field "unit" indefiniteUnit vunitKey
    <*> field "package" indefinitePackage vpkgName
    <*> field "component" indefiniteComponent vcomponentId
    <*> field "signatures" indefiniteSignatures (vlist vmoduleName)
    <*> field "requiredSignatures" indefiniteRequiredSignatures (vlist vmoduleName)
    <*> field "mixins" indefiniteMixins (vlist vstring)
    <*> field "reexportedModules" indefiniteReexportedModules (vlist vstring)

expectedInstantiationCodec :: Codec ExpectedInstantiation ExpectedInstantiation
expectedInstantiationCodec =
  ExpectedInstantiation
    <$> field "unit" instantiationUnit vunitKey
    <*> field "holes" instantiationHoles vmoduleStringMap

expectedOutputsCodec :: Codec ExpectedOutputs ExpectedOutputs
expectedOutputsCodec =
  ExpectedOutputs
    <$> field "componentGraphDrv" componentGraphDrv vbool
    <*> field "moduleGraphDrv" moduleGraphDrv vbool
    <*> field "backpackGraphDrv" backpackGraphDrv vbool
