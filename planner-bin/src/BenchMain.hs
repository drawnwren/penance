module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM)
import Data.List (intercalate, isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getCurrentDirectory,
    getTemporaryDirectory,
  )
import System.Environment (getArgs, getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO
  ( BufferMode (LineBuffering),
    Handle,
    IOMode (WriteMode),
    hPutStrLn,
    hSetBuffering,
    stdout,
    withFile,
  )
import System.Process
  ( CreateProcess (env, std_err, std_in, std_out),
    StdStream (NoStream, UseHandle),
    createProcess,
    proc,
    waitForProcess,
  )
import Text.Printf (printf)

data Options = Options
  { optSystem :: Maybe String,
    optArchitectureRunner :: Maybe FilePath,
    optFunctionalityRunner :: Maybe FilePath,
    optBaselineRunner :: Maybe FilePath,
    optRebuildScenariosRunner :: Maybe FilePath,
    optSurfaceRunner :: Maybe FilePath,
    optLegacyRunner :: Maybe FilePath,
    optHackageRunner :: Maybe FilePath,
    optStackageRunner :: Maybe FilePath,
    optHackagePackage :: String,
    optHackageIndexState :: Maybe String,
    optStackageResolver :: String,
    optStackagePackage :: String,
    optStackageDryRun :: Bool,
    optOutDir :: Maybe FilePath
  }

data Suite = Suite
  { suiteName :: String,
    suiteLabel :: String,
    suiteCommand :: [String],
    suiteEnv :: [(String, String)]
  }

data SuiteResult = SuiteResult
  { resultSuite :: Suite,
    resultStatus :: ExitCode,
    resultWallSeconds :: Double,
    resultLogPath :: FilePath
  }

defaultOptions :: IO Options
defaultOptions = do
  resolver <- lookupEnvWithDefault "PENANCE_BENCH_STACKAGE_RESOLVER" "lts-23.25"
  stackagePackage <- lookupEnvWithDefault "PENANCE_BENCH_STACKAGE_PACKAGE" "servant"
  hackagePackage <- lookupEnvWithDefault "PENANCE_BENCH_HACKAGE_PACKAGE" "StateVar-1.2.2"
  hackageIndexState <- lookupEnv "PENANCE_BENCH_HACKAGE_INDEX_STATE"
  stackageDryRun <- truthyEnv <$> lookupEnv "PENANCE_BENCH_STACKAGE_DRY_RUN"
  outDir <- lookupEnv "PENANCE_BENCH_OUT_DIR"
  pure
    Options
      { optSystem = Nothing,
        optArchitectureRunner = Nothing,
        optFunctionalityRunner = Nothing,
        optBaselineRunner = Nothing,
        optRebuildScenariosRunner = Nothing,
        optSurfaceRunner = Nothing,
        optLegacyRunner = Nothing,
        optHackageRunner = Nothing,
        optStackageRunner = Nothing,
        optHackagePackage = hackagePackage,
        optHackageIndexState = hackageIndexState,
        optStackageResolver = resolver,
        optStackagePackage = stackagePackage,
        optStackageDryRun = stackageDryRun,
        optOutDir = outDir
      }

main :: IO ()
main = do
  defaults <- defaultOptions
  args <- getArgs
  options <- parseArgs defaults args
  systemName <- requireOption "system" optSystem options
  architectureRunner <- requireOption "architecture-runner" optArchitectureRunner options
  functionalityRunner <- requireOption "architecture-functionality-runner" optFunctionalityRunner options
  baselineRunner <- requireOption "haskell-nix-baseline-runner" optBaselineRunner options
  rebuildScenariosRunner <- requireOption "rebuild-scenarios-runner" optRebuildScenariosRunner options
  surfaceRunner <- requireOption "surface-parity-runner" optSurfaceRunner options
  legacyRunner <- requireOption "legacy-runner" optLegacyRunner options
  hackageRunner <- requireOption "hackage-runner" optHackageRunner options
  stackageRunner <- requireOption "stackage-runner" optStackageRunner options
  outDir <- resolveOutDir systemName (optOutDir options)
  createDirectoryIfMissing True outDir

  let suites =
        [ Suite
            { suiteName = "architecture-phases",
              suiteLabel = "Architecture phases",
              suiteCommand = [architectureRunner, "--keep-going"],
              suiteEnv = [("PENANCE_PHASE_BENCH_OUT", outDir </> "architecture")]
            },
          Suite
            { suiteName = "architecture-rebuild",
              suiteLabel = "Architecture rebuild",
              suiteCommand = [architectureRunner, "--keep-going", "--rebuild"],
              suiteEnv = [("PENANCE_PHASE_BENCH_OUT", outDir </> "architecture-rebuild")]
            },
          Suite
            { suiteName = "architecture-functionality",
              suiteLabel = "Architecture functionality gaps",
              suiteCommand = [functionalityRunner, "--keep-going"],
              suiteEnv = [("PENANCE_PHASE_BENCH_OUT", outDir </> "architecture-functionality")]
            },
          Suite
            { suiteName = "rebuild-scenarios",
              suiteLabel = "Rebuild scenarios",
              suiteCommand = [rebuildScenariosRunner, "--keep-going"],
              suiteEnv = [("PENANCE_REBUILD_BENCH_OUT", outDir </> "rebuild-scenarios")]
            },
          Suite
            { suiteName = "haskell-nix-baseline",
              suiteLabel = "haskell.nix baseline",
              suiteCommand = [baselineRunner, "--keep-going"],
              suiteEnv = [("PENANCE_PHASE_BENCH_OUT", outDir </> "haskell-nix-baseline")]
            },
          Suite
            { suiteName = "surface-parity",
              suiteLabel = "Surface parity",
              suiteCommand = [surfaceRunner],
              suiteEnv = []
            },
          Suite
            { suiteName = "legacy-vs-haskell-nix",
              suiteLabel = "Legacy vs haskell.nix",
              suiteCommand = [legacyRunner],
              suiteEnv = [("PENANCE_BENCH_OUT", outDir </> "legacy")]
            },
          Suite
            { suiteName = "hackage-package-validation",
              suiteLabel = "Hackage package validation",
              suiteCommand = hackageCommand hackageRunner options,
              suiteEnv = [("PENANCE_HACKAGE_OUT_DIR", outDir </> "hackage")]
            },
          Suite
            { suiteName = "stackage-package-closure",
              suiteLabel = "Stackage package closure",
              suiteCommand = stackageCommand stackageRunner options,
              suiteEnv =
                [ ("PENANCE_STACKAGE_BENCH_OUT", outDir </> "stackage"),
                  ("PENANCE_STACKAGE_OUT_DIR", outDir </> "stackage")
                ]
            }
        ]

  putStrLn "Penance total benchmark"
  putStrLn ("  system: " <> systemName)
  putStrLn ("  output: " <> outDir)
  putStrLn ("  stackage: " <> optStackageResolver options <> " " <> optStackagePackage options <> " (" <> stackageMode options <> ")")
  putStrLn ("  hackage: " <> optHackagePackage options)
  putStrLn ""
  putStrLn "Running suites:"
  hSetBuffering stdout LineBuffering
  results <- forM suites (runSuite outDir)
  comparisonTimings <- collectComparisonTimings results
  metricTables <- collectMetricTables results
  writeSummaries outDir systemName options results comparisonTimings metricTables
  putStrLn ""
  putStrLn (renderHumanSummary outDir systemName options results comparisonTimings metricTables)
  if anyFailed results then exitFailure else exitSuccess

parseArgs :: Options -> [String] -> IO Options
parseArgs options [] = pure options
parseArgs _ ("-h" : _) = usageAndExit
parseArgs _ ("--help" : _) = usageAndExit
parseArgs options ("--system" : value : rest) =
  parseArgs options {optSystem = Just value} rest
parseArgs options ("--architecture-runner" : value : rest) =
  parseArgs options {optArchitectureRunner = Just value} rest
parseArgs options ("--architecture-functionality-runner" : value : rest) =
  parseArgs options {optFunctionalityRunner = Just value} rest
parseArgs options ("--haskell-nix-baseline-runner" : value : rest) =
  parseArgs options {optBaselineRunner = Just value} rest
parseArgs options ("--rebuild-scenarios-runner" : value : rest) =
  parseArgs options {optRebuildScenariosRunner = Just value} rest
parseArgs options ("--surface-parity-runner" : value : rest) =
  parseArgs options {optSurfaceRunner = Just value} rest
parseArgs options ("--legacy-runner" : value : rest) =
  parseArgs options {optLegacyRunner = Just value} rest
parseArgs options ("--hackage-runner" : value : rest) =
  parseArgs options {optHackageRunner = Just value} rest
parseArgs options ("--stackage-runner" : value : rest) =
  parseArgs options {optStackageRunner = Just value} rest
parseArgs options ("--hackage-package" : value : rest) =
  parseArgs options {optHackagePackage = value} rest
parseArgs options ("--hackage-index-state" : value : rest) =
  parseArgs options {optHackageIndexState = Just value} rest
parseArgs options ("--stackage-resolver" : value : rest) =
  parseArgs options {optStackageResolver = value} rest
parseArgs options ("--stackage-package" : value : rest) =
  parseArgs options {optStackagePackage = value} rest
parseArgs options ("--stackage-dry-run" : rest) =
  parseArgs options {optStackageDryRun = True} rest
parseArgs options ("--out-dir" : value : rest) =
  parseArgs options {optOutDir = Just value} rest
parseArgs _ (flag : _) =
  fail ("unknown option: " <> flag <> "\n\n" <> usageText)

usageAndExit :: IO a
usageAndExit = putStr usageText >> exitSuccess

usageText :: String
usageText =
  unlines
    [ "usage: penance-bench --system SYSTEM \\",
      "                     --architecture-runner PATH \\",
      "                     --architecture-functionality-runner PATH \\",
      "                     --haskell-nix-baseline-runner PATH \\",
      "                     --rebuild-scenarios-runner PATH \\",
      "                     --surface-parity-runner PATH \\",
      "                     --legacy-runner PATH \\",
      "                     --hackage-runner PATH \\",
      "                     --stackage-runner PATH [options]",
      "",
      "Options:",
      "  --hackage-package PACKAGE     default: PENANCE_BENCH_HACKAGE_PACKAGE or StateVar-1.2.2",
      "  --hackage-index-state STATE   default: validate-hackage-package default",
      "  --stackage-resolver RESOLVER  default: PENANCE_BENCH_STACKAGE_RESOLVER or lts-23.25",
      "  --stackage-package PACKAGE    default: PENANCE_BENCH_STACKAGE_PACKAGE or servant",
      "  --stackage-dry-run            use dry-run mode for the Stackage closure suite",
      "  --out-dir DIR                 default: docs/bench-results/bench/SYSTEM-TIMESTAMP"
    ]

requireOption :: String -> (Options -> Maybe a) -> Options -> IO a
requireOption name getter options =
  case getter options of
    Just value -> pure value
    Nothing -> fail ("missing required option --" <> name <> "\n\n" <> usageText)

lookupEnvWithDefault :: String -> String -> IO String
lookupEnvWithDefault name fallback = fromMaybe fallback <$> lookupEnv name

hackageCommand :: FilePath -> Options -> [String]
hackageCommand runner options =
  [runner]
    ++ maybe [] (\state -> ["--index-state", state]) (optHackageIndexState options)
    ++ [optHackagePackage options]

stackageCommand :: FilePath -> Options -> [String]
stackageCommand runner options =
  [runner]
    ++ ["--resolver", optStackageResolver options, "--package", optStackagePackage options]
    ++ if optStackageDryRun options then ["--dry-run"] else []

stackageMode :: Options -> String
stackageMode options =
  if optStackageDryRun options
    then "dry-run"
    else "full closure"

resolveOutDir :: String -> Maybe FilePath -> IO FilePath
resolveOutDir _ (Just dir) = pure dir
resolveOutDir systemName Nothing = do
  cwd <- getCurrentDirectory
  stamp <- timestamp
  if "/nix/store/" `isPrefixOfString` cwd
    then do
      tmp <- getTemporaryDirectory
      pure (tmp </> "penance-bench-results" </> (systemName <> "-" <> stamp))
    else pure ("docs" </> "bench-results" </> "bench" </> (systemName <> "-" <> stamp))

runSuite :: FilePath -> Suite -> IO SuiteResult
runSuite outDir suite = do
  let logPath = outDir </> suiteName suite <> ".log"
  printf "  %-28s ... " (suiteLabel suite)
  start <- getCurrentTime
  status <-
    withFile logPath WriteMode $ \logHandle -> do
      hSetBuffering logHandle LineBuffering
      hPutStrLn logHandle ("command: " <> renderCommand (suiteCommand suite))
      if null (suiteEnv suite)
        then pure ()
        else hPutStrLn logHandle ("environment: " <> renderEnvironment (suiteEnv suite))
      hPutStrLn logHandle ""
      attempt <- try (runLoggedWithEnv logHandle (suiteEnv suite) (suiteCommand suite)) :: IO (Either SomeException ExitCode)
      case attempt of
        Right exitCode -> pure exitCode
        Left exception -> do
          hPutStrLn logHandle ("runner error: " <> displayException exception)
          pure (ExitFailure 127)
  end <- getCurrentTime
  let wall = realToFrac (diffUTCTime end start) :: Double
  putStrLn (statusLabel status <> " " <> formatSeconds wall)
  pure
    SuiteResult
      { resultSuite = suite,
        resultStatus = status,
        resultWallSeconds = wall,
        resultLogPath = logPath
      }

runLoggedWithEnv :: Handle -> [(String, String)] -> [String] -> IO ExitCode
runLoggedWithEnv _ _ [] = pure (ExitFailure 127)
runLoggedWithEnv logHandle extraEnv (exe : arguments) = do
  baseEnv <- getEnvironment
  (_, _, _, processHandle) <-
    createProcess
      (proc exe arguments)
        { std_in = NoStream,
          std_out = UseHandle logHandle,
          std_err = UseHandle logHandle,
          env = Just (mergeEnvironment extraEnv baseEnv)
        }
  waitForProcess processHandle

writeSummaries :: FilePath -> String -> Options -> [SuiteResult] -> [(SuiteResult, [String])] -> [(SuiteResult, FilePath, [[String]])] -> IO ()
writeSummaries outDir systemName options results comparisonTimings metricTables = do
  let summaryText = renderHumanSummary outDir systemName options results comparisonTimings metricTables
      tsvPath = outDir </> "summary.tsv"
      txtPath = outDir </> "summary.txt"
  writeFile txtPath summaryText
  writeFile tsvPath (renderTsv results)

renderHumanSummary :: FilePath -> String -> Options -> [SuiteResult] -> [(SuiteResult, [String])] -> [(SuiteResult, FilePath, [[String]])] -> String
renderHumanSummary outDir systemName options results comparisonTimings metricTables =
  unlines $
    [ "Penance benchmark summary",
      "  result: " <> totalStatus results,
      "  system: " <> systemName,
      "  output: " <> outDir,
      "  stackage: " <> optStackageResolver options <> " " <> optStackagePackage options <> " (" <> stackageMode options <> ")",
      "  hackage: " <> optHackagePackage options,
      "",
      padRight 30 "SUITE" <> "  " <> padRight 6 "STATUS" <> "  " <> padRight 8 "WALL" <> "  LOG",
      padRight 30 "-----" <> "  " <> padRight 6 "------" <> "  " <> padRight 8 "----" <> "  ---"
    ]
      <> map renderResultRow results
      <> renderComparisonTimings comparisonTimings
      <> renderMetricTables metricTables
      <> failureSection results
      <> [ "",
           "Summary files:",
           "  " <> outDir </> "summary.txt",
           "  " <> outDir </> "summary.tsv"
         ]

renderResultRow :: SuiteResult -> String
renderResultRow result =
  padRight 30 (suiteName (resultSuite result))
    <> "  "
    <> padRight 6 (statusLabel (resultStatus result))
    <> "  "
    <> padRight 8 (formatSeconds (resultWallSeconds result))
    <> "  "
    <> resultLogPath result

failureSection :: [SuiteResult] -> [String]
failureSection results =
  case filter (isFailure . resultStatus) results of
    [] -> ["", "Failures:", "  none"]
    failed ->
      ""
        : "Failures:"
        : map
          ( \result ->
              "  - "
                <> suiteName (resultSuite result)
                <> " exited "
                <> exitCodeText (resultStatus result)
                <> "; see "
                <> resultLogPath result
          )
          failed

collectComparisonTimings :: [SuiteResult] -> IO [(SuiteResult, [String])]
collectComparisonTimings results =
  fmap concat $
    forM results $ \result -> do
      contents <- try (readFile (resultLogPath result)) :: IO (Either SomeException String)
      case contents of
        Left _ -> pure []
        Right text ->
          case extractMeasurements (lines text) of
            [] -> pure []
            measurementLines -> pure [(result, measurementLines)]

extractMeasurements :: [String] -> [String]
extractMeasurements input =
  case dropWhile (/= "Measurements:") input of
    [] -> []
    (_ : rest) -> trimBlankSuffix (takeUntilSection rest)

takeUntilSection :: [String] -> [String]
takeUntilSection [] = []
takeUntilSection (line : rest)
  | line == "Skipped:" = []
  | line == "Summary files:" = []
  | "==" `isPrefixOf` line = []
  | otherwise = line : takeUntilSection rest

renderComparisonTimings :: [(SuiteResult, [String])] -> [String]
renderComparisonTimings [] = []
renderComparisonTimings timings =
  ""
    : "Framework timings:"
    : concatMap renderSuiteTimings timings

renderSuiteTimings :: (SuiteResult, [String]) -> [String]
renderSuiteTimings (result, measurementLines) =
  ("  " <> suiteName (resultSuite result) <> ":")
    : map ("  " <>) measurementLines

trimBlankSuffix :: [String] -> [String]
trimBlankSuffix = reverse . dropWhile null . reverse

collectMetricTables :: [SuiteResult] -> IO [(SuiteResult, FilePath, [[String]])]
collectMetricTables results =
  fmap concat $
    forM results $ \result -> do
      contents <- try (readFile (resultLogPath result)) :: IO (Either SomeException String)
      case contents of
        Left _ -> pure []
        Right text -> do
          let paths = uniqueStrings (metricPathsFromLog (lines text))
          fmap concat $
            forM paths $ \path -> do
              exists <- doesFileExist path
              if not exists
                then pure []
                else do
                  tableText <- readFile path
                  case parseTsvTable tableText of
                    [] -> pure []
                    rows -> pure [(result, path, rows)]

metricPathsFromLog :: [String] -> [FilePath]
metricPathsFromLog =
  filter (".tsv" `isSuffixOf`) . mapMaybe metricPathFromLine

metricPathFromLine :: String -> Maybe FilePath
metricPathFromLine line =
  let trimmed = trim line
      withoutWrote =
        if "wrote " `isPrefixOf` trimmed
          then trim (drop (length ("wrote " :: String)) trimmed)
          else trimmed
   in if ".tsv" `isSuffixOf` withoutWrote
        then Just withoutWrote
        else Nothing

parseTsvTable :: String -> [[String]]
parseTsvTable =
  map (splitOnTab . trimEnd) . filter (not . null) . lines

renderMetricTables :: [(SuiteResult, FilePath, [[String]])] -> [String]
renderMetricTables [] = []
renderMetricTables tables =
  ""
    : "Suite metrics:"
    : concatMap renderMetricTable tables

renderMetricTable :: (SuiteResult, FilePath, [[String]]) -> [String]
renderMetricTable (result, path, rows) =
  case rows of
    [] -> []
    [_] -> []
    (header : metricRows) ->
      ("  " <> suiteName (resultSuite result) <> " (" <> path <> "):")
        : "    SCENARIO                         STATUS            WALL      COUNT"
        : "    --------                         ------            ----      -----"
        : map (renderMetricRow header) metricRows

renderMetricRow :: [String] -> [String] -> String
renderMetricRow header fields =
  let scenario = fieldNamed header fields ["scenario_id", "scenario", "phase_id"] 0
      status = fieldNamed header fields ["status"] 1
      wall = renderWallField header fields
      count = fieldNamed header fields ["rebuilt_drv_count"] (-1)
   in "    "
        <> padRight 32 scenario
        <> " "
        <> padRight 16 status
        <> "  "
        <> padRight 8 wall
        <> "  "
        <> count

renderWallField :: [String] -> [String] -> String
renderWallField header fields =
  case indexOf "wall_seconds" header of
    Just index -> fieldAt index fields <> "s"
    Nothing ->
      case indexOf "wall_ms" header of
        Just index -> renderMillisText (fieldAt index fields)
        Nothing -> fieldAt 2 fields <> "s"

renderMillisText :: String -> String
renderMillisText value =
  case reads value :: [(Integer, String)] of
    [(ms, "")] -> printf "%.2fs" ((fromIntegral ms / 1000) :: Double)
    _ -> value

fieldNamed :: [String] -> [String] -> [String] -> Int -> String
fieldNamed header fields names fallback =
  case firstIndex names header of
    Just index -> fieldAt index fields
    Nothing ->
      if fallback >= 0
        then fieldAt fallback fields
        else ""

firstIndex :: [String] -> [String] -> Maybe Int
firstIndex [] _ = Nothing
firstIndex (name : rest) values =
  case indexOf name values of
    Just index -> Just index
    Nothing -> firstIndex rest values

indexOf :: String -> [String] -> Maybe Int
indexOf needle = go 0
  where
    go _ [] = Nothing
    go index (value : rest)
      | value == needle = Just index
      | otherwise = go (index + 1) rest

fieldAt :: Int -> [String] -> String
fieldAt index fields =
  if index < length fields
    then fields !! index
    else ""

renderTsv :: [SuiteResult] -> String
renderTsv results =
  unlines $
    "suite\tlabel\tstatus\texit_code\twall_seconds\tlog\tcommand"
      : map
        ( \result ->
            intercalate
              "\t"
              [ suiteName (resultSuite result),
                suiteLabel (resultSuite result),
                statusLabel (resultStatus result),
                exitCodeText (resultStatus result),
                printf "%.2f" (resultWallSeconds result),
                resultLogPath result,
                renderCommand (suiteCommand (resultSuite result))
              ]
        )
        results

totalStatus :: [SuiteResult] -> String
totalStatus results =
  let failures = length (filter (isFailure . resultStatus) results)
   in if failures == 0
        then "PASS"
        else "FAIL (" <> show failures <> " " <> pluralize failures "suite" <> " failed)"

anyFailed :: [SuiteResult] -> Bool
anyFailed = any (isFailure . resultStatus)

isFailure :: ExitCode -> Bool
isFailure ExitSuccess = False
isFailure (ExitFailure _) = True

statusLabel :: ExitCode -> String
statusLabel ExitSuccess = "PASS"
statusLabel (ExitFailure _) = "FAIL"

exitCodeText :: ExitCode -> String
exitCodeText ExitSuccess = "0"
exitCodeText (ExitFailure code) = show code

formatSeconds :: Double -> String
formatSeconds = printf "%.2fs"

timestamp :: IO String
timestamp = formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" <$> getCurrentTime

padRight :: Int -> String -> String
padRight width value = take width (value <> repeat ' ')

renderCommand :: [String] -> String
renderCommand = unwords . map shellQuote

renderEnvironment :: [(String, String)] -> String
renderEnvironment =
  unwords . map (\(name, value) -> name <> "=" <> shellQuote value)

shellQuote :: String -> String
shellQuote value
  | null value = "''"
  | all isSimpleShellChar value = value
  | otherwise = "'" <> concatMap quoteChar value <> "'"
  where
    quoteChar '\'' = "'\\''"
    quoteChar char = [char]

isSimpleShellChar :: Char -> Bool
isSimpleShellChar char =
  char `elem` (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "-_./:=+@,%")

isPrefixOfString :: String -> String -> Bool
isPrefixOfString prefix value = take (length prefix) value == prefix

pluralize :: Int -> String -> String
pluralize 1 value = value
pluralize _ value = value <> "s"

trim :: String -> String
trim = trimEnd . dropWhile isSpaceChar

trimEnd :: String -> String
trimEnd = reverse . dropWhile isSpaceChar . reverse

isSpaceChar :: Char -> Bool
isSpaceChar char = char `elem` (" \t\r\n" :: String)

splitOnTab :: String -> [String]
splitOnTab [] = [""]
splitOnTab value =
  case break (== '\t') value of
    (field, []) -> [field]
    (field, _ : rest) -> field : splitOnTab rest

uniqueStrings :: [String] -> [String]
uniqueStrings = go []
  where
    go _ [] = []
    go seen (value : rest)
      | value `elem` seen = go seen rest
      | otherwise = value : go (value : seen) rest

truthyEnv :: Maybe String -> Bool
truthyEnv Nothing = False
truthyEnv (Just value) = value `elem` ["1", "true", "TRUE", "yes", "YES", "on", "ON"]

mergeEnvironment :: [(String, String)] -> [(String, String)] -> [(String, String)]
mergeEnvironment overrides base =
  overrides ++ filter (\(name, _) -> name `notElem` overrideNames) base
  where
    overrideNames = map fst overrides
