module Main (main) where

import qualified Penance.Emit.Drv as Emit
import qualified Penance.Graph.Backpack as Backpack
import qualified Penance.Graph.Component as Component
import qualified Penance.Graph.Module as Module
import qualified Penance.Graph.Package as Package
import qualified Penance.Plan as Plan
import System.Environment (getArgs)
import System.Exit (die)

data Options = Options
  { optSkeleton :: FilePath
  , optSrc :: FilePath
  , optIndexState :: String
  , optGranularity :: String
  , optOut :: FilePath
  }

main :: IO ()
main = do
  options <- parseArgs =<< getArgs
  skeleton <- Plan.readSkeleton (optSkeleton options)
  Plan.writePlannerTrace (optOut options) skeleton
  Package.emitBootstrap skeleton (optOut options)
  Component.emitBootstrap skeleton (optOut options)
  Module.emitBootstrap skeleton (optOut options)
  Backpack.emitBootstrap skeleton (optOut options)
  Emit.writeBootstrapIndex skeleton (optOut options)

parseArgs :: [String] -> IO Options
parseArgs args =
  case args of
    ["--skeleton", skeleton, "--src", src, "--index-state", indexState, "--granularity", granularity, "--out", out] ->
      pure
        Options
          { optSkeleton = skeleton
          , optSrc = src
          , optIndexState = indexState
          , optGranularity = granularity
          , optOut = out
          }
    _ ->
      die "usage: penance-planner --skeleton FILE --src DIR --index-state INDEX --granularity component|module --out DIR"
