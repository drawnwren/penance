module Penance.Plan
  ( BackpackSkeleton (..)
  , ExpectedInstantiation (..)
  , ExpectedOutputs (..)
  , IndefiniteUnit (..)
  , LocalComponent (..)
  , LocalPackage (..)
  , ProjectSkeleton (..)
  , drvFileFor
  , readSkeleton
  , writeJsonFile
  , writePlannerTrace
  )
where

import Penance.Json (Json (..), renderJson)
import qualified Penance.Json as Json
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Exit (die)
import System.FilePath ((</>))

data ProjectSkeleton = ProjectSkeleton
  { skeletonPath :: FilePath
  , projectKey :: String
  , localPackages :: [LocalPackage]
  , sourceRepos :: [[(String, String)]]
  , planCacheKey :: String
  , plannerDrvInputs :: [String]
  , granularity :: String
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
  deriving (Eq, Show)

data LocalComponent = LocalComponent
  { componentName :: String
  , componentKind :: String
  , componentProvidedModules :: [String]
  , componentSignatures :: [String]
  , componentRequiredSignatures :: [String]
  , componentMixins :: [String]
  , componentReexportedModules :: [String]
  }
  deriving (Eq, Show)

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
  deriving (Eq, Show)

data ExpectedInstantiation = ExpectedInstantiation
  { instantiationUnit :: String
  , instantiationHoles :: [(String, String)]
  }
  deriving (Eq, Show)

data ExpectedOutputs = ExpectedOutputs
  { componentGraphDrv :: Bool
  , moduleGraphDrv :: Bool
  , backpackGraphDrv :: Bool
  }
  deriving (Eq, Show)

readSkeleton :: FilePath -> IO ProjectSkeleton
readSkeleton path = do
  contents <- readFile path
  case Json.parseJson contents >>= decodeProjectSkeleton path of
    Left err -> die ("failed to parse ProjectSkeleton: " ++ err)
    Right skeleton -> pure skeleton

writePlannerTrace :: FilePath -> ProjectSkeleton -> IO ()
writePlannerTrace out skeleton = do
  createDirectoryIfMissing True out
  copyFile (skeletonPath skeleton) (out </> "project-skeleton.trace.json")

writeJsonFile :: FilePath -> Json -> IO ()
writeJsonFile path value =
  writeFile path (renderJson value ++ "\n")

drvFileFor :: String -> String
drvFileFor name = safeFileName name ++ ".drv.plan.json"

decodeProjectSkeleton :: FilePath -> Json -> Either String ProjectSkeleton
decodeProjectSkeleton path value = do
  fields <- asObject "ProjectSkeleton" value
  ProjectSkeleton path
    <$> stringField "projectKey" fields
    <*> arrayField "localPackages" decodeLocalPackage fields
    <*> arrayField "sourceRepos" decodeStringMap fields
    <*> stringField "planCacheKey" fields
    <*> stringListField "plannerDrvInputs" fields
    <*> stringField "granularity" fields
    <*> (field "backpack" fields >>= decodeBackpackSkeleton)
    <*> (field "expectedOutputs" fields >>= decodeExpectedOutputs)

decodeLocalPackage :: Json -> Either String LocalPackage
decodeLocalPackage value = do
  fields <- asObject "LocalPackage" value
  LocalPackage
    <$> stringField "name" fields
    <*> stringField "version" fields
    <*> stringListField "components" fields
    <*> arrayField "componentDetails" decodeLocalComponent fields
    <*> stringListField "signatures" fields
    <*> stringListField "requiredSignatures" fields
    <*> stringListField "providedModules" fields

decodeLocalComponent :: Json -> Either String LocalComponent
decodeLocalComponent value = do
  fields <- asObject "LocalComponent" value
  LocalComponent
    <$> stringField "component" fields
    <*> stringField "kind" fields
    <*> stringListField "providedModules" fields
    <*> stringListField "signatures" fields
    <*> stringListField "requiredSignatures" fields
    <*> stringListField "mixins" fields
    <*> stringListField "reexportedModules" fields

decodeBackpackSkeleton :: Json -> Either String BackpackSkeleton
decodeBackpackSkeleton value = do
  fields <- asObject "BackpackSkeleton" value
  BackpackSkeleton
    <$> arrayField "indefiniteUnits" decodeIndefiniteUnit fields
    <*> arrayField "expectedInstantiations" decodeExpectedInstantiation fields

decodeIndefiniteUnit :: Json -> Either String IndefiniteUnit
decodeIndefiniteUnit value = do
  fields <- asObject "IndefiniteUnit" value
  IndefiniteUnit
    <$> stringField "unit" fields
    <*> stringField "package" fields
    <*> stringField "component" fields
    <*> stringListField "signatures" fields
    <*> stringListField "requiredSignatures" fields
    <*> stringListField "mixins" fields
    <*> stringListField "reexportedModules" fields

decodeExpectedInstantiation :: Json -> Either String ExpectedInstantiation
decodeExpectedInstantiation value = do
  fields <- asObject "ExpectedInstantiation" value
  ExpectedInstantiation
    <$> stringField "unit" fields
    <*> (field "holes" fields >>= decodeStringMap)

decodeExpectedOutputs :: Json -> Either String ExpectedOutputs
decodeExpectedOutputs value = do
  fields <- asObject "ExpectedOutputs" value
  ExpectedOutputs
    <$> boolField "componentGraphDrv" fields
    <*> boolField "moduleGraphDrv" fields
    <*> boolField "backpackGraphDrv" fields

decodeStringMap :: Json -> Either String [(String, String)]
decodeStringMap value = do
  fields <- asObject "string map" value
  traverse decodeEntry fields
  where
    decodeEntry (name, JsonString value') = Right (name, value')
    decodeEntry (name, _) = Left ("expected string value in object field `" ++ name ++ "`")

field :: String -> [(String, Json)] -> Either String Json
field name fields =
  case lookup name fields of
    Just value -> Right value
    Nothing -> Left ("missing required JSON field `" ++ name ++ "`")

stringField :: String -> [(String, Json)] -> Either String String
stringField name fields =
  field name fields >>= asString name

boolField :: String -> [(String, Json)] -> Either String Bool
boolField name fields =
  field name fields >>= asBool name

stringListField :: String -> [(String, Json)] -> Either String [String]
stringListField name fields =
  arrayField name (asString name) fields

arrayField :: String -> (Json -> Either String a) -> [(String, Json)] -> Either String [a]
arrayField name decode fields =
  field name fields >>= asArray name >>= traverse decode

asObject :: String -> Json -> Either String [(String, Json)]
asObject _ (JsonObject fields) = Right fields
asObject context other = Left ("expected JSON object for " ++ context ++ ", got " ++ show other)

asArray :: String -> Json -> Either String [Json]
asArray _ (JsonArray values) = Right values
asArray context other = Left ("expected JSON array for `" ++ context ++ "`, got " ++ show other)

asString :: String -> Json -> Either String String
asString _ (JsonString value) = Right value
asString context other = Left ("expected JSON string for `" ++ context ++ "`, got " ++ show other)

asBool :: String -> Json -> Either String Bool
asBool _ (JsonBool value) = Right value
asBool context other = Left ("expected JSON bool for `" ++ context ++ "`, got " ++ show other)

safeFileName :: String -> String
safeFileName =
  map
    ( \ch ->
        if ch == '/' || ch == '\\' || ch == ' ' || ch == '(' || ch == ')' || ch == ','
          then '_'
          else ch
    )
