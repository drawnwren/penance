module Penance.ModulePlan
  ( writeModulePlan
  , languagePragmas
  , hasAnnPragma
  , needsDbFullFor
  )
where

import Data.Char (isSpace, toLower)
import Data.List (dropWhileEnd, isPrefixOf, isSuffixOf, stripPrefix)
import qualified Data.Set as Set
import Penance.Error (throwJsonError)
import Penance.GhcMakefile (ModuleDep (..), moduleGraphFromMakefile)
import Penance.Json (Json (..), array, bool, object, renderJson, string)
import qualified Penance.Json as Json
import Penance.Json.Decode (asArray, asObject, asString, field, stringArray)
import Penance.Types
  ( PackageDbKind (..)
  , PenanceSchema (..)
  , renderPackageDbKind
  , renderPenanceSchema
  )
import Penance.Utf8.IO (readUtf8File, writeUtf8File)

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
  writeUtf8File out (renderJson (planJson componentName plans) ++ "\n")

readLockComponents :: FilePath -> IO [LockComponent]
readLockComponents lockPath = do
  contents <- readUtf8File lockPath
  case Json.parseJson contents >>= decodeLockComponents of
    Left err -> throwJsonError ("failed to parse lock components from " ++ lockPath ++ ": " ++ err)
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
  contents <- readUtf8File (moduleSource dep)
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
  uniqueSorted (concatMap languagePragma (pragmaBodies contents))

languagePragma :: String -> [String]
languagePragma body =
  case words body of
    keyword : _
      | map toLower keyword == "language" ->
          let extensions = trim (drop (length keyword) (trim body))
           in filter (not . null) (map (trim . dropSuffix ",") (splitByComma extensions))
    _ -> []

hasAnnPragma :: String -> Bool
hasAnnPragma contents =
  any ((== "ann") . map toLower . firstWord) (pragmaBodies contents)

pragmaBodies :: String -> [String]
pragmaBodies = go
  where
    go source =
      case findSubstring "{-#" source of
        Nothing -> []
        Just afterStart ->
          case breakOn "#-}" afterStart of
            Nothing -> []
            Just (body, remaining) -> trim body : go remaining

firstWord :: String -> String
firstWord value =
  case words value of
    word : _ -> word
    [] -> ""

findSubstring :: String -> String -> Maybe String
findSubstring needle = search
  where
    search [] = Nothing
    search value@(_ : rest)
      | needle `isPrefixOf` value = Just (drop (length needle) value)
      | otherwise = search rest

breakOn :: String -> String -> Maybe (String, String)
breakOn needle = search []
  where
    search _ [] = Nothing
    search prefix value@(ch : rest)
      | needle `isPrefixOf` value = Just (reverse prefix, drop (length needle) value)
      | otherwise = search (ch : prefix) rest

planJson :: String -> [ModulePlan] -> Json
planJson componentName plans =
  object
    [ ("schema", string (renderPenanceSchema ModulePlanSchemaV1))
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
    , ("db", string (renderPackageDbKind (if needsDbFull plan then FullPackageDb else InterfacePackageDb)))
    ]

needsDbFull :: ModulePlan -> Bool
needsDbFull plan = needsDbFullFor (planExtensions plan) (planAnnPragma plan)

needsDbFullFor :: [String] -> Bool -> Bool
needsDbFullFor extensions annPragma =
  annPragma || any (`elem` thExtensions) extensions

thExtensions :: [String]
thExtensions =
  [ "QuasiQuotes"
  , "TemplateHaskell"
  , "TemplateHaskellQuotes"
  ]

splitByComma :: String -> [String]
splitByComma "" = [""]
splitByComma value =
  case break (== ',') value of
    (prefix, "") -> [prefix]
    (prefix, _ : rest) -> prefix : splitByComma rest

trim :: String -> String
trim =
  dropWhileEnd isSpace . dropWhile isSpace

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
