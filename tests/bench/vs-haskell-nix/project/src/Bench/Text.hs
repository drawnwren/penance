module Bench.Text
  ( slug
  )
where

slug :: String -> String
slug =
  map normalize
  where
    normalize ch
      | ch == ' ' = '-'
      | otherwise = ch
