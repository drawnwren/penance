module Main (main) where

import Data.Hashable (hashWithSalt)

main :: IO ()
main = print (hashWithSalt 17 ("disabled" :: String))
