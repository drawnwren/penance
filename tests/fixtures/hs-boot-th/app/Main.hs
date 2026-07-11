module Main (main) where

import Cycle.A (cycleA)
import TH.Sibling (siblingValue)
import TH.Splice (splicedValue)

main :: IO ()
main =
  putStrLn ("hs-boot-th:" ++ show cycleA ++ ":" ++ splicedValue ++ ":" ++ siblingValue)
