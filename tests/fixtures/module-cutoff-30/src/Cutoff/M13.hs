module Cutoff.M13 where

import Cutoff.M11 (m11)
import Cutoff.M12 (m12)

m13 :: String
m13 = m11 ++ "|" ++ m12 ++ "|m13-body"
