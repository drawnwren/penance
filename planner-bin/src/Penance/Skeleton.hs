module Penance.Skeleton
  ( ProjectSkeleton (..)
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

import Data.List (sort)
import Penance.Json (Json (..))
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
  , projectKey :: String
  , localPackages :: [LocalPackage]
  , sourceRepos :: [[(String, String)]]
  , planCacheKey :: String
  , plannerDrvInputs :: [String]
  , granularity :: Granularity
  , backpack :: BackpackSkeleton
  , expectedOutputs :: ExpectedOutputs
  }
  deriving (Eq, Show)

data LocalPackage = LocalPackage
  { packageName :: String
  , packageVersion :: String
  , packageComponents :: [String]
  , packageComponentDetails :: [LocalComponent]
  , packageSignatures :: [String]
  , packageRequiredSignatures :: [String]
  , packageProvidedModules :: [String]
  }
  deriving (Eq, Ord, Show)

data LocalComponent = LocalComponent
  { componentName :: String
  , componentKind :: ComponentKind
  , componentProvidedModules :: [String]
  , componentSignatures :: [String]
  , componentRequiredSignatures :: [String]
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
  { indefiniteUnit :: String
  , indefinitePackage :: String
  , indefiniteComponent :: String
  , indefiniteSignatures :: [String]
  , indefiniteRequiredSignatures :: [String]
  , indefiniteMixins :: [String]
  , indefiniteReexportedModules :: [String]
  }
  deriving (Eq, Ord, Show)

data ExpectedInstantiation = ExpectedInstantiation
  { instantiationUnit :: String
  , instantiationHoles :: [(String, String)]
  }
  deriving (Eq, Ord, Show)

data ExpectedOutputs = ExpectedOutputs
  { componentGraphDrv :: Bool
  , moduleGraphDrv :: Bool
  , backpackGraphDrv :: Bool
  }
  deriving (Eq, Show)

encodeProjectSkeleton :: ProjectSkeleton -> Json
encodeProjectSkeleton = JsonObject . codecEnc projectSkeletonCodec

decodeProjectSkeleton :: FilePath -> Json -> Either String ProjectSkeleton
decodeProjectSkeleton path value = do
  fields <- asObject "ProjectSkeleton" value
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

nested :: Codec a a -> Value a
nested codec =
  Value (JsonObject . codecEnc codec) $ \key value ->
    case value of
      JsonObject fields -> codecDec codec fields
      other -> Left ("expected JSON object for `" ++ key ++ "`, got " ++ show other)

asObject :: String -> Json -> Either String [(String, Json)]
asObject _ (JsonObject fields) = Right fields
asObject context other =
  Left ("expected JSON object for " ++ context ++ ", got " ++ show other)

-- | Decodes to a @FilePath -> ProjectSkeleton@ because @skeletonPath@ is
-- supplied out of band rather than read from JSON.
projectSkeletonCodec :: Codec ProjectSkeleton (FilePath -> ProjectSkeleton)
projectSkeletonCodec =
  assemble
    <$> field "projectKey" projectKey vstring
    <*> field "localPackages" localPackages (vlist (nested localPackageCodec))
    <*> field "sourceRepos" sourceRepos (vlist vstringMap)
    <*> field "planCacheKey" planCacheKey vstring
    <*> field "plannerDrvInputs" plannerDrvInputs (vlist vstring)
    <*> field "granularity" granularity vgranularity
    <*> field "backpack" backpack (nested backpackCodec)
    <*> field "expectedOutputs" expectedOutputs (nested expectedOutputsCodec)
  where
    assemble pk lps repos cacheKey drvInputs gran bp outs path =
      ProjectSkeleton path pk lps repos cacheKey drvInputs gran bp outs

localPackageCodec :: Codec LocalPackage LocalPackage
localPackageCodec =
  LocalPackage
    <$> field "name" packageName vstring
    <*> field "version" packageVersion vstring
    <*> field "components" packageComponents (vlist vstring)
    <*> field "componentDetails" packageComponentDetails (vlist (nested localComponentCodec))
    <*> field "signatures" packageSignatures (vlist vstring)
    <*> field "requiredSignatures" packageRequiredSignatures (vlist vstring)
    <*> field "providedModules" packageProvidedModules (vlist vstring)

localComponentCodec :: Codec LocalComponent LocalComponent
localComponentCodec =
  LocalComponent
    <$> field "component" componentName vstring
    <*> field "kind" componentKind vcomponentKind
    <*> field "providedModules" componentProvidedModules (vlist vstring)
    <*> field "signatures" componentSignatures (vlist vstring)
    <*> field "requiredSignatures" componentRequiredSignatures (vlist vstring)
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
    <$> field "unit" indefiniteUnit vstring
    <*> field "package" indefinitePackage vstring
    <*> field "component" indefiniteComponent vstring
    <*> field "signatures" indefiniteSignatures (vlist vstring)
    <*> field "requiredSignatures" indefiniteRequiredSignatures (vlist vstring)
    <*> field "mixins" indefiniteMixins (vlist vstring)
    <*> field "reexportedModules" indefiniteReexportedModules (vlist vstring)

expectedInstantiationCodec :: Codec ExpectedInstantiation ExpectedInstantiation
expectedInstantiationCodec =
  ExpectedInstantiation
    <$> field "unit" instantiationUnit vstring
    <*> field "holes" instantiationHoles vstringMap

expectedOutputsCodec :: Codec ExpectedOutputs ExpectedOutputs
expectedOutputsCodec =
  ExpectedOutputs
    <$> field "componentGraphDrv" componentGraphDrv vbool
    <*> field "moduleGraphDrv" moduleGraphDrv vbool
    <*> field "backpackGraphDrv" backpackGraphDrv vbool
