module Main (main) where

import ForeignAnswer (foreignAnswer)

main :: IO ()
main = foreignAnswer >>= print
