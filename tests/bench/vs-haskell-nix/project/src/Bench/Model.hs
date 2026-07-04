module Bench.Model
  ( User (..)
  , demoUsers
  )
where

data User = User
  { userId :: Int
  , userName :: String
  }
  deriving (Eq, Ord, Show)

demoUsers :: [User]
demoUsers =
  [ User 1 "ada"
  , User 2 "grace"
  , User 3 "barbara"
  ]
