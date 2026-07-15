module Main (main) where

import Control.Monad (foldM, forM_, unless, when)
import Data.List (dropWhileEnd, find, intercalate, isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Penance.Bench.Common
  ( Row (..)
  , baseTsvFields
  , baseTsvHeaderFields
  , detectNixSystem
  , formatColumns
  , maxTextWidth
  , renderSeconds
  , sanitize
  )
import Penance.Json (Json (..), parseJson, renderJson)
import qualified Penance.Json as Json
import Penance.Types
  ( BenchmarkAction (..)
  , BenchmarkBackend (..)
  , BenchmarkStatus (..)
  , PenanceSchema (..)
  , PhaseStatus (..)
  , benchmarkStatusFromExit
  , benchmarkStatusSucceeded
  , parsePhaseStatus
  , renderBenchmarkAction
  , renderBenchmarkBackend
  , renderBenchmarkStatus
  , renderPhaseStatus
  , renderPenanceSchema
  )
import Penance.Utf8.IO (appendUtf8File, readUtf8File, writeUtf8File)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , doesPathExist
  , getCurrentDirectory
  , listDirectory
  , removePathForcibly
  )
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.IO (IOMode (..), hPutStr, stderr, withFile)
import System.Process
  ( proc
  , readCreateProcessWithExitCode
  , waitForProcess
  , withCreateProcess
  , CreateProcess (std_err, std_out)
  , StdStream (UseHandle)
  )

data Options = Options
  { optFlake :: FilePath
  , optMatrix :: FilePath
  , optSystem :: Maybe String
  , optOutDir :: FilePath
  , optPhases :: [String]
  , optSkipPhases :: [String]
  , optRepeat :: Int
  , optRebuild :: Bool
  , optDryRun :: Bool
  , optKeepGoing :: Bool
  , optAllowNotImplemented :: Bool
  , optAllowHaskellNixFailures :: Bool
  , optRequirePenanceFaster :: Bool
  , optRetainPhase :: Maybe String
  , optList :: Bool
  , optNixBin :: FilePath
  }
  deriving (Eq, Show)

data Phase = Phase
  { phaseId :: String
  , phaseMilestone :: String
  , phaseTitle :: String
  , phaseStatus :: PhaseStatus
  , phasePenanceAttr :: Maybe String
  , phaseHaskellNixAttr :: Maybe String
  , phaseRequired :: Bool
  , phaseFailure :: Maybe String
  , phaseAllowRebuildFailure :: Bool
  , phaseSpeedGate :: Bool
  }
  deriving (Eq, Show)

main :: IO ()
main = do
  options <- parseOptions =<< getArgs
  phases <- readMatrix (optMatrix options)
  if optList options
    then printPhaseList phases
    else do
      system <- maybe (detectSystem options) pure (optSystem options)
      runBench options system phases

parseOptions :: [String] -> IO Options
parseOptions args = do
  cwd <- getCurrentDirectory
  nixBin <- fromMaybe "nix" <$> lookupEnv "PENANCE_NIX_BIN"
  envFlake <- lookupEnv "PENANCE_PHASE_BENCH_FLAKE"
  envOut <- lookupEnv "PENANCE_PHASE_BENCH_OUT"
  envMatrix <- lookupEnv "PENANCE_PHASE_BENCH_MATRIX"
  envRetainPhase <- lookupEnv "PENANCE_PHASE_BENCH_RETAIN_PHASE"
  let defaults =
        Options
          { optFlake = fromMaybe ("path:" ++ cwd) envFlake
          , optMatrix = fromMaybe (cwd </> "tests" </> "architecture" </> "phase-matrix.json") envMatrix
          , optSystem = Nothing
          , optOutDir = fromMaybe (cwd </> ".penance" </> "bench-results" </> "architecture") envOut
          , optPhases = []
          , optSkipPhases = []
          , optRepeat = 1
          , optRebuild = False
          , optDryRun = False
          , optKeepGoing = False
          , optAllowNotImplemented = False
          , optAllowHaskellNixFailures = False
          , optRequirePenanceFaster = False
          , optRetainPhase = envRetainPhase
          , optList = False
          , optNixBin = nixBin
          }
  go defaults args
  where
    go options rest =
      case rest of
        [] -> pure options
        "--flake" : value : xs -> go options {optFlake = value} xs
        "--matrix" : value : xs -> go options {optMatrix = value} xs
        "--system" : value : xs -> go options {optSystem = Just value} xs
        "--out-dir" : value : xs -> go options {optOutDir = value} xs
        "--phase" : value : xs -> go options {optPhases = optPhases options ++ [value]} xs
        "--skip-phase" : value : xs -> go options {optSkipPhases = optSkipPhases options ++ [value]} xs
        "--repeat" : value : xs ->
          case reads value of
            [(n, "")] | n > 0 -> go options {optRepeat = n} xs
            _ -> die "--repeat must be a positive integer"
        "--rebuild" : xs -> go options {optRebuild = True} xs
        "--dry-run" : xs -> go options {optDryRun = True} xs
        "--keep-going" : xs -> go options {optKeepGoing = True} xs
        "--allow-not-implemented" : xs -> go options {optAllowNotImplemented = True} xs
        "--allow-haskell-nix-failures" : xs -> go options {optAllowHaskellNixFailures = True} xs
        "--require-penance-faster" : xs -> go options {optRequirePenanceFaster = True} xs
        "--list" : xs -> go options {optList = True} xs
        "-h" : _ -> usage >> exitSuccess
        "--help" : _ -> usage >> exitSuccess
        flag : _ -> die ("unknown option: " ++ flag)

usage :: IO ()
usage =
  putStrLn $
    unlines
      [ "usage: penance-architecture-bench [options]"
      , ""
      , "Runs the architecture phase benchmark matrix. Comparison phases time"
      , "evaluation and nix builds for equivalent penance and haskell.nix package attrs."
      , "Failing phases record architecture failures."
      , ""
      , "Options:"
      , "  --flake REF          flake to benchmark (default: current directory)"
      , "  --matrix PATH        phase matrix JSON"
      , "  --system SYSTEM      Nix system (default: builtins.currentSystem)"
      , "  --out-dir DIR        output directory"
      , "  --phase ID           run only one phase; may be repeated"
      , "  --skip-phase ID      exclude one phase; may be repeated"
      , "  --repeat N           repeat runnable measurements N times (default: 1)"
      , "  --rebuild            pass --rebuild to nix build for local rebuild timing"
      , "  --dry-run            use nix build --dry-run instead of real builds"
      , "  --keep-going         continue after a failed runnable measurement"
      , "  --allow-not-implemented"
      , "                       report not_implemented rows but do not fail the suite"
      , "  --allow-haskell-nix-failures"
      , "                       report haskell.nix rebuild build failures but do not fail the suite"
      , "  --require-penance-faster"
      , "                       fail when a measured section median is not faster on penance"
      , "  --list               print the phase matrix and exit"
      , "  -h, --help           show this help"
      ]

detectSystem :: Options -> IO String
detectSystem options = either die pure =<< detectNixSystem (optNixBin options)

readMatrix :: FilePath -> IO [Phase]
readMatrix path = do
  exists <- doesFileExist path
  unless exists (die ("phase matrix not found: " ++ path))
  contents <- readUtf8File path
  value <- either die pure (parseJson contents)
  fields <- expectObject "phase matrix" value
  schema <- stringField "schema" fields
  unless (schema == renderPenanceSchema ArchitecturePhaseMatrixSchemaV1) $
    die ("unexpected phase matrix schema: " ++ schema)
  phaseValues <- arrayField "phases" fields
  traverse decodePhase phaseValues

decodePhase :: Json -> IO Phase
decodePhase value = do
  fields <- expectObject "phase" value
  statusText <- stringField "status" fields
  status <- either die pure (parsePhaseStatus statusText)
  Phase
    <$> stringField "id" fields
    <*> stringField "milestone" fields
    <*> stringField "title" fields
    <*> pure status
    <*> optionalStringField "penanceAttr" fields
    <*> optionalStringField "haskellNixAttr" fields
    <*> boolField "required" fields
    <*> optionalStringField "failure" fields
    <*> optionalBoolField False "allowRebuildFailure" fields
    <*> optionalBoolField True "speedGate" fields

printPhaseList :: [Phase] -> IO ()
printPhaseList phases = do
  let widths =
        [ maxTextWidth 24 (map phaseId phases)
        , maxTextWidth 10 (map (renderPhaseStatus . phaseStatus) phases)
        , maxTextWidth 34 (map (fromMaybe "-" . phasePenanceAttr) phases)
        , maxTextWidth 34 (map (fromMaybe "-" . phaseHaskellNixAttr) phases)
        ]
  putStrLn (formatColumns widths ["PHASE", "STATE", "PENANCE TARGET", "HASKELL.NIX TARGET"] ++ " TITLE")
  putStrLn (formatColumns widths ["-----", "-----", "--------------", "------------------"] ++ " -----")
  forM_ phases $ \phase ->
    putStrLn $
      formatColumns
        widths
        [ phaseId phase
        , renderPhaseStatus (phaseStatus phase)
        , fromMaybe "-" (phasePenanceAttr phase)
        , fromMaybe "-" (phaseHaskellNixAttr phase)
        ]
        ++ " "
        ++ phaseTitle phase
  putStrLn ""
  putStrLn "States:"
  putStrLn "  comparison  equivalent real penance build vs real haskell.nix build"
  putStrLn "  proof       one-sided mechanism proof with a negative control"
  putStrLn "  failing     required comparison is not implemented or not passing yet"

runBench :: Options -> String -> [Phase] -> IO ()
runBench options system phases = do
  stamp <- formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" <$> getCurrentTime
  let runDir = optOutDir options </> system ++ "-" ++ stamp
      logDir = runDir </> "logs"
      linkDir = runDir </> "results"
      metricsTsv = runDir </> "metrics.tsv"
      metricsJsonl = runDir </> "metrics.jsonl"
      summaryJson = runDir </> "summary.json"
      selectedPhases = filter (selected options) phases
  when (null selectedPhases) (die "no phases selected")
  createDirectoryIfMissing True logDir
  createDirectoryIfMissing True linkDir
  writeUtf8File metricsTsv (tsvHeader ++ "\n")
  writeUtf8File metricsJsonl ""

  rows <- runPhases options system logDir linkDir selectedPhases
  let speedFailures = sectionSpeedFailures options rows
      failures = countEffectiveFailures options rows + length speedFailures
  appendUtf8File metricsTsv (concatMap ((++ "\n") . renderTsvRow) rows)
  appendUtf8File metricsJsonl (concatMap ((++ "\n") . renderJson . rowJson) rows)
  writeUtf8File summaryJson (renderJson (summaryJsonValue stamp system options failures speedFailures rows) ++ "\n")

  hPutStr stderr $
    unlines
      [ "wrote architecture benchmark metrics:"
      , "  " ++ metricsTsv
      , "  " ++ metricsJsonl
      , "  " ++ summaryJson
      ]
  hPutStr stderr (renderHumanSummary system options failures speedFailures rows)
  when (failures /= 0) exitFailure

selected :: Options -> Phase -> Bool
selected options phase =
  (null (optPhases options) || phaseId phase `elem` optPhases options)
    && phaseId phase `notElem` optSkipPhases options

runPhases :: Options -> String -> FilePath -> FilePath -> [Phase] -> IO [Row]
runPhases options system logDir linkDir phases =
  foldM step [] phases
  where
    step accRows phase = do
      rows <- case phaseStatus phase of
        FailingPhase -> do
          let row =
                Row
                  { rowRunId = "failing"
                  , rowPhaseId = phaseId phase
                  , rowMilestone = phaseMilestone phase
                  , rowPhaseTitle = phaseTitle phase
                  , rowBackend = PhaseBackend
                  , rowAttr = Nothing
                  , rowAction = ArchitectureFailureAction
                  , rowStatus = BenchmarkNotImplemented
                  , rowSupported = False
                  , rowWallMs = 0
                  , rowDrvPath = Nothing
                  , rowOutPath = Nothing
                  , rowClosureNarSize = 0
                  , rowLog = Nothing
                  , rowCommand = Just (fromMaybe "Required real-build comparison is not implemented" (phaseFailure phase))
                  , rowRebuildEventCount = 0
                  , rowRebuildEventNames = []
                  , rowExpectedMaxRebuildEvents = Nothing
                  , rowAllowRebuildFailure = phaseAllowRebuildFailure phase
                  , rowSpeedGate = phaseSpeedGate phase
                  }
          case phaseHaskellNixAttr phase of
            Nothing ->
              pure (accRows ++ [row])
            Just _ -> do
              haskellRows <-
                measureBackend options system logDir linkDir phase HaskellNixBackend (phaseHaskellNixAttr phase) 1
              pure (accRows ++ [row] ++ haskellRows)
        ProofPhase -> runProofRepeats accRows phase
        ComparisonPhase ->
          runComparisonRepeats accRows phase
      when (optRetainPhase options == Just (phaseId phase) && not (optDryRun options)) $
        retainCompilerInputs options linkDir phase rows
      unless (optRetainPhase options == Just (phaseId phase)) $
        cleanupResultLinks linkDir (phaseId phase)
      pure rows

    runProofRepeats accRows phase =
      case phasePenanceAttr phase of
        Nothing -> die ("proof phase is missing penanceAttr: " ++ phaseId phase)
        Just attr -> do
          rows <-
            fmap concat . mapM
              (measureBackend options system logDir linkDir phase PenanceBackend (Just attr))
              $ [1 .. optRepeat options]
          pure (accRows ++ rows)

    runComparisonRepeats accRows phase =
      goRepeat accRows 1
      where
        goRepeat rows repeatIndex
          | repeatIndex > optRepeat options = pure rows
          | otherwise = do
              hPutStr stderr $
                "phase "
                  ++ phaseId phase
                  ++ " [comparison] ("
                  ++ phaseTitle phase
                  ++ "), repeat "
                  ++ show repeatIndex
                  ++ "/"
                  ++ show (optRepeat options)
                  ++ "\n"
              penanceRows <-
                measureBackend options system logDir linkDir phase PenanceBackend (phasePenanceAttr phase) repeatIndex
              let penanceEffectiveFailure = any (rowIsEffectiveFailure options) penanceRows
              if penanceEffectiveFailure && not (optKeepGoing options)
                then pure (rows ++ penanceRows)
                else do
                  haskellRows <-
                    measureBackend options system logDir linkDir phase HaskellNixBackend (phaseHaskellNixAttr phase) repeatIndex
                  let rowsAfter = rows ++ penanceRows ++ haskellRows
                      haskellEffectiveFailure = any (rowIsEffectiveFailure options) haskellRows
                  if haskellEffectiveFailure && not (optKeepGoing options)
                    then pure rowsAfter
                    else goRepeat rowsAfter (repeatIndex + 1)

measureBackend :: Options -> String -> FilePath -> FilePath -> Phase -> BenchmarkBackend -> Maybe String -> Int -> IO [Row]
measureBackend options system logDir linkDir phase backend maybeAttr repeatIndex =
  case maybeAttr of
    Nothing ->
      pure
        [ baseRow
            { rowRunId = runId
            , rowBackend = backend
            , rowAction = SkippedAction
            , rowStatus = BenchmarkUnsupported
            , rowSupported = False
            }
        ]
    Just attr -> do
      let runName =
            sanitize (phaseId phase)
              ++ "-" ++ sanitize (renderBenchmarkBackend backend)
              ++ "-" ++ sanitize attr
              ++ "-r" ++ show repeatIndex
          evalRef = optFlake options ++ "#packages." ++ system ++ "." ++ attr ++ ".drvPath"
          evalLog = logDir </> runName ++ "-eval.log"
          evalOut = logDir </> runName ++ "-eval.out"
          evalCommand = optNixBin options ++ " eval --raw " ++ evalRef
      evalResult <- timedReadSplit evalOut evalLog (optNixBin options) ["eval", "--raw", evalRef]
      drvPath <- if trStatus evalResult == 0 then Just . strip <$> readUtf8File evalOut else pure Nothing
      let evalRow =
            baseRow
              { rowRunId = runId
              , rowBackend = backend
              , rowAttr = Just attr
              , rowAction = EvalDrvPathAction
              , rowStatus = benchmarkStatusFromExit (trStatus evalResult)
              , rowSupported = True
              , rowWallMs = trWallMs evalResult
              , rowDrvPath = nonEmptyMaybe =<< drvPath
              , rowLog = Just evalLog
              , rowCommand = Just evalCommand
              }
      if trStatus evalResult /= 0
        then pure [evalRow]
        else do
          let buildRef =
                case drvPath of
                  Just path | not (null path) -> path ++ "^out"
                  _ -> optFlake options ++ "#packages." ++ system ++ "." ++ attr
              outLink = linkDir </> runName
              warmupLink = linkDir </> runName ++ "-warmup"
              warmupLog = logDir </> runName ++ "-warmup.log"
              buildLog = logDir </> runName ++ "-build.log"
              (buildAction, buildArgs) =
                if optDryRun options
                  then (BuildDryRunAction, ["build", "--dry-run", buildRef, "-L"])
                  else
                    ( BuildAction
                    , ["build", buildRef, "--out-link", outLink, "-L"]
                        ++ if optRebuild options then ["--rebuild"] else []
                    )
              warmupArgs = ["build", buildRef, "--out-link", warmupLink, "-L"]
              warmupCommand = optNixBin options ++ " " ++ unwords warmupArgs
              buildCommand = optNixBin options ++ " " ++ unwords buildArgs
          -- Outputs exist after the first repeat's --rebuild re-realizes them,
          -- so later repeats can skip the untimed warmup build.
          let doWarmup = optRebuild options && not (optDryRun options) && repeatIndex == 1
          warmupResult <-
            if doWarmup
              then timedRunToLog warmupLog (optNixBin options) warmupArgs
              else pure TimedResult {trStatus = 0, trWallMs = 0}
          buildResult <-
            if trStatus warmupResult /= 0
              then pure warmupResult
              else timedRunToLog buildLog (optNixBin options) buildArgs
          let warmupFailed = trStatus warmupResult /= 0
              (rowLogPath, rowCommandText)
                | not doWarmup = (buildLog, buildCommand)
                | warmupFailed = (warmupLog, warmupCommand)
                | otherwise = (warmupLog ++ ", " ++ buildLog, warmupCommand ++ "; " ++ buildCommand)
              realizedOut = trStatus buildResult == 0 && not (optDryRun options)
          realizedPath <- if realizedOut then Just <$> canonicalizePath outLink else pure Nothing
          closureSize <- if realizedOut then pathNarSize options outLink else pure 0
          let buildRow =
                baseRow
                  { rowRunId = runId
                  , rowBackend = backend
                  , rowAttr = Just attr
                  , rowAction = buildAction
                  , rowStatus = benchmarkStatusFromExit (trStatus buildResult)
                  , rowSupported = True
                  , rowWallMs = trWallMs buildResult
                  , rowDrvPath = nonEmptyMaybe =<< drvPath
                  , rowOutPath = realizedPath
                  , rowClosureNarSize = closureSize
                  , rowLog = Just rowLogPath
                  , rowCommand = Just rowCommandText
                  }
          pure [evalRow, buildRow]
  where
    runId = "r" ++ show repeatIndex
    baseRow =
      Row
        { rowRunId = runId
        , rowPhaseId = phaseId phase
        , rowMilestone = phaseMilestone phase
        , rowPhaseTitle = phaseTitle phase
        , rowBackend = backend
        , rowAttr = Nothing
        , rowAction = SkippedAction
        , rowStatus = BenchmarkUnsupported
        , rowSupported = False
        , rowWallMs = 0
        , rowDrvPath = Nothing
        , rowOutPath = Nothing
        , rowClosureNarSize = 0
        , rowLog = Nothing
        , rowCommand = Nothing
        , rowRebuildEventCount = 0
        , rowRebuildEventNames = []
        , rowExpectedMaxRebuildEvents = Nothing
        , rowAllowRebuildFailure = phaseAllowRebuildFailure phase
        , rowSpeedGate = phaseSpeedGate phase
        }

cleanupResultLinks :: FilePath -> String -> IO ()
cleanupResultLinks linkDir phaseName = do
  entries <- listDirectory linkDir
  let prefix = sanitize phaseName ++ "-"
  forM_ entries $ \entry ->
    when (prefix `isPrefixOf` entry) (removePathForcibly (linkDir </> entry))

retainCompilerInputs :: Options -> FilePath -> Phase -> [Row] -> IO ()
retainCompilerInputs options linkDir phase rows = do
  let phaseDrvPaths =
        nub . mapMaybe rowDrvPath $
          filter ((== phaseId phase) . rowPhaseId) rows
  references <- concat <$> mapM (directDerivationReferences options) phaseDrvPaths
  let compilerDrvs = sort . nub $ filter isCompilerDerivation references
  when (null compilerDrvs) $
    die ("retained phase has no direct GHC compiler derivation: " ++ phaseId phase)
  forM_ (zip [(1 :: Int) ..] compilerDrvs) $ \(index, compilerDrv) -> do
    let root = linkDir </> "retained-compiler-" ++ show index
    (code, _, stderrText) <-
      readCreateProcessWithExitCode
        (proc (nixStoreBin options) ["--add-root", root, "--realise", compilerDrv ++ "!out"])
        ""
    case code of
      ExitSuccess -> pure ()
      ExitFailure _ -> die ("failed to retain compiler input " ++ compilerDrv ++ ":\n" ++ stderrText)

directDerivationReferences :: Options -> FilePath -> IO [FilePath]
directDerivationReferences options drvPath = do
  (code, stdoutText, stderrText) <-
    readCreateProcessWithExitCode
      (proc (nixStoreBin options) ["--query", "--references", drvPath])
      ""
  case code of
    ExitSuccess -> pure (filter (not . null) (lines stdoutText))
    ExitFailure _ -> die ("failed to query derivation references for " ++ drvPath ++ ":\n" ++ stderrText)

nixStoreBin :: Options -> FilePath
nixStoreBin options =
  let directory = takeDirectory (optNixBin options)
   in if directory == "." then "nix-store" else directory </> "nix-store"

isCompilerDerivation :: FilePath -> Bool
isCompilerDerivation path =
  let name = takeFileName path
   in "-ghc-" `isInfixOf` name
        && ".drv" `isSuffixOf` name
        && not ("-deps.drv" `isSuffixOf` name)

data TimedResult = TimedResult
  { trStatus :: Int
  , trWallMs :: Integer
  }
  deriving (Eq, Show)

timedReadSplit :: FilePath -> FilePath -> FilePath -> [String] -> IO TimedResult
timedReadSplit stdoutPath stderrPath command args = do
  start <- nowMillis
  (code, stdoutText, stderrText) <- readCreateProcessWithExitCode (proc command args) ""
  end <- nowMillis
  writeUtf8File stdoutPath stdoutText
  writeUtf8File stderrPath stderrText
  pure TimedResult {trStatus = exitCodeInt code, trWallMs = end - start}

timedRunToLog :: FilePath -> FilePath -> [String] -> IO TimedResult
timedRunToLog logPath command args =
  withFile logPath WriteMode $ \handle -> do
    start <- nowMillis
    code <-
      withCreateProcess
        (proc command args) {std_out = UseHandle handle, std_err = UseHandle handle}
        (\_ _ _ processHandle -> waitForProcess processHandle)
    end <- nowMillis
    pure TimedResult {trStatus = exitCodeInt code, trWallMs = end - start}

pathNarSize :: Options -> FilePath -> IO Integer
pathNarSize options path = do
  exists <- doesPathExist path
  if not exists
    then pure 0
    else do
      resolved <- canonicalizePath path
      (code, stdoutText, _) <-
        readCreateProcessWithExitCode
          (proc (optNixBin options) ["path-info", "--json", "-S", resolved])
          ""
      case code of
        ExitFailure _ -> pure 0
        ExitSuccess ->
          case parseJson stdoutText >>= decodeNarSize of
            Right n -> pure n
            Left _ -> pure 0

decodeNarSize :: Json -> Either String Integer
decodeNarSize value = do
  values <- expectArray "path-info output" value
  case values of
    JsonObject fields : _ -> numberField "narSize" fields
    _ -> Left "path-info output did not contain an object"

summaryJsonValue :: String -> String -> Options -> Int -> [SectionTotal] -> [Row] -> Json
summaryJsonValue stamp system options failures speedFailures rows =
  Json.object
    [ ("schema", Json.string (renderPenanceSchema ArchitecturePhaseBenchSchemaV1))
    , ("created", Json.string stamp)
    , ("system", Json.string system)
    , ("flake", Json.string (optFlake options))
    , ("matrix", Json.string (optMatrix options))
    , ( "options"
      , Json.object
          [ ("repeat", jsonNumber (toInteger (optRepeat options)))
          , ("rebuild", Json.bool (optRebuild options))
          , ("dryRun", Json.bool (optDryRun options))
          , ("allowNotImplemented", Json.bool (optAllowNotImplemented options))
          , ("allowHaskellNixFailures", Json.bool (optAllowHaskellNixFailures options))
          , ("requirePenanceFaster", Json.bool (optRequirePenanceFaster options))
          ]
      )
    , ("failures", jsonNumber (toInteger failures))
    , ("recordedFailures", jsonNumber (toInteger (countFailureRows rows)))
    , ("allowedFailures", jsonNumber (toInteger (countAllowedFailures options rows)))
    , ("speedFailures", Json.array (map sectionTotalJson speedFailures))
    , ("rows", Json.array (map rowJson rows))
    ]

sectionTotalJson :: SectionTotal -> Json
sectionTotalJson total =
  Json.object
    [ ("phaseId", Json.string (sectionPhaseId total))
    , ("penanceMedianMs", jsonNumber (sectionPenanceMedianMs total))
    , ("haskellNixMedianMs", jsonNumber (sectionHaskellMedianMs total))
    ]

rowJson :: Row -> Json
rowJson row =
  Json.object
    [ ("runId", Json.string (rowRunId row))
    , ("phaseId", Json.string (rowPhaseId row))
    , ("milestone", Json.string (rowMilestone row))
    , ("phaseTitle", Json.string (rowPhaseTitle row))
    , ("backend", Json.string (renderBenchmarkBackend (rowBackend row)))
    , ("attr", maybe Json.JsonNull Json.string (rowAttr row))
    , ("action", Json.string (renderBenchmarkAction (rowAction row)))
    , ("status", Json.string (renderBenchmarkStatus (rowStatus row)))
    , ("supported", Json.bool (rowSupported row))
    , ("wallMs", jsonNumber (rowWallMs row))
    , ("drvPath", maybe Json.JsonNull Json.string (rowDrvPath row))
    , ("outPath", maybe Json.JsonNull Json.string (rowOutPath row))
    , ("closureNarSize", jsonNumber (rowClosureNarSize row))
    , ("log", maybe Json.JsonNull Json.string (rowLog row))
    , ("command", maybe Json.JsonNull Json.string (rowCommand row))
    , ("allowRebuildFailure", Json.bool (rowAllowRebuildFailure row))
    , ("speedGate", Json.bool (rowSpeedGate row))
    ]

renderHumanSummary :: String -> Options -> Int -> [SectionTotal] -> [Row] -> String
renderHumanSummary system options failures speedFailures rows =
  unlines $
    [ "Architecture benchmark summary"
    , "  system: " ++ system
    , "  result: " ++ if failures == 0 then "PASS" else "FAIL (" ++ show failures ++ " failure(s))"
    , "  recorded failures: " ++ show (countFailureRows rows) ++ allowedFailureSuffix
    , "  rows: " ++ show (length rows)
    , ""
    , "Failures:"
    ]
      ++ renderFailures
      ++ [ ""
         , "Allowed failures:"
         ]
      ++ renderAllowedFailures
      ++ [ ""
         , "Measurements:"
         ]
      ++ renderMeasurements
      ++ [ ""
         , "Section totals:"
         ]
      ++ renderSectionTotals
      ++ [ ""
         , "Speed failures:"
         ]
      ++ renderSpeedFailures
      ++ [ ""
         , "Skipped:"
         ]
      ++ renderSkipped
  where
    failureRows = filter (rowIsEffectiveFailure options) rows
    allowedFailureRows = filter (rowIsAllowedFailure options) rows
    measurementRows = filter isMeasurementRow rows
    skippedRows = filter ((== SkippedAction) . rowAction) rows
    totals = sectionTotals rows
    allowedFailureSuffix =
      case countAllowedFailures options rows of
        0 -> ""
        n -> " (" ++ show n ++ " allowed)"

    renderRowLines rowsToRender =
      if null rowsToRender
        then ["  none"]
        else
          map
            ( \row ->
                "  - "
                  ++ rowPhaseId row
                  ++ " ["
                  ++ renderBenchmarkStatus (rowStatus row)
                  ++ "]: "
                  ++ fromMaybe (fromMaybe "see log" (rowLog row)) (rowCommand row)
            )
            rowsToRender
    renderFailures = renderRowLines failureRows
    renderAllowedFailures = renderRowLines allowedFailureRows
    renderMeasurements =
      if null measurementRows
        then ["  none"]
        else
          let includeRun = hasMultipleRuns measurementRows
              header =
                if includeRun
                  then
                    [ "  RUN    PHASE                    ACTION          PENANCE           HASKELL.NIX"
                    , "  ---    -----                    ------          -------           -----------"
                    ]
                  else
                    [ "  PHASE                    ACTION          PENANCE           HASKELL.NIX"
                    , "  -----                    ------          -------           -----------"
                    ]
           in header ++ map (renderMeasurementGroup includeRun) (measurementGroups measurementRows)
    renderSectionTotals =
      if null totals
        then ["  none"]
        else
          [ "  PHASE                    PENANCE MEDIAN  HASKELL.NIX MEDIAN"
          , "  -----                    --------------  ------------------"
          ]
            ++ map renderSectionTotal totals
    renderSpeedFailures =
      if null speedFailures
        then ["  none"]
        else map renderSpeedFailure speedFailures
    renderSkipped =
      if null skippedRows
        then ["  none"]
        else map (\row -> "  - " ++ rowPhaseId row ++ " [" ++ renderBenchmarkStatus (rowStatus row) ++ "]") skippedRows

data SectionTotal = SectionTotal
  { sectionPhaseId :: String
  , sectionPenanceMedianMs :: Integer
  , sectionHaskellMedianMs :: Integer
  }
  deriving (Eq, Show)

type MeasurementKey = (String, String, BenchmarkAction)

measurementGroups :: [Row] -> [(MeasurementKey, Maybe Row, Maybe Row)]
measurementGroups rows =
  map groupFor (uniqueValues (map measurementKey rows))
  where
    groupFor key =
      ( key
      , findMeasurement key PenanceBackend
      , findMeasurement key HaskellNixBackend
      )
    findMeasurement key backend =
      find
        (\row -> measurementKey row == key && rowBackend row == backend)
        rows

measurementKey :: Row -> MeasurementKey
measurementKey row =
  (rowRunId row, rowPhaseId row, rowAction row)

sectionTotals :: [Row] -> [SectionTotal]
sectionTotals rows =
  [ SectionTotal
      { sectionPhaseId = phase
      , sectionPenanceMedianMs = median (map fst totalsForPhase)
      , sectionHaskellMedianMs = median (map snd totalsForPhase)
      }
  | phase <- uniqueValues [phaseIdValue | ((_, phaseIdValue), _, _) <- perRunTotals]
  , let totalsForPhase = [(penance, haskellNix) | ((_, phaseIdValue), penance, haskellNix) <- perRunTotals, phaseIdValue == phase]
  , not (null totalsForPhase)
  ]
  where
    perRunTotals =
      [ (key, penance, haskellNix)
      | key <- uniqueValues (map measurementRunKey measurementRows)
      , Just penance <- [backendRunTotal key PenanceBackend]
      , Just haskellNix <- [backendRunTotal key HaskellNixBackend]
      ]
    measurementRows = filter isMeasurementRow rows
    backendRunTotal key backend =
      let backendRows =
            [row | row <- measurementRows, measurementRunKey row == key, rowBackend row == backend]
          hasEval = any ((== EvalDrvPathAction) . rowAction) backendRows
          hasRealization = any (\row -> rowAction row `elem` [BuildAction, BuildDryRunAction]) backendRows
          allSuccessful = all (benchmarkStatusSucceeded . rowStatus) backendRows
       in if hasEval && hasRealization && allSuccessful
            then Just (sum (map rowWallMs backendRows))
            else Nothing

measurementRunKey :: Row -> (String, String)
measurementRunKey row =
  (rowRunId row, rowPhaseId row)

sectionSpeedFailures :: Options -> [Row] -> [SectionTotal]
sectionSpeedFailures options rows =
  if optRequirePenanceFaster options
    then filter (\total -> sectionPenanceMedianMs total >= sectionHaskellMedianMs total) (sectionTotals (filter rowSpeedGate rows))
    else []

renderSectionTotal :: SectionTotal -> String
renderSectionTotal total =
  "  "
    ++ formatColumns
      [24, 14, 18]
      [ sectionPhaseId total
      , renderSeconds (sectionPenanceMedianMs total)
      , renderSeconds (sectionHaskellMedianMs total)
      ]
    ++ if sectionPenanceMedianMs total < sectionHaskellMedianMs total then " ✅" else ""

renderSpeedFailure :: SectionTotal -> String
renderSpeedFailure total =
  "  - "
    ++ sectionPhaseId total
    ++ ": penance median "
    ++ renderSeconds (sectionPenanceMedianMs total)
    ++ " vs haskell.nix median "
    ++ renderSeconds (sectionHaskellMedianMs total)

median :: [Integer] -> Integer
median [] = 0
median values =
  let sorted = sort values
   in sorted !! (length sorted `div` 2)

hasMultipleRuns :: [Row] -> Bool
hasMultipleRuns rows =
  case uniqueValues (map rowRunId rows) of
    _ : _ : _ -> True
    _ -> False

renderMeasurementGroup :: Bool -> (MeasurementKey, Maybe Row, Maybe Row) -> String
renderMeasurementGroup includeRun ((runId, phaseIdValue, action), penanceRow, haskellNixRow) =
  "  " ++ formatColumns widths values
  where
    winners = winnerBackends [(PenanceBackend, penanceRow), (HaskellNixBackend, haskellNixRow)]
    baseValues =
      [ phaseIdValue
      , renderBenchmarkAction action
      , renderBackendCell winners PenanceBackend penanceRow
      , renderBackendCell winners HaskellNixBackend haskellNixRow
      ]
    values =
      if includeRun
        then runId : baseValues
        else baseValues
    widths =
      if includeRun
        then [6, 24, 15, 17, 17]
        else [24, 15, 17, 17]

renderBackendCell :: [BenchmarkBackend] -> BenchmarkBackend -> Maybe Row -> String
renderBackendCell winners backend maybeRow =
  case maybeRow of
    Nothing -> "-"
    Just row ->
      renderSeconds (rowWallMs row)
        ++ statusSuffix row
        ++ if backend `elem` winners then " ✅" else ""

statusSuffix :: Row -> String
statusSuffix row =
  if benchmarkStatusSucceeded (rowStatus row)
    then ""
    else " (" ++ renderBenchmarkStatus (rowStatus row) ++ ")"

winnerBackends :: [(BenchmarkBackend, Maybe Row)] -> [BenchmarkBackend]
winnerBackends candidates =
  case successful of
    [] -> []
    _ ->
      let best = minimum (map (rowWallMs . snd) successful)
       in [backend | (backend, row) <- successful, rowWallMs row == best]
  where
    successful =
      [ (backend, row)
      | (backend, Just row) <- candidates
      , benchmarkStatusSucceeded (rowStatus row)
      ]

isMeasurementRow :: Row -> Bool
isMeasurementRow row =
  rowAction row `elem` [EvalDrvPathAction, BuildAction, BuildDryRunAction]

rowIsFailure :: Row -> Bool
rowIsFailure row =
  rowAction row == ArchitectureFailureAction
    || (rowAction row /= SkippedAction && not (benchmarkStatusSucceeded (rowStatus row)))

rowIsAllowedFailure :: Options -> Row -> Bool
rowIsAllowedFailure options row =
  rowIsFailure row
    && ( (optAllowNotImplemented options && rowAction row == ArchitectureFailureAction && rowStatus row == BenchmarkNotImplemented)
           || ( optAllowHaskellNixFailures options
                  && optRebuild options
                  && rowBackend row == HaskellNixBackend
                  && rowAction row == BuildAction
              )
           || ( rowAllowRebuildFailure row
                  && optRebuild options
                  && rowAction row == BuildAction
              )
       )

rowIsEffectiveFailure :: Options -> Row -> Bool
rowIsEffectiveFailure options row =
  rowIsFailure row && not (rowIsAllowedFailure options row)

countFailureRows :: [Row] -> Int
countFailureRows = length . filter rowIsFailure

countAllowedFailures :: Options -> [Row] -> Int
countAllowedFailures options = length . filter (rowIsAllowedFailure options)

countEffectiveFailures :: Options -> [Row] -> Int
countEffectiveFailures options = length . filter (rowIsEffectiveFailure options)

uniqueValues :: (Eq a) => [a] -> [a]
uniqueValues =
  foldl
    ( \seen value ->
        if value `elem` seen
          then seen
          else seen ++ [value]
    )
    []

renderTsvRow :: Row -> String
renderTsvRow row =
  intercalate "\t" (baseTsvFields row)

tsvHeader :: String
tsvHeader = intercalate "\t" baseTsvHeaderFields

expectObject :: String -> Json -> IO [(String, Json)]
expectObject _ (JsonObject fields) = pure fields
expectObject context other = die ("expected JSON object for " ++ context ++ ", got " ++ show other)

expectArray :: String -> Json -> Either String [Json]
expectArray _ (JsonArray values) = Right values
expectArray context other = Left ("expected JSON array for " ++ context ++ ", got " ++ show other)

arrayField :: String -> [(String, Json)] -> IO [Json]
arrayField name fields =
  case lookup name fields of
    Just (JsonArray values) -> pure values
    Just other -> die ("expected JSON array field `" ++ name ++ "`, got " ++ show other)
    Nothing -> die ("missing JSON field `" ++ name ++ "`")

stringField :: String -> [(String, Json)] -> IO String
stringField name fields =
  case lookup name fields of
    Just (JsonString value) -> pure value
    Just other -> die ("expected JSON string field `" ++ name ++ "`, got " ++ show other)
    Nothing -> die ("missing JSON field `" ++ name ++ "`")

optionalStringField :: String -> [(String, Json)] -> IO (Maybe String)
optionalStringField name fields =
  case lookup name fields of
    Just (JsonString value) -> pure (Just value)
    Just JsonNull -> pure Nothing
    Nothing -> pure Nothing
    Just other -> die ("expected JSON string/null field `" ++ name ++ "`, got " ++ show other)

boolField :: String -> [(String, Json)] -> IO Bool
boolField name fields =
  case lookup name fields of
    Just (JsonBool value) -> pure value
    Just other -> die ("expected JSON bool field `" ++ name ++ "`, got " ++ show other)
    Nothing -> die ("missing JSON field `" ++ name ++ "`")

optionalBoolField :: Bool -> String -> [(String, Json)] -> IO Bool
optionalBoolField fallback name fields =
  case lookup name fields of
    Just (JsonBool value) -> pure value
    Just other -> die ("expected JSON bool field `" ++ name ++ "`, got " ++ show other)
    Nothing -> pure fallback

numberField :: String -> [(String, Json)] -> Either String Integer
numberField name fields =
  case lookup name fields of
    Just (JsonNumber value) ->
      case reads value of
        [(n, "")] -> Right n
        _ -> Left ("invalid JSON number in field `" ++ name ++ "`")
    Just other -> Left ("expected JSON number field `" ++ name ++ "`, got " ++ show other)
    Nothing -> Left ("missing JSON field `" ++ name ++ "`")

nowMillis :: IO Integer
nowMillis = round . (* 1000) <$> getPOSIXTime

exitCodeInt :: ExitCode -> Int
exitCodeInt ExitSuccess = 0
exitCodeInt (ExitFailure n) = n

jsonNumber :: Integer -> Json
jsonNumber = JsonNumber . show

strip :: String -> String
strip = dropWhileEnd isSpaceLike . dropWhile isSpaceLike

isSpaceLike :: Char -> Bool
isSpaceLike ch = ch `elem` (" \t\r\n" :: String)

nonEmptyMaybe :: String -> Maybe String
nonEmptyMaybe "" = Nothing
nonEmptyMaybe value = Just value

die :: String -> IO a
die message = hPutStr stderr (message ++ "\n") >> exitFailure
