module Penance.GhcMakefile
  ( ModuleDep (..)
  , moduleGraphFromMakefile
  , moduleOrderFromMakefile
  )
where

import Data.Char (isSpace)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (intercalate, isSuffixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Penance.Error (throwGraphError)
import Penance.Utf8.IO (readUtf8File)
import System.Directory (doesFileExist)

data ObjectRule = ObjectRule
  { ruleObject :: FilePath
  , ruleDeps :: [FilePath]
  }
  deriving (Eq, Show)

data ObjectDeps = ObjectDeps
  { objectPath :: FilePath
  , objectSource :: Maybe FilePath
  , objectHiDeps :: [FilePath]
  }
  deriving (Eq, Show)

data ModuleDep = ModuleDep
  { moduleSource :: FilePath
  , moduleHiDeps :: [FilePath]
  , moduleSourceDeps :: [FilePath]
  }
  deriving (Eq, Show)

moduleOrderFromMakefile :: FilePath -> IO [FilePath]
moduleOrderFromMakefile makefile =
  map moduleSource <$> moduleGraphFromMakefile makefile

moduleGraphFromMakefile :: FilePath -> IO [ModuleDep]
moduleGraphFromMakefile makefile = do
  logicalLines <- readLogicalLines makefile
  let objectRules = mapMaybe parseObjectRule (filter (elem ':') logicalLines)
      depsByObject =
        Map.fromListWith
          (++)
          [ (ruleObject rule, ruleDeps rule)
          | rule <- objectRules
          ]
  objectDeps <- traverse objectDepsFromRule (Map.toList depsByObject)
  let sourceByObject =
        [ (objectPath deps, source)
        | deps <- objectDeps
        , not (null (objectPath deps))
        , Just source <- [objectSource deps]
        ]
      sourceByHi =
        Map.fromList
          [ (generatedHi object, source)
          | (object, source) <- sourceByObject
          ]
      depsBySource =
        Map.fromListWith
          (++)
          [ (source, objectHiDeps deps)
          | deps <- objectDeps
          , Just source <- [objectSource deps]
          ]
  order <- either throwGraphError pure (topoSort makefile sourceByHi depsBySource)
  pure
    [ ModuleDep
        { moduleSource = source
        , moduleHiDeps = uniqueSorted (Map.findWithDefault [] source depsBySource)
        , moduleSourceDeps = sourceDeps source (Map.findWithDefault [] source depsBySource) sourceByHi
        }
    | source <- order
    ]

readLogicalLines :: FilePath -> IO [String]
readLogicalLines makefile = do
  physical <- lines <$> readUtf8File makefile
  pure (go [] physical)
  where
    go parts [] = [concat (reverse parts) | not (null parts)]
    go parts (line0 : rest) =
      let line = stripTrailingCR line0
       in case stripTrailingBackslash line of
            Just continued -> go (" " : continued : parts) rest
            Nothing -> concat (reverse (line : parts)) : go [] rest

parseObjectRule :: String -> Maybe ObjectRule
parseObjectRule line =
  case break (== ':') line of
    (targetsText, _ : depsText) ->
      let targets = splitMakeWords targetsText
          deps = splitMakeWords depsText
       in case filter isObjectTarget targets of
            [] -> Nothing
            firstObject : _ ->
              Just ObjectRule {ruleObject = firstObject, ruleDeps = deps}
    _ ->
      Nothing

objectDepsFromRule :: (FilePath, [FilePath]) -> IO ObjectDeps
objectDepsFromRule (object, deps) = do
  source <- firstExistingSource deps
  pure
    ObjectDeps
      { objectPath = object
      , objectSource = source
      , objectHiDeps = filter isHiDependency deps
      }

firstExistingSource :: [FilePath] -> IO (Maybe FilePath)
firstExistingSource deps =
  case filter isHaskellSource deps of
    [] -> pure Nothing
    candidates -> go candidates
  where
    go [] = pure Nothing
    go (candidate : rest) = do
      exists <- doesFileExist candidate
      if exists
        then pure (Just candidate)
        else go rest

topoSort :: FilePath -> Map.Map FilePath FilePath -> Map.Map FilePath [FilePath] -> Either String [FilePath]
topoSort makefile sourceByHi depsBySource =
  case [cycleSources | CyclicSCC cycleSources <- components] of
    cycleSources : _ ->
      Left
        ( "cycle in "
            ++ makefile
            ++ ": "
            ++ intercalate " -> " (cycleSources ++ take 1 cycleSources)
        )
    [] -> Right [source | AcyclicSCC source <- components]
  where
    components = stronglyConnComp (map graphNode (Map.keys depsBySource))
    graphNode source =
      ( source
      , source
      , uniqueSorted
          [ dependencySource
          | hi <- Map.findWithDefault [] source depsBySource
          , Just dependencySource <- [Map.lookup hi sourceByHi]
          , dependencySource /= source
          ]
      )

splitMakeWords :: String -> [String]
splitMakeWords = reverse . finish . foldl step (False, [], [])
  where
    step (escaped, current, values) ch
      | escaped = (False, ch : current, values)
      | ch == '\\' = (True, current, values)
      | isSpace ch = emit current values
      | otherwise = (False, ch : current, values)
    finish (escaped, current, values) =
      let finalCurrent = if escaped then '\\' : current else current
       in third (emit finalCurrent values)
    emit [] values = (False, [], values)
    emit current values = (False, [], reverse current : values)
    third (_, _, value) = value

isObjectTarget :: FilePath -> Bool
isObjectTarget path =
  isBootObjectTarget path
    || (".o" `isSuffixOf` path && not (".dyn_o" `isSuffixOf` path))

isBootObjectTarget :: FilePath -> Bool
isBootObjectTarget path =
  ".o-boot" `isSuffixOf` path

isHaskellSource :: FilePath -> Bool
isHaskellSource path =
  ".hs" `isSuffixOf` path || ".lhs" `isSuffixOf` path || ".hs-boot" `isSuffixOf` path

isHiDependency :: FilePath -> Bool
isHiDependency path =
  ".hi" `isSuffixOf` path || ".hi-boot" `isSuffixOf` path

replaceSuffix :: String -> String -> FilePath -> FilePath
replaceSuffix old new path
  | old `isSuffixOf` path = take (length path - length old) path ++ new
  | otherwise = path

generatedHi :: FilePath -> FilePath
generatedHi object
  | isBootObjectTarget object = replaceSuffix ".o-boot" ".hi-boot" object
  | otherwise = replaceSuffix ".o" ".hi" object

sourceDeps :: FilePath -> [FilePath] -> Map.Map FilePath FilePath -> [FilePath]
sourceDeps source hiDeps sourceByHi =
  uniqueSorted
    [ depSource
    | hi <- hiDeps
    , Just depSource <- [Map.lookup hi sourceByHi]
    , depSource /= source
    ]

uniqueSorted :: Ord a => [a] -> [a]
uniqueSorted =
  Set.toAscList . Set.fromList

stripTrailingCR :: String -> String
stripTrailingCR line =
  case reverse line of
    '\r' : rest -> reverse rest
    _ -> line

stripTrailingBackslash :: String -> Maybe String
stripTrailingBackslash line =
  case reverse line of
    '\\' : rest -> Just (reverse rest)
    _ -> Nothing
