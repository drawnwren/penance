module Bench.Route
  ( Route (..)
  , routePath
  )
where

data Route
  = Health
  | Users
  | Orders
  deriving (Eq, Ord, Show)

routePath :: Route -> String
routePath route =
  case route of
    Health -> "/health"
    Users -> "/users"
    Orders -> "/orders"
