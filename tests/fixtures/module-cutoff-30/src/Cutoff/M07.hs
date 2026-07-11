module Cutoff.M07 where

import Cutoff.M05 (m05)
import Cutoff.M06 (m06)

m07 :: String
m07 = m05 ++ "|" ++ m06 ++ "|m07-body"
