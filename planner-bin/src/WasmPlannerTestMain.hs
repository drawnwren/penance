module Main (main) where

import Penance.WasmPlanner (runSelfTests)
import System.Exit (die)

main :: IO ()
main = either die (const (putStrLn "penance-wasm-planner: tests passed")) runSelfTests
