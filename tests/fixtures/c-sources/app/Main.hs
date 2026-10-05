module Main (main) where

import ForeignAnswer (foreignAnswer)
import System.Environment (getArgs, lookupEnv)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["runtime"] -> do
      sentinel <- lookupEnv "PENANCE_RUNTIME_SENTINEL"
      path <- lookupEnv "PATH"
      putStrLn (maybe "" id sentinel)
      putStrLn (maybe "" id path)
    _ -> foreignAnswer >>= print
