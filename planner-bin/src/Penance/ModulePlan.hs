module Penance.ModulePlan
  ( writeModulePlan
  )
where

import Data.Char (isSpace)
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Set as Set
import Penance.GhcMakefile (ModuleDep (..), moduleGraphFromMakefile)
import Penance.Json (Json (..), array, bool, object, renderJson, string)
import qualified Penance.Json as Json
import System.Exit (die)

data LockComponent = LockComponent
  { lockComponentName :: String
  , lockSourceDirs :: [FilePath]
  , lockDefaultExtensions :: [String]
  }
  deriving (Eq, Show)

data ModulePlan = ModulePlan
  { planSource :: FilePath
  , planDeps :: [FilePath]
  , planHiDeps :: [FilePath]
  , planExtensions :: [String]
  , planAnnPragma :: Bool
  }
  deriving (Eq, Show)

writeModulePlan :: FilePath -> FilePath -> String -> FilePath -> IO ()
writeModulePlan makefile lockPath componentName out = do
  components <- readLockComponents lockPath
  graph <- moduleGraphFromMakefile makefile
  plans <- traverse (modulePlanFor components) graph
  writeFile out (renderJson (planJson componentName plans) ++ "\n")

readLockComponents :: FilePath -> IO [LockComponent]
readLockComponents lockPath = do
  contents <- readFile lockPath
  case Json.parseJson contents >>= decodeLockComponents of
    Left err -> die ("failed to parse lock components from " ++ lockPath ++ ": " ++ err)
    Right components -> pure components

decodeLockComponents :: Json -> Either String [LockComponent]
decodeLockComponents value = do
  fields <- asObject "lock" value
  packages <- field "packages" fields >>= asArray "packages"
  concat <$> traverse decodePackageComponents packages

decodePackageComponents :: Json -> Either String [LockComponent]
decodePackageComponents value = do
  fields <- asObject "package" value
  components <- field "components" fields >>= asArray "components"
  traverse decodeLockComponent components

decodeLockComponent :: Json -> Either String LockComponent
decodeLockComponent value = do
  fields <- asObject "component" value
  LockComponent
    <$> (field "name" fields >>= asString "component.name")
    <*> (field "sourceDirs" fields >>= stringArray "component.sourceDirs")
    <*> (field "defaultExtensions" fields >>= stringArray "component.defaultExtensions")

modulePlanFor :: [LockComponent] -> ModuleDep -> IO ModulePlan
modulePlanFor components dep = do
  contents <- readFile (moduleSource dep)
  let componentExts =
        uniqueSorted
          [ ext
          | component <- components
          , sourceInComponent (moduleSource dep) component
          , ext <- lockDefaultExtensions component
          ]
      sourceExts = languagePragmas contents
      annPragma = hasAnnPragma contents
  pure
    ModulePlan
      { planSource = moduleSource dep
      , planDeps = moduleSourceDeps dep
      , planHiDeps = moduleHiDeps dep
      , planExtensions = uniqueSorted (componentExts ++ sourceExts)
      , planAnnPragma = annPragma
      }

sourceInComponent :: FilePath -> LockComponent -> Bool
sourceInComponent source component =
  any inDir (map normalizeSourceDir (lockSourceDirs component))
  where
    inDir dir =
      dir == "."
        || source == dir
        || (dir ++ "/") `isPrefixOf` source

normalizeSourceDir :: FilePath -> FilePath
normalizeSourceDir dir =
  let noPrefix = dropPrefix "./" dir
      noSuffix = dropSuffix "/" noPrefix
   in if null noSuffix then "." else noSuffix

languagePragmas :: String -> [String]
languagePragmas contents =
  uniqueSorted (concatMap pragmasFromLine (lines contents))

pragmasFromLine :: String -> [String]
pragmasFromLine line =
  case stripPrefix "{-# LANGUAGE" (trim line) of
    Nothing -> []
    Just rest ->
      let body = trim (dropSuffix "#-}" rest)
       in filter (not . null) (map (trim . dropSuffix ",") (splitByComma body))

hasAnnPragma :: String -> Bool
hasAnnPragma contents =
  any (isPrefixOf "{-# ANN" . trim) (lines contents)

planJson :: String -> [ModulePlan] -> Json
planJson componentName plans =
  object
    [ ("schema", string "penance/module-plan/1")
    , ("component", string componentName)
    , ("modules", array (map moduleJson plans))
    ]

moduleJson :: ModulePlan -> Json
moduleJson plan =
  object
    [ ("source", string (planSource plan))
    , ("deps", array (map string (planDeps plan)))
    , ("hiDeps", array (map string (planHiDeps plan)))
    , ("extensions", array (map string (planExtensions plan)))
    , ("ann", bool (planAnnPragma plan))
    , ("db", string (if needsDbFull plan then "dbFull" else "dbIface"))
    ]

needsDbFull :: ModulePlan -> Bool
needsDbFull plan =
  planAnnPragma plan
    || any (`elem` thExtensions) (planExtensions plan)

thExtensions :: [String]
thExtensions =
  [ "QuasiQuotes"
  , "TemplateHaskell"
  , "TemplateHaskellQuotes"
  ]

field :: String -> [(String, Json)] -> Either String Json
field name fields =
  case lookup name fields of
    Just value -> Right value
    Nothing -> Left ("missing required JSON field `" ++ name ++ "`")

asObject :: String -> Json -> Either String [(String, Json)]
asObject _ (JsonObject fields) = Right fields
asObject context other = Left ("expected object for " ++ context ++ ", got " ++ show other)

asArray :: String -> Json -> Either String [Json]
asArray _ (JsonArray values) = Right values
asArray context other = Left ("expected array for " ++ context ++ ", got " ++ show other)

asString :: String -> Json -> Either String String
asString _ (JsonString value) = Right value
asString context other = Left ("expected string for " ++ context ++ ", got " ++ show other)

stringArray :: String -> Json -> Either String [String]
stringArray context value =
  asArray context value >>= traverse (asString context)

splitByComma :: String -> [String]
splitByComma "" = [""]
splitByComma value =
  case break (== ',') value of
    (prefix, "") -> [prefix]
    (prefix, _ : rest) -> prefix : splitByComma rest

trim :: String -> String
trim =
  dropWhileEnd isSpace . dropWhile isSpace

dropWhileEnd :: (a -> Bool) -> [a] -> [a]
dropWhileEnd predicate =
  reverse . dropWhile predicate . reverse

stripPrefix :: String -> String -> Maybe String
stripPrefix prefix value
  | prefix `isPrefixOf` value = Just (drop (length prefix) value)
  | otherwise = Nothing

dropPrefix :: String -> String -> String
dropPrefix prefix value =
  case stripPrefix prefix value of
    Just rest -> rest
    Nothing -> value

dropSuffix :: String -> String -> String
dropSuffix suffix value
  | suffix `isSuffixOf` value = take (length value - length suffix) value
  | otherwise = value

uniqueSorted :: Ord a => [a] -> [a]
uniqueSorted =
  Set.toAscList . Set.fromList
