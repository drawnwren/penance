module Penance.List (chunksOf) where

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf size values =
  let (prefix, suffix) = splitAt size values
   in prefix : chunksOf size suffix
