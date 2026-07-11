module Cutoff.M24 where

import Cutoff.M22 (m22)
import Cutoff.M23 (m23)

m24 :: String
m24 = m22 ++ "|" ++ m23 ++ "|m24-body"
