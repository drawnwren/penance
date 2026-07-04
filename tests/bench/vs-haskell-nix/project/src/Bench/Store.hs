module Bench.Store
  ( UserStore
  , lookupUser
  , userStore
  )
where

import Bench.Model (User (..), demoUsers)
import qualified Data.Map.Strict as Map

type UserStore = Map.Map Int User

userStore :: UserStore
userStore =
  Map.fromList [(userId user, user) | user <- demoUsers]

lookupUser :: Int -> Maybe User
lookupUser key =
  Map.lookup key userStore
