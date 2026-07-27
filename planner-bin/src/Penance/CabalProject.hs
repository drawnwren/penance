module Penance.CabalProject
  ( CabalProject (..)
  , parseCabalProject
  , qualifyConstraintForAllScopes
  )
where

import Data.Char (isSpace, toLower)
import Data.List (sort)
import Penance.CabalLex
  ( LogicalLine (..)
  , collectContinuation
  , logicalLines
  , sortNub
  , splitField
  , trim
  , trimCommas
  )

data CabalProject = CabalProject
  { projectPackages :: [FilePath]
  , projectOptionalPackages :: [FilePath]
  , projectSourceRepos :: [[(String, String)]]
  , projectIndexState :: Maybe String
  , projectConstraints :: [String]
  }
  deriving (Eq, Show)

parseCabalProject :: String -> Either String CabalProject
parseCabalProject text = go (logicalLines text) [] [] [] Nothing []
  where
    go [] packages optionalPackages repos indexState constraints =
      Right
        CabalProject
          { projectPackages = sortNub packages
          , projectOptionalPackages = sortNub optionalPackages
          , projectSourceRepos = sort repos
          , projectIndexState = indexState
          , projectConstraints = sortNub constraints
          }
    go (line : rest) packages optionalPackages repos indexState constraints
      | logicalIndent line /= 0 = malformed line
      | map toLower (logicalText line) == "source-repository-package" = do
          (repo, remaining) <- parseSourceRepo rest []
          go remaining packages optionalPackages (sort repo : repos) indexState constraints
      | otherwise = do
          (field, firstValue) <- splitField "cabal.project" line
          let normalizedField = map toLower field
              (value, remaining) = collectContinuation (logicalIndent line) firstValue rest
          case normalizedField of
            "packages" ->
              go
                remaining
                (splitPackageWords value ++ packages)
                optionalPackages
                repos
                indexState
                constraints
            "optional-packages" ->
              go
                remaining
                packages
                (splitPackageWords value ++ optionalPackages)
                repos
                indexState
                constraints
            "index-state" ->
              go remaining packages optionalPackages repos (Just (trim value)) constraints
            "constraints" ->
              go
                remaining
                packages
                optionalPackages
                repos
                indexState
                (splitConstraintValues value ++ constraints)
            _
              | normalizedField `elem` ignoredProjectFields ->
                  go remaining packages optionalPackages repos indexState constraints
              | otherwise ->
                  Left
                    ( "cabal.project line "
                        ++ show (logicalNumber line)
                        ++ ": unsupported construct `"
                        ++ field
                        ++ "`"
                    )
      where
        malformed bad =
          Left
            ( "cabal.project line "
                ++ show (logicalNumber bad)
                ++ ": expected `key: value`, got `"
                ++ logicalText bad
                ++ "`"
            )

    parseSourceRepo allLines fields =
      case allLines of
        [] -> Right (fields, [])
        line : rest
          | logicalIndent line == 0 -> Right (fields, allLines)
          | otherwise -> do
              (field, firstValue) <- splitField "cabal.project" line
              let (value, remaining) = collectContinuation (logicalIndent line) firstValue rest
              parseSourceRepo remaining (insertField (map toLower field) value fields)

ignoredProjectFields :: [String]
ignoredProjectFields =
  [ "allow-newer"
  , "allow-older"
  , "with-compiler"
  , "repository"
  , "remote-repo-cache"
  , "jobs"
  , "package"
  , "program-options"
  , "optimization"
  , "tests"
  , "benchmarks"
  ]

splitPackageWords :: String -> [FilePath]
splitPackageWords = filter (not . null) . map trimCommas . words

splitConstraintValues :: String -> [String]
splitConstraintValues = reverse . finish . foldl step ([], [], 0)
  where
    step :: ([String], String, Int) -> Char -> ([String], String, Int)
    step (values, current, depth) character =
      case character of
        ','
          | depth == 0 -> (emit values current, [], depth)
        '{' -> (values, character : current, depth + 1)
        '(' -> (values, character : current, depth + 1)
        '[' -> (values, character : current, depth + 1)
        '}'
          | depth > 0 -> (values, character : current, depth - 1)
        ')'
          | depth > 0 -> (values, character : current, depth - 1)
        ']'
          | depth > 0 -> (values, character : current, depth - 1)
        '\n' -> (values, ' ' : current, depth)
        _ -> (values, character : current, depth)

    finish (values, current, _depth) = emit values current
    emit values current =
      case trim (reverse current) of
        "" -> values
        value -> value : values

qualifyConstraintForAllScopes :: String -> String
qualifyConstraintForAllScopes constraint =
  case span (not . isSpace) constraint of
    (subject, rest)
      | any (`elem` subject) ".:" -> constraint
      | otherwise -> "any." ++ subject ++ rest

insertField :: String -> String -> [(String, String)] -> [(String, String)]
insertField name value fields = (name, value) : filter ((/= name) . fst) fields
