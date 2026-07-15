module Main (main) where

import Control.Exception (handle)
import Control.Monad (unless)
import Penance.Error (renderPenanceError)
import qualified Penance.Emit.Drv as Emit
import qualified Penance.Graph.Backpack as Backpack
import qualified Penance.Graph.Component as Component
import qualified Penance.Graph.Module as Module
import qualified Penance.Graph.Package as Package
import qualified Penance.Plan as Plan
import Penance.Skeleton (ProjectSkeleton (granularity))
import Penance.Types (Granularity, IndexState (..), parseGranularity)
import System.Environment (getArgs)
import System.Exit (die)

data Options = Options
  { optSkeleton :: FilePath
  , optSrc :: FilePath
  , optIndexState :: IndexState
  , optGranularity :: Granularity
  , optOut :: FilePath
  }

main :: IO ()
main = handle (die . renderPenanceError) run

run :: IO ()
run = do
  options <- parseArgs =<< getArgs
  skeleton <- Plan.readSkeleton (optSkeleton options)
  unless (granularity skeleton == optGranularity options) $
    die "planner granularity does not match the decoded skeleton"
  Package.emitBootstrap skeleton (optOut options)
  Component.emitBootstrap skeleton (optOut options)
  Module.emitBootstrap skeleton (optOut options)
  Backpack.emitBootstrap skeleton (optOut options)
  Emit.writeBootstrapIndex skeleton (optOut options)

parseArgs :: [String] -> IO Options
parseArgs args =
  case args of
    ["--skeleton", skeleton, "--src", src, "--index-state", indexState, "--granularity", granularityText, "--out", out] ->
      case parseGranularity granularityText of
        Left err -> die err
        Right parsedGranularity ->
          pure
            Options
              { optSkeleton = skeleton
              , optSrc = src
              , optIndexState = IndexState indexState
              , optGranularity = parsedGranularity
              , optOut = out
              }
    _ ->
      die "usage: penance-planner --skeleton FILE --src DIR --index-state INDEX --granularity component|module --out DIR"
