module Main (main) where

import Penance.WasmPlanner (normalizeProject, runSelfTests)
import Penance.Utf8.IO (readUtf8Stdin)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> readUtf8Stdin >>= either die putStr . normalizeProject
    ["--self-test"] -> either die (const (putStrLn "penance-wasm-planner: tests passed")) runSelfTests
    _ -> die "usage: normalize-project [--self-test]"
