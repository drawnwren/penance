module Penance.Bench.Common
  ( Row (..)
  , baseTsvFields
  , baseTsvHeaderFields
  , detectNixSystem
  , formatColumns
  , maxTextWidth
  , renderSeconds
  , sanitize
  )
where

import Data.Char (isAlphaNum, isSpace)
import Data.List (dropWhileEnd)
import Data.Maybe (fromMaybe)
import Penance.Types
  ( BenchmarkAction
  , BenchmarkBackend
  , BenchmarkStatus
  , renderBenchmarkAction
  , renderBenchmarkBackend
  , renderBenchmarkStatus
  )
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)

data Row = Row
  { rowRunId :: String
  , rowPhaseId :: String
  , rowMilestone :: String
  , rowPhaseTitle :: String
  , rowBackend :: BenchmarkBackend
  , rowAttr :: Maybe String
  , rowAction :: BenchmarkAction
  , rowStatus :: BenchmarkStatus
  , rowSupported :: Bool
  , rowWallMs :: Integer
  , rowDrvPath :: Maybe FilePath
  , rowOutPath :: Maybe FilePath
  , rowClosureNarSize :: Integer
  , rowLog :: Maybe FilePath
  , rowCommand :: Maybe String
  , rowRebuildEventCount :: Int
  , rowRebuildEventNames :: [String]
  , rowExpectedMaxRebuildEvents :: Maybe Int
  , rowAllowRebuildFailure :: Bool
  , rowSpeedGate :: Bool
  }
  deriving (Eq, Show)

baseTsvFields :: Row -> [String]
baseTsvFields row =
  [ rowRunId row
  , rowPhaseId row
  , rowMilestone row
  , rowPhaseTitle row
  , renderBenchmarkBackend (rowBackend row)
  , fromMaybe "" (rowAttr row)
  , renderBenchmarkAction (rowAction row)
  , renderBenchmarkStatus (rowStatus row)
  , if rowSupported row then "1" else "0"
  , show (rowWallMs row)
  , fromMaybe "" (rowDrvPath row)
  , fromMaybe "" (rowOutPath row)
  , show (rowClosureNarSize row)
  , fromMaybe "" (rowLog row)
  , fromMaybe "" (rowCommand row)
  ]

baseTsvHeaderFields :: [String]
baseTsvHeaderFields =
  [ "run_id"
  , "phase_id"
  , "milestone"
  , "phase_title"
  , "backend"
  , "attr"
  , "action"
  , "status"
  , "supported"
  , "wall_ms"
  , "drv_path"
  , "out_path"
  , "closure_nar_size"
  , "log"
  , "command"
  ]

detectNixSystem :: FilePath -> IO (Either String String)
detectNixSystem nixBin = do
  (exitCode, stdoutText, stderrText) <-
    readCreateProcessWithExitCode
      (proc nixBin ["eval", "--raw", "--impure", "--expr", "builtins.currentSystem"])
      ""
  pure $
    case exitCode of
      ExitSuccess -> Right (dropWhileEnd isSpace (dropWhile isSpace stdoutText))
      ExitFailure _ -> Left ("failed to detect current Nix system:\n" ++ stderrText)

formatColumns :: [Int] -> [String] -> String
formatColumns widths values = unwords (zipWith padRight widths values)
  where
    padRight width text = take width (text ++ repeat ' ')

maxTextWidth :: Int -> [String] -> Int
maxTextWidth minimumWidth values = max minimumWidth (maximum (0 : map length values))

renderSeconds :: Integer -> String
renderSeconds ms
  | ms == 0 = "-"
  | otherwise =
      let centiseconds = (ms + 5) `div` 10
          secondsPart = centiseconds `div` 100
          fracPart = centiseconds `mod` 100
       in show secondsPart ++ "." ++ twoDigits fracPart ++ "s"
  where
    twoDigits n
      | n < 10 = '0' : show n
      | otherwise = show n

sanitize :: String -> String
sanitize = map (\ch -> if isAlphaNum ch || ch `elem` ("._-" :: String) then ch else '-')
