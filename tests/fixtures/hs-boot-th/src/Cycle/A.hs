module Cycle.A (cycleA) where

import Cycle.B (cycleB)

cycleA :: Int
cycleA = cycleB + 1
