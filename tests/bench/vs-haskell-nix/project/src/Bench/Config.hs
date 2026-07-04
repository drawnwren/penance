module Bench.Config
  ( Config (..)
  , defaultConfig
  , renderConfig
  )
where

data Config = Config
  { configPort :: Int
  , configDbPath :: FilePath
  }
  deriving (Eq, Show)

defaultConfig :: Config
defaultConfig =
  Config
    { configPort = 8080
    , configDbPath = "bench.sqlite"
    }

renderConfig :: Config -> String
renderConfig config =
  "port=" ++ show (configPort config) ++ " db=" ++ configDbPath config
