module Bench.App (runApp) where

import Bench.Api (endpoints, renderEndpoint)
import Bench.Config (defaultConfig, renderConfig)
import Bench.Generated (generatedBuildLabel)
import Bench.Render (renderLines)

runApp :: String
runApp =
  renderLines
    ( renderConfig defaultConfig
        : generatedBuildLabel
        : map renderEndpoint endpoints
    )
