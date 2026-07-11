module Cutoff.M30 where

import Cutoff.M28 (m28)
import Cutoff.M29 (m29)

m30 :: String
m30 = m28 ++ "|" ++ m29 ++ "|m30-body"
