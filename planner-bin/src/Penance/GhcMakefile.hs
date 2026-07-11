module Penance.GhcMakefile
  ( ModuleDep (..)
  , moduleGraphFromMakefile
  , moduleOrderFromMakefile
  )
where

import Data.List (isSuffixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import System.Directory (doesFileExist)
import System.Exit (die)

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
  order <- topoSort makefile sourceByHi depsBySource
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
  physical <- lines <$> readFile makefile
  pure (go "" physical)
  where
    go acc [] = [acc | not (null acc)]
    go acc (line0 : rest) =
      let line = stripTrailingCR line0
       in case stripTrailingBackslash line of
            Just continued -> go (acc ++ continued ++ " ") rest
            Nothing -> (acc ++ line) : go "" rest

parseObjectRule :: String -> Maybe ObjectRule
parseObjectRule line =
  case break (== ':') line of
    (targetsText, _ : depsText) ->
      let targets = words targetsText
          deps = words depsText
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

topoSort :: FilePath -> Map.Map FilePath FilePath -> Map.Map FilePath [FilePath] -> IO [FilePath]
topoSort makefile sourceByHi depsBySource =
  go Set.empty (Set.fromList (Map.keys depsBySource)) []
  where
    go _ remaining order
      | Set.null remaining = pure (reverse order)
    go done remaining order = do
      let ready = filter (isReady done) (Set.toAscList remaining)
      case ready of
        [] ->
          die ("cycle or missing dependency in " ++ makefile ++ ": " ++ unwords (Set.toAscList remaining))
        _ -> do
          let readySet = Set.fromList ready
          go
            (Set.union done readySet)
            (Set.difference remaining readySet)
            (reverse ready ++ order)

    isReady done source =
      all dependencyDone (Map.findWithDefault [] source depsBySource)
      where
        dependencyDone hi =
          case Map.lookup hi sourceByHi of
            Nothing -> True
            Just dependencySource -> dependencySource == source || Set.member dependencySource done

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
