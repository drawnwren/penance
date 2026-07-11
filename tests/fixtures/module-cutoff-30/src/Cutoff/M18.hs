module Cutoff.M18 where

import Cutoff.M16 (m16)
import Cutoff.M17 (m17)

m18 :: String
m18 = m16 ++ "|" ++ m17 ++ "|m18-body"
