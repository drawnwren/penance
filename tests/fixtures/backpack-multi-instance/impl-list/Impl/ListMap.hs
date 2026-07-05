module Impl.ListMap
  ( Map
  , empty
  , size
  )
where

newtype Map k v = Map [(k, v)]

empty :: Map k v
empty = Map []

size :: Map k v -> Int
size (Map entries) = length entries
