module Cutoff.M04 where

import Cutoff.M02 (m02)
import Cutoff.M03 (m03)

m04 :: String
m04 = m02 ++ "|" ++ m03 ++ "|m04-body"
