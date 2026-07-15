module Penance.CabalLex
  ( LogicalLine (..)
  , collectContinuation
  , logicalLines
  , sortNub
  , splitField
  , splitSubstring
  , stripComment
  , trim
  , trimCommas
  )
where

import Data.Char (isSpace)
import Data.List (dropWhileEnd, intercalate, isPrefixOf, sort)

data LogicalLine = LogicalLine
  { logicalNumber :: Int
  , logicalIndent :: Int
  , logicalText :: String
  }
  deriving (Eq, Show)

logicalLines :: String -> [LogicalLine]
logicalLines text =
  [ LogicalLine number (length (takeWhile isSpace uncommented)) (trim uncommented)
  | (number, raw) <- zip [1 ..] (lines text)
  , let uncommented = stripComment raw
  , not (null (trim uncommented))
  ]

stripComment :: String -> String
stripComment text = maybe text fst (splitSubstring "--" text)

splitField :: String -> LogicalLine -> Either String (String, String)
splitField context line =
  case break (== ':') (logicalText line) of
    (field, _ : value) -> Right (trim field, trim value)
    _ ->
      Left
        ( context
            ++ " line "
            ++ show (logicalNumber line)
            ++ ": expected `key: value`, got `"
            ++ logicalText line
            ++ "`"
        )

collectContinuation :: Int -> String -> [LogicalLine] -> (String, [LogicalLine])
collectContinuation fieldIndent firstValue allLines =
  let (continuation, remaining) = span ((> fieldIndent) . logicalIndent) allLines
      values = filter (not . null) (trim firstValue : map (trim . logicalText) continuation)
   in (intercalate "\n" values, remaining)

splitSubstring :: String -> String -> Maybe (String, String)
splitSubstring needle = go ""
  where
    go _ [] = Nothing
    go prefix value@(ch : rest)
      | needle `isPrefixOf` value = Just (reverse prefix, drop (length needle) value)
      | otherwise = go (ch : prefix) rest

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace

trimCommas :: String -> String
trimCommas = dropWhile (== ',') . reverse . dropWhile (== ',') . reverse

sortNub :: Ord a => [a] -> [a]
sortNub = foldr insert [] . sort
  where
    insert value values@(first : _)
      | value == first = values
    insert value values = value : values
