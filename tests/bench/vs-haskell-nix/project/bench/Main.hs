module Main (main) where

import Bench.App (runApp)

main :: IO ()
main =
  putStrLn ("rendered-bytes=" ++ show (length runApp))
