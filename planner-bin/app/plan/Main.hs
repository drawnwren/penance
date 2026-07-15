module Main (main) where

import Control.Exception (handle)
import qualified Penance.Dyndrv as Dyndrv
import Penance.Error (renderPenanceError)
import qualified Penance.GhcMakefile as GhcMakefile
import qualified Penance.ModulePlan as ModulePlan
import Penance.Utf8.IO (writeUtf8File)
import System.Environment (getArgs)
import System.Exit (die, exitSuccess)

data Command
  = ModuleOrder FilePath FilePath
  | ModulePlan FilePath FilePath String FilePath
  | EmitBenchDyndrv [String]

main :: IO ()
main = handle (die . renderPenanceError) run

run :: IO ()
run = do
  command <- parseCommand =<< getArgs
  case command of
    ModuleOrder makefile out -> do
      modules <- GhcMakefile.moduleOrderFromMakefile makefile
      writeUtf8File out (unlines modules)
    ModulePlan makefile lock component out ->
      ModulePlan.writeModulePlan makefile lock component out
    EmitBenchDyndrv args ->
      Dyndrv.emitBenchDyndrvFromArgs args

parseCommand :: [String] -> IO Command
parseCommand args =
  case args of
    ["module-order", "--makefile", makefile, "--out", out] ->
      pure (ModuleOrder makefile out)
    ["module-plan", "--makefile", makefile, "--lock", lock, "--component", component, "--out", out] ->
      pure (ModulePlan makefile lock component out)
    "emit-bench-dyndrv" : rest ->
      pure (EmitBenchDyndrv rest)
    ["-h"] -> usage
    ["--help"] -> usage
    _ -> die usageText

usage :: IO a
usage = do
  putStr usageText
  exitSuccess

usageText :: String
usageText =
  unlines
    [ "usage:"
    , "  penance-plan module-order --makefile FILE --out FILE"
    , "  penance-plan module-plan --makefile FILE --lock FILE --component COMPONENT --out FILE"
    , "  penance-plan emit-bench-dyndrv --module-plan FILE --src-root DIR --out FILE ..."
    ]
