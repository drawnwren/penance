module Main (main) where

import Penance.Sha256 (nixBase32Sha256, renderNixBase32Sha256)
import Penance.WasmPlanner (runSelfTests)
import System.Exit (die)

main :: IO ()
main = do
  if renderNixBase32Sha256 (nixBase32Sha256 "abc") == "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s"
    then pure ()
    else die "Penance.Sha256 did not match the Nix base32 SHA-256 test vector"
  either die (const (putStrLn "penance-wasm-planner: tests passed")) runSelfTests
