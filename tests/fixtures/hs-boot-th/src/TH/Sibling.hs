module TH.Sibling (siblingValue) where

import TH.Dep (depValue)

siblingValue :: String
siblingValue = depValue ++ ":sibling"
