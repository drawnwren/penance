module Penance.CabalProject
  ( CabalProject (..)
  , parseCabalProject
  )
where

import Data.Char (toLower)
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
  }
  deriving (Eq, Show)

parseCabalProject :: String -> Either String CabalProject
parseCabalProject text = go (logicalLines text) [] [] [] Nothing
  where
    go [] packages optionalPackages repos indexState =
      Right
        CabalProject
          { projectPackages = sortNub packages
          , projectOptionalPackages = sortNub optionalPackages
          , projectSourceRepos = sort repos
          , projectIndexState = indexState
          }
    go (line : rest) packages optionalPackages repos indexState
      | logicalIndent line /= 0 = malformed line
      | map toLower (logicalText line) == "source-repository-package" = do
          (repo, remaining) <- parseSourceRepo rest []
          go remaining packages optionalPackages (sort repo : repos) indexState
      | otherwise = do
          (field, firstValue) <- splitField "cabal.project" line
          let normalizedField = map toLower field
              (value, remaining) = collectContinuation (logicalIndent line) firstValue rest
          case normalizedField of
            "packages" -> go remaining (splitPackageWords value ++ packages) optionalPackages repos indexState
            "optional-packages" -> go remaining packages (splitPackageWords value ++ optionalPackages) repos indexState
            "index-state" -> go remaining packages optionalPackages repos (Just (trim value))
            _
              | normalizedField `elem` ignoredProjectFields -> go remaining packages optionalPackages repos indexState
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
  [ "constraints"
  , "allow-newer"
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

insertField :: String -> String -> [(String, String)] -> [(String, String)]
insertField name value fields = (name, value) : filter ((/= name) . fst) fields
