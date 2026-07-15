module TH.Dep (depValue) where

import TH.Base (baseValue)

depValue :: String
depValue = baseValue ++ ":dep-v1"
