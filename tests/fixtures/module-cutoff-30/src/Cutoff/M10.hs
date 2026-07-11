module Cutoff.M10 where

import Cutoff.M08 (m08)
import Cutoff.M09 (m09)

m10 :: String
m10 = m08 ++ "|" ++ m09 ++ "|m10-body"
