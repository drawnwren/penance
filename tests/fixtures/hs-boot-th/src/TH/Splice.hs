{-# LANGUAGE TemplateHaskell #-}

module TH.Splice (splicedValue) where

import Language.Haskell.TH.Syntax (lift)
import TH.Dep (depValue)

splicedValue :: String
splicedValue = $(lift (depValue ++ ":splice"))
