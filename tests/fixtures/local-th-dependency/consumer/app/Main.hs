{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import Language.Haskell.TH.Syntax (lift)
import LocalTH.Producer (producerValue)

main :: IO ()
main = putStrLn $(lift producerValue)
