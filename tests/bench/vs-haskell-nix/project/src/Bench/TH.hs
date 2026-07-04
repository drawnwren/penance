{-# LANGUAGE TemplateHaskell #-}

module Bench.TH (buildLabel) where

import Language.Haskell.TH (Exp, Q)

buildLabel :: String -> Q Exp
buildLabel name =
  [| "generated:" ++ name |]
