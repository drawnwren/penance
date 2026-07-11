module Cutoff.M16 where

import Cutoff.M14 (m14)
import Cutoff.M15 (m15)

m16 :: String
m16 = m14 ++ "|" ++ m15 ++ "|m16-body"
