module Main (main) where

import Bench.Api (endpoints)
import Bench.App (runApp)
import Bench.Generated (generatedBuildLabel)
import Bench.Model (User (..))
import Bench.Store (lookupUser)

main :: IO ()
main = do
  assert "generated label" (generatedBuildLabel == "generated:penance-bench")
  assert "endpoint count" (length endpoints == 3)
  assert "store lookup" (fmap userName (lookupUser 2) == Just "grace")
  assert "rendered output" ("generated:penance-bench" `lineMember` lines runApp)

assert :: String -> Bool -> IO ()
assert label ok =
  if ok
    then pure ()
    else fail ("failed: " ++ label)

lineMember :: String -> [String] -> Bool
lineMember needle =
  any (== needle)
