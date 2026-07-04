module Bench.Api
  ( Endpoint (..)
  , endpoints
  , renderEndpoint
  )
where

import Bench.Route (Route (..), routePath)

data Endpoint = Endpoint
  { endpointName :: String
  , endpointRoute :: Route
  }
  deriving (Eq, Ord, Show)

endpoints :: [Endpoint]
endpoints =
  [ Endpoint "health" Health
  , Endpoint "users" Users
  , Endpoint "orders" Orders
  ]

renderEndpoint :: Endpoint -> String
renderEndpoint endpoint =
  endpointName endpoint ++ " " ++ routePath (endpointRoute endpoint)
