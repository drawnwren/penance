module Main (main) where

import Penance.WasmPlanner (normalizeProject, runSelfTests)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> getContents >>= either die putStr . normalizeProject
    ["--self-test"] -> either die (const (putStrLn "penance-wasm-planner: tests passed")) runSelfTests
    _ -> die "usage: normalize-project [--self-test]"
