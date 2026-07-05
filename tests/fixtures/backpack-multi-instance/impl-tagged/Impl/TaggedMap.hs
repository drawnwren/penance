module Impl.TaggedMap
  ( Map
  , empty
  , size
  )
where

data Map k v = Map Int

empty :: Map k v
empty = Map 0

size :: Map k v -> Int
size (Map count) = count
