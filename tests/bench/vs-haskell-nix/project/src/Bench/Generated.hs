{-# LANGUAGE TemplateHaskell #-}

module Bench.Generated (generatedBuildLabel) where

import Bench.TH (buildLabel)

generatedBuildLabel :: String
generatedBuildLabel = $(buildLabel "penance-bench")
