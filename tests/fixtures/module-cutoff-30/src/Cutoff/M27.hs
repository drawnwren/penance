module Cutoff.M27 where

import Cutoff.M25 (m25)
import Cutoff.M26 (m26)

m27 :: String
m27 = m25 ++ "|" ++ m26 ++ "|m27-body"
