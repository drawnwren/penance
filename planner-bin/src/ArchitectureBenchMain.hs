module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Char (isAlphaNum)
import Data.List (find, intercalate)
import Data.Maybe (fromMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Penance.Json (Json (..), parseJson, renderJson)
import qualified Penance.Json as Json
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , doesPathExist
  , getCurrentDirectory
  )
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.FilePath ((</>))
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
  , optRepeat :: Int
  , optRebuild :: Bool
  , optDryRun :: Bool
  , optKeepGoing :: Bool
  , optList :: Bool
  , optNixBin :: FilePath
  }
  deriving (Eq, Show)

data Phase = Phase
  { phaseId :: String
  , phaseMilestone :: String
  , phaseTitle :: String
  , phaseStatus :: String
  , phasePenanceAttr :: Maybe String
  , phaseHaskellNixAttr :: Maybe String
  , phaseRequired :: Bool
  , phaseFailure :: Maybe String
  }
  deriving (Eq, Show)

data Row = Row
  { rowRunId :: String
  , rowPhaseId :: String
  , rowMilestone :: String
  , rowPhaseTitle :: String
  , rowBackend :: String
  , rowAttr :: Maybe String
  , rowAction :: String
  , rowStatus :: String
  , rowSupported :: Bool
  , rowWallMs :: Integer
  , rowDrvPath :: Maybe FilePath
  , rowOutPath :: Maybe FilePath
  , rowClosureNarSize :: Integer
  , rowLog :: Maybe FilePath
  , rowCommand :: Maybe String
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
  envOut <- lookupEnv "PENANCE_PHASE_BENCH_OUT"
  envMatrix <- lookupEnv "PENANCE_PHASE_BENCH_MATRIX"
  let defaults =
        Options
          { optFlake = cwd
          , optMatrix = fromMaybe (cwd </> "tests" </> "architecture" </> "phase-matrix.json") envMatrix
          , optSystem = Nothing
          , optOutDir = fromMaybe (cwd </> "docs" </> "bench-results" </> "architecture") envOut
          , optPhases = []
          , optRepeat = 1
          , optRebuild = False
          , optDryRun = False
          , optKeepGoing = False
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
        "--repeat" : value : xs ->
          case reads value of
            [(n, "")] | n > 0 -> go options {optRepeat = n} xs
            _ -> die "--repeat must be a positive integer"
        "--rebuild" : xs -> go options {optRebuild = True} xs
        "--dry-run" : xs -> go options {optDryRun = True} xs
        "--keep-going" : xs -> go options {optKeepGoing = True} xs
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
      , "  --repeat N           repeat runnable measurements N times (default: 1)"
      , "  --rebuild            pass --rebuild to nix build for local rebuild timing"
      , "  --dry-run            use nix build --dry-run instead of real builds"
      , "  --keep-going         continue after a failed runnable measurement"
      , "  --list               print the phase matrix and exit"
      , "  -h, --help           show this help"
      ]

detectSystem :: Options -> IO String
detectSystem options = do
  (code, stdoutText, stderrText) <-
    readCreateProcessWithExitCode
      (proc (optNixBin options) ["eval", "--raw", "--impure", "--expr", "builtins.currentSystem"])
      ""
  case code of
    ExitSuccess -> pure (strip stdoutText)
    ExitFailure _ -> die ("failed to detect current Nix system:\n" ++ stderrText)

readMatrix :: FilePath -> IO [Phase]
readMatrix path = do
  exists <- doesFileExist path
  unless exists (die ("phase matrix not found: " ++ path))
  contents <- readFile path
  value <- either die pure (parseJson contents)
  fields <- expectObject "phase matrix" value
  schema <- stringField "schema" fields
  unless (schema == "penance/architecture-phase-matrix/1") $
    die ("unexpected phase matrix schema: " ++ schema)
  phaseValues <- arrayField "phases" fields
  traverse decodePhase phaseValues

decodePhase :: Json -> IO Phase
decodePhase value = do
  fields <- expectObject "phase" value
  Phase
    <$> stringField "id" fields
    <*> stringField "milestone" fields
    <*> stringField "title" fields
    <*> stringField "status" fields
    <*> optionalStringField "penanceAttr" fields
    <*> optionalStringField "haskellNixAttr" fields
    <*> boolField "required" fields
    <*> optionalStringField "failure" fields

printPhaseList :: [Phase] -> IO ()
printPhaseList phases = do
  let widths =
        [ maxTextWidth 24 (map phaseId phases)
        , maxTextWidth 10 (map phaseStatus phases)
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
        , phaseStatus phase
        , fromMaybe "-" (phasePenanceAttr phase)
        , fromMaybe "-" (phaseHaskellNixAttr phase)
        ]
        ++ " "
        ++ phaseTitle phase
  putStrLn ""
  putStrLn "States:"
  putStrLn "  comparison  equivalent real penance build vs real haskell.nix build"
  putStrLn "  failing     required comparison is not implemented or not passing yet"

maxTextWidth :: Int -> [String] -> Int
maxTextWidth minimumWidth values =
  max minimumWidth (maximum (0 : map length values))

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
  writeFile metricsTsv (tsvHeader ++ "\n")
  writeFile metricsJsonl ""

  (rows, failures) <- runPhases options system logDir linkDir selectedPhases
  appendFile metricsTsv (concatMap ((++ "\n") . renderTsvRow) rows)
  appendFile metricsJsonl (concatMap ((++ "\n") . renderJson . rowJson) rows)
  writeFile summaryJson (renderJson (summaryJsonValue stamp system options failures rows) ++ "\n")

  hPutStr stderr $
    unlines
      [ "wrote architecture benchmark metrics:"
      , "  " ++ metricsTsv
      , "  " ++ metricsJsonl
      , "  " ++ summaryJson
      ]
  hPutStr stderr (renderHumanSummary system failures rows)
  when (failures /= 0) exitFailure

selected :: Options -> Phase -> Bool
selected options phase =
  null (optPhases options) || phaseId phase `elem` optPhases options

runPhases :: Options -> String -> FilePath -> FilePath -> [Phase] -> IO ([Row], Int)
runPhases options system logDir linkDir phases =
  foldlM step ([], 0) phases
  where
    step (accRows, accFailures) phase =
      case phaseStatus phase of
        "failing" -> do
          let row =
                Row
                  { rowRunId = "failing"
                  , rowPhaseId = phaseId phase
                  , rowMilestone = phaseMilestone phase
                  , rowPhaseTitle = phaseTitle phase
                  , rowBackend = "phase"
                  , rowAttr = Nothing
                  , rowAction = "architecture_failure"
                  , rowStatus = "not_implemented"
                  , rowSupported = False
                  , rowWallMs = 0
                  , rowDrvPath = Nothing
                  , rowOutPath = Nothing
                  , rowClosureNarSize = 0
                  , rowLog = Nothing
                  , rowCommand = Just (fromMaybe "Required real-build comparison is not implemented" (phaseFailure phase))
                  }
              failuresWithMarker = accFailures + 1
          case phaseHaskellNixAttr phase of
            Nothing ->
              pure (accRows ++ [row], failuresWithMarker)
            Just _ -> do
              (haskellRows, haskellOk) <-
                measureBackend options system logDir linkDir phase "haskell.nix" (phaseHaskellNixAttr phase) 1
              let failuresAfterHaskell =
                    if haskellOk
                      then failuresWithMarker
                      else failuresWithMarker + 1
              pure (accRows ++ [row] ++ haskellRows, failuresAfterHaskell)
        "comparison" ->
          runComparisonRepeats accRows accFailures phase
        other ->
          die ("unknown phase status '" ++ other ++ "' for " ++ phaseId phase)

    runComparisonRepeats accRows accFailures phase =
      goRepeat accRows accFailures 1
      where
        goRepeat rows failures repeatIndex
          | repeatIndex > optRepeat options = pure (rows, failures)
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
              (penanceRows, penanceOk) <-
                measureBackend options system logDir linkDir phase "penance" (phasePenanceAttr phase) repeatIndex
              let failuresAfterPenance = if penanceOk then failures else failures + 1
              if not penanceOk && not (optKeepGoing options)
                then pure (rows ++ penanceRows, failuresAfterPenance)
                else do
                  (haskellRows, haskellOk) <-
                    measureBackend options system logDir linkDir phase "haskell.nix" (phaseHaskellNixAttr phase) repeatIndex
                  let failuresAfterHaskell = if haskellOk then failuresAfterPenance else failuresAfterPenance + 1
                      rowsAfter = rows ++ penanceRows ++ haskellRows
                  if not haskellOk && not (optKeepGoing options)
                    then pure (rowsAfter, failuresAfterHaskell)
                    else goRepeat rowsAfter failuresAfterHaskell (repeatIndex + 1)

measureBackend :: Options -> String -> FilePath -> FilePath -> Phase -> String -> Maybe String -> Int -> IO ([Row], Bool)
measureBackend options system logDir linkDir phase backend maybeAttr repeatIndex =
  case maybeAttr of
    Nothing ->
      pure
        ( [ baseRow
              { rowRunId = runId
              , rowBackend = backend
              , rowAction = "skipped"
              , rowStatus = "unsupported"
              , rowSupported = False
              }
          ]
        , True
        )
    Just attr -> do
      let safePhase = sanitize (phaseId phase)
          safeBackend = sanitize backend
          safeAttr = sanitize attr
          evalRef = optFlake options ++ "#packages." ++ system ++ "." ++ attr ++ ".drvPath"
          evalLog = logDir </> safePhase ++ "-" ++ safeBackend ++ "-" ++ safeAttr ++ "-r" ++ show repeatIndex ++ "-eval.log"
          evalOut = logDir </> safePhase ++ "-" ++ safeBackend ++ "-" ++ safeAttr ++ "-r" ++ show repeatIndex ++ "-eval.out"
          evalCommand = optNixBin options ++ " eval --raw " ++ evalRef
      evalResult <- timedReadSplit evalOut evalLog (optNixBin options) ["eval", "--raw", evalRef]
      drvPath <- if trStatus evalResult == 0 then Just . strip <$> readFile evalOut else pure Nothing
      let evalRow =
            baseRow
              { rowRunId = runId
              , rowBackend = backend
              , rowAttr = Just attr
              , rowAction = "eval_drv_path"
              , rowStatus = show (trStatus evalResult)
              , rowSupported = True
              , rowWallMs = trWallMs evalResult
              , rowDrvPath = nonEmptyMaybe =<< drvPath
              , rowLog = Just evalLog
              , rowCommand = Just evalCommand
              }
      if trStatus evalResult /= 0
        then pure ([evalRow], False)
        else do
          let buildRef = optFlake options ++ "#packages." ++ system ++ "." ++ attr
              outLink = linkDir </> safePhase ++ "-" ++ safeBackend ++ "-" ++ safeAttr ++ "-r" ++ show repeatIndex
              buildLog = logDir </> safePhase ++ "-" ++ safeBackend ++ "-" ++ safeAttr ++ "-r" ++ show repeatIndex ++ "-build.log"
              (buildAction, buildArgs) =
                if optDryRun options
                  then ("build_dry_run", ["build", "--dry-run", buildRef, "-L"])
                  else
                    ( "build"
                    , ["build", buildRef, "--out-link", outLink, "-L"]
                        ++ if optRebuild options then ["--rebuild"] else []
                    )
              buildCommand = optNixBin options ++ " " ++ unwords buildArgs
          buildResult <- timedRunToLog buildLog (optNixBin options) buildArgs
          let realizedOut = trStatus buildResult == 0 && not (optDryRun options)
          closureSize <- if realizedOut then pathNarSize options outLink else pure 0
          let buildRow =
                baseRow
                  { rowRunId = runId
                  , rowBackend = backend
                  , rowAttr = Just attr
                  , rowAction = buildAction
                  , rowStatus = show (trStatus buildResult)
                  , rowSupported = True
                  , rowWallMs = trWallMs buildResult
                  , rowDrvPath = nonEmptyMaybe =<< drvPath
                  , rowOutPath = if realizedOut then Just outLink else Nothing
                  , rowClosureNarSize = closureSize
                  , rowLog = Just buildLog
                  , rowCommand = Just buildCommand
                  }
          pure ([evalRow, buildRow], trStatus buildResult == 0)
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
        , rowAction = ""
        , rowStatus = ""
        , rowSupported = False
        , rowWallMs = 0
        , rowDrvPath = Nothing
        , rowOutPath = Nothing
        , rowClosureNarSize = 0
        , rowLog = Nothing
        , rowCommand = Nothing
        }

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
  writeFile stdoutPath stdoutText
  writeFile stderrPath stderrText
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

summaryJsonValue :: String -> String -> Options -> Int -> [Row] -> Json
summaryJsonValue stamp system options failures rows =
  Json.object
    [ ("schema", Json.string "penance/architecture-phase-bench/1")
    , ("created", Json.string stamp)
    , ("system", Json.string system)
    , ("flake", Json.string (optFlake options))
    , ("matrix", Json.string (optMatrix options))
    , ( "options"
      , Json.object
          [ ("repeat", jsonNumber (toInteger (optRepeat options)))
          , ("rebuild", Json.bool (optRebuild options))
          , ("dryRun", Json.bool (optDryRun options))
          ]
      )
    , ("failures", jsonNumber (toInteger failures))
    , ("rows", Json.array (map rowJson rows))
    ]

rowJson :: Row -> Json
rowJson row =
  Json.object
    [ ("runId", Json.string (rowRunId row))
    , ("phaseId", Json.string (rowPhaseId row))
    , ("milestone", Json.string (rowMilestone row))
    , ("phaseTitle", Json.string (rowPhaseTitle row))
    , ("backend", Json.string (rowBackend row))
    , ("attr", maybe Json.JsonNull Json.string (rowAttr row))
    , ("action", Json.string (rowAction row))
    , ("status", Json.string (rowStatus row))
    , ("supported", Json.bool (rowSupported row))
    , ("wallMs", jsonNumber (rowWallMs row))
    , ("drvPath", maybe Json.JsonNull Json.string (rowDrvPath row))
    , ("outPath", maybe Json.JsonNull Json.string (rowOutPath row))
    , ("closureNarSize", jsonNumber (rowClosureNarSize row))
    , ("log", maybe Json.JsonNull Json.string (rowLog row))
    , ("command", maybe Json.JsonNull Json.string (rowCommand row))
    ]

renderHumanSummary :: String -> Int -> [Row] -> String
renderHumanSummary system failures rows =
  unlines $
    [ "Architecture benchmark summary"
    , "  system: " ++ system
    , "  result: " ++ if failures == 0 then "PASS" else "FAIL (" ++ show failures ++ " failure(s))"
    , "  rows: " ++ show (length rows)
    , ""
    , "Failures:"
    ]
      ++ renderFailures
      ++ [ ""
         , "Measurements:"
         ]
      ++ renderMeasurements
      ++ [ ""
         , "Skipped:"
         ]
      ++ renderSkipped
  where
    failureRows =
      filter
        ( \row ->
            rowAction row == "architecture_failure"
              || (rowAction row /= "skipped" && rowStatus row /= "0")
        )
        rows
    measurementRows =
      filter
        (\row -> rowAction row `elem` ["eval_drv_path", "build", "build_dry_run"])
        rows
    skippedRows = filter ((== "skipped") . rowAction) rows

    renderFailures =
      if null failureRows
        then ["  none"]
        else
          map
            ( \row ->
                "  - "
                  ++ rowPhaseId row
                  ++ " ["
                  ++ rowStatus row
                  ++ "]: "
                  ++ fromMaybe (fromMaybe "see log" (rowLog row)) (rowCommand row)
            )
            failureRows
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
    renderSkipped =
      if null skippedRows
        then ["  none"]
        else map (\row -> "  - " ++ rowPhaseId row ++ " [" ++ rowStatus row ++ "]") skippedRows

type MeasurementKey = (String, String, String)

measurementGroups :: [Row] -> [(MeasurementKey, Maybe Row, Maybe Row)]
measurementGroups rows =
  map groupFor (uniqueValues (map measurementKey rows))
  where
    groupFor key =
      ( key
      , findMeasurement key "penance"
      , findMeasurement key "haskell.nix"
      )
    findMeasurement key backend =
      find
        (\row -> measurementKey row == key && rowBackend row == backend)
        rows

measurementKey :: Row -> MeasurementKey
measurementKey row =
  (rowRunId row, rowPhaseId row, rowAction row)

hasMultipleRuns :: [Row] -> Bool
hasMultipleRuns rows =
  case uniqueValues (map rowRunId rows) of
    _ : _ : _ -> True
    _ -> False

renderMeasurementGroup :: Bool -> (MeasurementKey, Maybe Row, Maybe Row) -> String
renderMeasurementGroup includeRun ((runId, phaseIdValue, action), penanceRow, haskellNixRow) =
  "  " ++ formatColumns widths values
  where
    winners = winnerBackends [("penance", penanceRow), ("haskell.nix", haskellNixRow)]
    baseValues =
      [ phaseIdValue
      , action
      , renderBackendCell winners "penance" penanceRow
      , renderBackendCell winners "haskell.nix" haskellNixRow
      ]
    values =
      if includeRun
        then runId : baseValues
        else baseValues
    widths =
      if includeRun
        then [6, 24, 15, 17, 17]
        else [24, 15, 17, 17]

renderBackendCell :: [String] -> String -> Maybe Row -> String
renderBackendCell winners backend maybeRow =
  case maybeRow of
    Nothing -> "-"
    Just row ->
      renderSeconds (rowWallMs row)
        ++ statusSuffix row
        ++ if backend `elem` winners then " ✅" else ""

statusSuffix :: Row -> String
statusSuffix row =
  if rowStatus row == "0"
    then ""
    else " (" ++ rowStatus row ++ ")"

winnerBackends :: [(String, Maybe Row)] -> [String]
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
      , rowStatus row == "0"
      ]

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
  intercalate
    "\t"
    [ rowRunId row
    , rowPhaseId row
    , rowMilestone row
    , rowPhaseTitle row
    , rowBackend row
    , fromMaybe "" (rowAttr row)
    , rowAction row
    , rowStatus row
    , if rowSupported row then "1" else "0"
    , show (rowWallMs row)
    , fromMaybe "" (rowDrvPath row)
    , fromMaybe "" (rowOutPath row)
    , show (rowClosureNarSize row)
    , fromMaybe "" (rowLog row)
    , fromMaybe "" (rowCommand row)
    ]

tsvHeader :: String
tsvHeader =
  intercalate
    "\t"
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

numberField :: String -> [(String, Json)] -> Either String Integer
numberField name fields =
  case lookup name fields of
    Just (JsonNumber value) ->
      case reads value of
        [(n, "")] -> Right n
        _ -> Left ("invalid JSON number in field `" ++ name ++ "`")
    Just other -> Left ("expected JSON number field `" ++ name ++ "`, got " ++ show other)
    Nothing -> Left ("missing JSON field `" ++ name ++ "`")

foldlM :: (Monad m) => (a -> b -> m a) -> a -> [b] -> m a
foldlM _ acc [] = pure acc
foldlM f acc (x : xs) = f acc x >>= \next -> foldlM f next xs

nowMillis :: IO Integer
nowMillis = round . (* 1000) <$> getPOSIXTime

exitCodeInt :: ExitCode -> Int
exitCodeInt ExitSuccess = 0
exitCodeInt (ExitFailure n) = n

jsonNumber :: Integer -> Json
jsonNumber = JsonNumber . show

formatColumns :: [Int] -> [String] -> String
formatColumns widths values =
  unwords (zipWith padRight widths values)

padRight :: Int -> String -> String
padRight width text =
  take width (text ++ repeat ' ')

renderSeconds :: Integer -> String
renderSeconds ms
  | ms == 0 = "-"
  | otherwise =
      let centiseconds = (ms + 5) `div` 10
          secondsPart = centiseconds `div` 100
          fracPart = centiseconds `mod` 100
       in show secondsPart ++ "." ++ twoDigits fracPart ++ "s"

twoDigits :: Integer -> String
twoDigits n
  | n < 10 = '0' : show n
  | otherwise = show n

sanitize :: String -> String
sanitize =
  map (\ch -> if isAlphaNum ch || ch `elem` ("._-" :: String) then ch else '-')

strip :: String -> String
strip =
  dropWhileEndLike isSpaceLike . dropWhile isSpaceLike

dropWhileEndLike :: (Char -> Bool) -> String -> String
dropWhileEndLike predicate =
  reverse . dropWhile predicate . reverse

isSpaceLike :: Char -> Bool
isSpaceLike ch = ch `elem` (" \t\r\n" :: String)

nonEmptyMaybe :: String -> Maybe String
nonEmptyMaybe "" = Nothing
nonEmptyMaybe value = Just value

die :: String -> IO a
die message = hPutStr stderr (message ++ "\n") >> exitFailure
