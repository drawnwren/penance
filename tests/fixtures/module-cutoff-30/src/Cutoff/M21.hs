module Cutoff.M21 where

import Cutoff.M19 (m19)
import Cutoff.M20 (m20)

m21 :: String
m21 = m19 ++ "|" ++ m20 ++ "|m21-body"
