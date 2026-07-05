module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless, when)
import Data.Char (isAlphaNum)
import Data.List (intercalate, isPrefixOf, isSuffixOf, sort, nub, (\\))
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Penance.Json (Json (..), parseJson, renderJson)
import qualified Penance.Json as Json
import System.Directory
  ( canonicalizePath
  , copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , getTemporaryDirectory
  , listDirectory
  , removePathForcibly
  )
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO (hPutStr, stderr)
import System.Process
  ( CreateProcess (cwd)
  , proc
  , readCreateProcessWithExitCode
  )

data Options = Options
  { optFlake :: FilePath
  , optScenarios :: FilePath
  , optSystem :: Maybe String
  , optOutDir :: FilePath
  , optSelected :: [String]
  , optKeepGoing :: Bool
  , optList :: Bool
  , optNixBin :: FilePath
  }
  deriving (Eq, Show)

data Scenario = Scenario
  { scenarioId :: String
  , scenarioMilestone :: String
  , scenarioTitle :: String
  , scenarioStatus :: String
  , scenarioAttr :: String
  , scenarioFixture :: FilePath
  , scenarioEdit :: Edit
  , scenarioExpectedMax :: Maybe Int
  , scenarioRequired :: Bool
  , scenarioFailure :: Maybe String
  , scenarioNotes :: Maybe String
  }
  deriving (Eq, Show)

data Edit
  = NoEdit
  | ReplaceEdit
      { editFile :: FilePath
      , editFind :: String
      , editReplace :: String
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
  , rowRebuiltDrvCount :: Int
  , rowRebuiltDrvNames :: [String]
  , rowExpectedMaxRebuiltDrvs :: Maybe Int
  }
  deriving (Eq, Show)

data CommandResult = CommandResult
  { crStatus :: Int
  , crWallMs :: Integer
  , crStdout :: String
  , crStderr :: String
  , crCommand :: String
  }
  deriving (Eq, Show)

main :: IO ()
main = do
  options <- parseOptions =<< getArgs
  scenarios <- readScenarios (optScenarios options)
  if optList options
    then printScenarioList scenarios
    else do
      system <- maybe (detectSystem options) pure (optSystem options)
      runBench options system scenarios

parseOptions :: [String] -> IO Options
parseOptions args = do
  cwdPath <- getCurrentDirectory
  nixBin <- fromMaybe "nix" <$> lookupEnv "PENANCE_NIX_BIN"
  envOut <- lookupEnv "PENANCE_REBUILD_BENCH_OUT"
  envScenarios <- lookupEnv "PENANCE_REBUILD_SCENARIOS"
  let defaults =
        Options
          { optFlake = cwdPath
          , optScenarios =
              fromMaybe
                (cwdPath </> "tests" </> "architecture" </> "rebuild-scenarios.json")
                envScenarios
          , optSystem = Nothing
          , optOutDir =
              fromMaybe
                (cwdPath </> "docs" </> "bench-results" </> "rebuild-scenarios")
                envOut
          , optSelected = []
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
        "--scenarios" : value : xs -> go options {optScenarios = value} xs
        "--system" : value : xs -> go options {optSystem = Just value} xs
        "--out-dir" : value : xs -> go options {optOutDir = value} xs
        "--scenario" : value : xs -> go options {optSelected = optSelected options ++ [value]} xs
        "--keep-going" : xs -> go options {optKeepGoing = True} xs
        "--list" : xs -> go options {optList = True} xs
        "-h" : _ -> usage >> exitSuccess
        "--help" : _ -> usage >> exitSuccess
        flag : _ -> die ("unknown option: " ++ flag)

usage :: IO ()
usage =
  putStrLn $
    unlines
      [ "usage: penance-rebuild-bench [options]"
      , ""
      , "Runs rebuild-count scenarios by copying the local flake to a temporary"
      , "worktree, measuring a baseline dry-run, applying the scenario edit, and"
      , "diffing the edited dry-run derivation set against the baseline."
      , ""
      , "Options:"
      , "  --flake PATH          local flake checkout to copy (default: current directory)"
      , "  --scenarios PATH      rebuild scenario JSON"
      , "  --system SYSTEM       Nix system (default: builtins.currentSystem)"
      , "  --out-dir DIR         output directory"
      , "  --scenario ID         run one scenario; may be repeated"
      , "  --keep-going          continue after a failed scenario"
      , "  --list                print scenarios and exit"
      , "  -h, --help            show this help"
      ]

detectSystem :: Options -> IO String
detectSystem options = do
  (codeValue, stdoutText, stderrText) <-
    readCreateProcessWithExitCode
      (proc (optNixBin options) ["eval", "--raw", "--impure", "--expr", "builtins.currentSystem"])
      ""
  case codeValue of
    ExitSuccess -> pure (strip stdoutText)
    ExitFailure _ -> die ("failed to detect current Nix system:\n" ++ stderrText)

readScenarios :: FilePath -> IO [Scenario]
readScenarios path = do
  exists <- doesFileExist path
  unless exists (die ("rebuild scenarios file not found: " ++ path))
  contents <- readFile path
  value <- either die pure (parseJson contents)
  fields <- expectObject "rebuild scenarios" value
  schema <- stringField "schema" fields
  unless (schema == "penance/rebuild-scenarios/1") $
    die ("unexpected rebuild scenario schema: " ++ schema)
  scenarioValues <- arrayField "scenarios" fields
  traverse decodeScenario scenarioValues

decodeScenario :: Json -> IO Scenario
decodeScenario value = do
  fields <- expectObject "scenario" value
  Scenario
    <$> stringField "id" fields
    <*> stringField "milestone" fields
    <*> stringField "title" fields
    <*> stringField "status" fields
    <*> stringField "attr" fields
    <*> stringField "fixture" fields
    <*> (decodeEdit =<< objectField "edit" fields)
    <*> optionalIntField "expectedMaxRebuiltDrvs" fields
    <*> boolField "required" fields
    <*> optionalStringField "failure" fields
    <*> optionalStringField "notes" fields

decodeEdit :: [(String, Json)] -> IO Edit
decodeEdit fields = do
  editType <- optionalStringField "type" fields
  case editType of
    Nothing -> decodeReplace
    Just "none" -> pure NoEdit
    Just "replace" -> decodeReplace
    Just other -> die ("unknown edit type: " ++ other)
  where
    decodeReplace = do
      file <- stringField "file" fields
      patch <- objectField "patch" fields
      ReplaceEdit file
        <$> stringField "find" patch
        <*> stringField "replace" patch

printScenarioList :: [Scenario] -> IO ()
printScenarioList scenarios = do
  let widths =
        [ maxTextWidth 34 (map scenarioId scenarios)
        , maxTextWidth 10 (map scenarioStatus scenarios)
        , maxTextWidth 30 (map scenarioAttr scenarios)
        , maxTextWidth 8 (map (maybe "-" show . scenarioExpectedMax) scenarios)
        ]
  putStrLn (formatColumns widths ["SCENARIO", "STATE", "ATTR", "MAX"] ++ " TITLE")
  putStrLn (formatColumns widths ["--------", "-----", "----", "---"] ++ " -----")
  forM_ scenarios $ \scenario ->
    putStrLn $
      formatColumns
        widths
        [ scenarioId scenario
        , scenarioStatus scenario
        , scenarioAttr scenario
        , maybe "-" show (scenarioExpectedMax scenario)
        ]
        ++ " "
        ++ scenarioTitle scenario

runBench :: Options -> String -> [Scenario] -> IO ()
runBench options system scenarios = do
  stamp <- formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" <$> getCurrentTime
  let runDir = optOutDir options </> system ++ "-" ++ stamp
      logDir = runDir </> "logs"
      metricsTsv = runDir </> "metrics.tsv"
      metricsJsonl = runDir </> "metrics.jsonl"
      summaryJson = runDir </> "summary.json"
      selectedScenarios = filter (selected options) scenarios
  when (null selectedScenarios) (die "no rebuild scenarios selected")
  createDirectoryIfMissing True logDir
  writeFile metricsTsv (tsvHeader ++ "\n")
  writeFile metricsJsonl ""

  (rows, failures) <- runScenarios options system logDir selectedScenarios
  appendFile metricsTsv (concatMap ((++ "\n") . renderTsvRow) rows)
  appendFile metricsJsonl (concatMap ((++ "\n") . renderJson . rowJson) rows)
  writeFile summaryJson (renderJson (summaryJsonValue stamp system options failures rows) ++ "\n")

  hPutStr stderr $
    unlines
      [ "wrote rebuild scenario metrics:"
      , "  " ++ metricsTsv
      , "  " ++ metricsJsonl
      , "  " ++ summaryJson
      ]
  hPutStr stderr (renderHumanSummary system failures rows)
  when (failures /= 0) exitFailure

selected :: Options -> Scenario -> Bool
selected options scenario =
  null (optSelected options) || scenarioId scenario `elem` optSelected options

runScenarios :: Options -> String -> FilePath -> [Scenario] -> IO ([Row], Int)
runScenarios options system logDir scenarios =
  go [] 0 scenarios
  where
    go rows failures [] = pure (rows, failures)
    go rows failures (scenario : rest) = do
      hPutStr stderr ("rebuild scenario " ++ scenarioId scenario ++ " (" ++ scenarioTitle scenario ++ ")\n")
      (row, failed) <- runScenario options system logDir scenario
      let failuresAfter = failures + if failed then 1 else 0
          rowsAfter = rows ++ [row]
      if failed && not (optKeepGoing options)
        then pure (rowsAfter, failuresAfter)
        else go rowsAfter failuresAfter rest

runScenario :: Options -> String -> FilePath -> Scenario -> IO (Row, Bool)
runScenario options system logDir scenario = do
  overallStart <- nowMillis
  bracket (copyFlakeToTemp options scenario) (removePathForcibly . fst) $ \(_, repo) -> do
    let ref = ".#packages." ++ system ++ "." ++ scenarioAttr scenario
        drvRef = ref ++ ".drvPath"
        safeId = sanitize (scenarioId scenario)
        baselineLog = logDir </> safeId ++ "-baseline-dry-run.log"
        pathInfoLog = logDir </> safeId ++ "-baseline-path-info.log"
        evalLog = logDir </> safeId ++ "-edited-eval.log"
        editedLog = logDir </> safeId ++ "-edited-dry-run.log"
    baseline <- timedReadToLog repo baselineLog (optNixBin options) ["build", "--dry-run", ref, "-L"]
    pathInfo <- timedReadToLog repo pathInfoLog (optNixBin options) ["path-info", "--derivation", "-r", ref]
    editResult <- applyEdit repo scenario
    editedEval <- timedReadToLog repo evalLog (optNixBin options) ["eval", "--raw", drvRef]
    edited <- timedReadToLog repo editedLog (optNixBin options) ["build", "--dry-run", ref, "-L"]
    overallEnd <- nowMillis

    let baselineDrvs = extractDrvPaths (crStdout baseline ++ "\n" ++ crStderr baseline)
        pathInfoDrvs = extractDrvPaths (crStdout pathInfo ++ "\n" ++ crStderr pathInfo)
        editedDrvs = extractDrvPaths (crStdout edited ++ "\n" ++ crStderr edited)
        rebuiltDrvs = sort (editedDrvs \\ baselineDrvs)
        rebuiltNames = map drvName rebuiltDrvs
        count = length rebuiltDrvs
        commandStatus =
          firstNonZero
            [ ("baseline dry-run", baseline)
            , ("edited eval", editedEval)
            , ("edited dry-run", edited)
            ]
        boundStatus =
          case scenarioExpectedMax scenario of
            Just maxValue | count > maxValue -> Just ("rebuilt drv count " ++ show count ++ " exceeds expected maximum " ++ show maxValue)
            _ -> Nothing
        statusFailure =
          if scenarioStatus scenario == "failing"
            then Just (fromMaybe "Required rebuild scenario does not have an enforced bound yet" (scenarioFailure scenario))
            else Nothing
        editFailure =
          case editResult of
            Nothing -> Nothing
            Just message -> Just message
        statusText =
          case commandStatus <|> editFailure <|> boundStatus <|> statusFailure of
            Nothing -> "0"
            Just message ->
              if scenarioStatus scenario == "failing" && commandStatus == Nothing && editFailure == Nothing && boundStatus == Nothing
                then "not_implemented"
                else message
        failed = statusText /= "0"
        drvPath = nonEmptyMaybe (strip (crStdout editedEval))
        logText = intercalate ", " [baselineLog, pathInfoLog, evalLog, editedLog]
        commandText =
          intercalate
            "; "
            [ "worktree " ++ repo
            , "edit " ++ editDescription (scenarioEdit scenario)
            , "baseline dry-run drvs " ++ show (length baselineDrvs)
            , "baseline path-info drvs " ++ show (length pathInfoDrvs)
            , "edited dry-run drvs " ++ show (length editedDrvs)
            , "rebuilt drvs " ++ show count
            ]
        row =
          Row
            { rowRunId = "r1"
            , rowPhaseId = scenarioId scenario
            , rowMilestone = scenarioMilestone scenario
            , rowPhaseTitle = scenarioTitle scenario
            , rowBackend = "penance"
            , rowAttr = Just (scenarioAttr scenario)
            , rowAction = "rebuild_dry_run"
            , rowStatus = statusText
            , rowSupported = commandStatus == Nothing && editFailure == Nothing
            , rowWallMs = overallEnd - overallStart
            , rowDrvPath = drvPath
            , rowOutPath = Nothing
            , rowClosureNarSize = 0
            , rowLog = Just logText
            , rowCommand = Just commandText
            , rowRebuiltDrvCount = count
            , rowRebuiltDrvNames = rebuiltNames
            , rowExpectedMaxRebuiltDrvs = scenarioExpectedMax scenario
            }
    pure (row, failed)

copyFlakeToTemp :: Options -> Scenario -> IO (FilePath, FilePath)
copyFlakeToTemp options scenario = do
  flakePath <- canonicalizePath (optFlake options)
  isDir <- doesDirectoryExist flakePath
  unless isDir (die ("--flake must be a local directory for rebuild scenarios: " ++ optFlake options))
  tmp <- getTemporaryDirectory
  stamp <- formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" <$> getCurrentTime
  let root = tmp </> "penance-rebuild-" ++ sanitize (scenarioId scenario) ++ "-" ++ stamp
      repo = root </> "repo"
  createDirectoryIfMissing True repo
  copyDirectoryFiltered flakePath repo
  pure (root, repo)

copyDirectoryFiltered :: FilePath -> FilePath -> IO ()
copyDirectoryFiltered src dst =
  go "" src dst
  where
    go rel currentSrc currentDst = do
      createDirectoryIfMissing True currentDst
      entries <- listDirectory currentSrc
      forM_ entries $ \entry -> do
        let relEntry =
              if null rel
                then entry
                else rel </> entry
            srcEntry = currentSrc </> entry
            dstEntry = currentDst </> entry
        unless (skipCopyPath relEntry) $ do
          isDir <- doesDirectoryExist srcEntry
          if isDir
            then go relEntry srcEntry dstEntry
            else copyFile srcEntry dstEntry

skipCopyPath :: FilePath -> Bool
skipCopyPath path =
  path == ".git"
    || path == "docs/bench-results"
    || ("docs/bench-results/" `isPrefixOf` path)
    || takeFileNameSimple path == "result"
    || ("result-" `isPrefixOf` takeFileNameSimple path)

applyEdit :: FilePath -> Scenario -> IO (Maybe String)
applyEdit repo scenario =
  case scenarioEdit scenario of
    NoEdit -> pure Nothing
    ReplaceEdit file needle replacement -> do
      let path = repo </> scenarioFixture scenario </> file
      exists <- doesFileExist path
      if not exists
        then pure (Just ("edit file not found: " ++ path))
        else do
          contents <- readFile path
          length contents `seq` pure ()
          case replaceOnce needle replacement contents of
            Nothing -> pure (Just ("edit marker not found in " ++ path))
            Just updated -> length updated `seq` writeFile path updated >> pure Nothing

timedReadToLog :: FilePath -> FilePath -> FilePath -> [String] -> IO CommandResult
timedReadToLog workingDir logPath command args = do
  createDirectoryIfMissing True (takeDirectorySimple logPath)
  start <- nowMillis
  (codeValue, stdoutText, stderrText) <-
    readCreateProcessWithExitCode
      (proc command args) {cwd = Just workingDir}
      ""
  end <- nowMillis
  let commandText = command ++ " " ++ unwords args
      status = exitCodeInt codeValue
  writeFile logPath $
    unlines
      [ "command: " ++ commandText
      , "cwd: " ++ workingDir
      , "status: " ++ show status
      , "wall_ms: " ++ show (end - start)
      , ""
      , "stdout:"
      , stdoutText
      , ""
      , "stderr:"
      , stderrText
      ]
  pure
    CommandResult
      { crStatus = status
      , crWallMs = end - start
      , crStdout = stdoutText
      , crStderr = stderrText
      , crCommand = commandText
      }

firstNonZero :: [(String, CommandResult)] -> Maybe String
firstNonZero [] = Nothing
firstNonZero ((label, result) : rest)
  | crStatus result == 0 = firstNonZero rest
  | otherwise = Just (label ++ " exited " ++ show (crStatus result))

extractDrvPaths :: String -> [FilePath]
extractDrvPaths =
  sort . nub . mapMaybe extractDrvPath . words

extractDrvPath :: String -> Maybe FilePath
extractDrvPath token =
  case dropUntilStore token of
    Nothing -> Nothing
    Just storeText ->
      case splitOn ".drv" storeText of
        Nothing -> Nothing
        Just (prefix, _) -> Just (prefix ++ ".drv")

dropUntilStore :: String -> Maybe String
dropUntilStore value
  | "/nix/store/" `isPrefixOf` value = Just value
  | otherwise =
      case value of
        [] -> Nothing
        _ : rest -> dropUntilStore rest

splitOn :: String -> String -> Maybe (String, String)
splitOn needle haystack =
  go "" haystack
  where
    go _ [] = Nothing
    go prefix rest
      | needle `isPrefixOf` rest = Just (reverse prefix, drop (length needle) rest)
      | otherwise =
          case rest of
            ch : xs -> go (ch : prefix) xs
            [] -> Nothing

drvName :: FilePath -> String
drvName path =
  let base = takeFileNameSimple path
      withoutDrv =
        if ".drv" `isSuffixOf` base
          then take (length base - 4) base
          else base
   in if length withoutDrv > 33
        then drop 33 withoutDrv
        else withoutDrv

editDescription :: Edit -> String
editDescription NoEdit = "none"
editDescription (ReplaceEdit file _ _) = "replace in " ++ file

summaryJsonValue :: String -> String -> Options -> Int -> [Row] -> Json
summaryJsonValue stamp system options failures rows =
  Json.object
    [ ("schema", Json.string "penance/rebuild-bench/1")
    , ("created", Json.string stamp)
    , ("system", Json.string system)
    , ("flake", Json.string (optFlake options))
    , ("scenarios", Json.string (optScenarios options))
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
    , ("rebuiltDrvCount", jsonNumber (toInteger (rowRebuiltDrvCount row)))
    , ("rebuiltDrvNames", Json.array (map Json.string (rowRebuiltDrvNames row)))
    , ("expectedMaxRebuiltDrvs", maybe Json.JsonNull (jsonNumber . toInteger) (rowExpectedMaxRebuiltDrvs row))
    ]

renderHumanSummary :: String -> Int -> [Row] -> String
renderHumanSummary system failures rows =
  unlines $
    [ "Rebuild scenario summary"
    , "  system: " ++ system
    , "  result: " ++ if failures == 0 then "PASS" else "FAIL (" ++ show failures ++ " failure(s))"
    , "  rows: " ++ show (length rows)
    , ""
    , "Failures:"
    ]
      ++ renderFailures
      ++ [ ""
         , "Measurements:"
         , "  SCENARIO                          STATUS           REBUILT  WALL"
         , "  --------                          ------           -------  ----"
         ]
      ++ map renderMeasurement rows
  where
    failingRows = filter ((/= "0") . rowStatus) rows
    renderFailures =
      if null failingRows
        then ["  none"]
        else
          map
            ( \row ->
                "  - "
                  ++ rowPhaseId row
                  ++ " ["
                  ++ rowStatus row
                  ++ "]: "
                  ++ fromMaybe "see logs" (rowCommand row)
            )
            failingRows

renderMeasurement :: Row -> String
renderMeasurement row =
  "  "
    ++ formatColumns
      [33, 16, 7, 8]
      [ rowPhaseId row
      , rowStatus row
      , show (rowRebuiltDrvCount row)
      , renderSeconds (rowWallMs row)
      ]

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
    , show (rowRebuiltDrvCount row)
    , intercalate "," (rowRebuiltDrvNames row)
    , maybe "" show (rowExpectedMaxRebuiltDrvs row)
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
    , "rebuilt_drv_count"
    , "rebuilt_drv_names"
    , "expected_max_rebuilt_drvs"
    ]

expectObject :: String -> Json -> IO [(String, Json)]
expectObject _ (JsonObject fields) = pure fields
expectObject context other = die ("expected JSON object for " ++ context ++ ", got " ++ show other)

arrayField :: String -> [(String, Json)] -> IO [Json]
arrayField name fields =
  case lookup name fields of
    Just (JsonArray values) -> pure values
    Just other -> die ("expected JSON array field `" ++ name ++ "`, got " ++ show other)
    Nothing -> die ("missing JSON field `" ++ name ++ "`")

objectField :: String -> [(String, Json)] -> IO [(String, Json)]
objectField name fields =
  case lookup name fields of
    Just (JsonObject values) -> pure values
    Just other -> die ("expected JSON object field `" ++ name ++ "`, got " ++ show other)
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

optionalIntField :: String -> [(String, Json)] -> IO (Maybe Int)
optionalIntField name fields =
  case lookup name fields of
    Just JsonNull -> pure Nothing
    Nothing -> pure Nothing
    Just (JsonNumber value) ->
      case reads value of
        [(n, "")] -> pure (Just n)
        _ -> die ("invalid JSON number in field `" ++ name ++ "`")
    Just other -> die ("expected JSON number/null field `" ++ name ++ "`, got " ++ show other)

forM_ :: (Foldable t, Applicative f) => t a -> (a -> f b) -> f ()
forM_ values action = traverse_ action values

traverse_ :: (Foldable t, Applicative f) => (a -> f b) -> t a -> f ()
traverse_ action = foldr ((*>) . (() <$) . action) (pure ())

(<|>) :: Maybe a -> Maybe a -> Maybe a
Nothing <|> fallback = fallback
value@(Just _) <|> _ = value

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

maxTextWidth :: Int -> [String] -> Int
maxTextWidth minimumWidth values =
  max minimumWidth (maximum (0 : map length values))

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

replaceOnce :: String -> String -> String -> Maybe String
replaceOnce needle replacement haystack =
  case splitOn needle haystack of
    Nothing -> Nothing
    Just (before, after) -> Just (before ++ replacement ++ after)

takeDirectorySimple :: FilePath -> FilePath
takeDirectorySimple path =
  case reverse path of
    [] -> "."
    reversed ->
      case dropWhile (/= '/') reversed of
        [] -> "."
        _ : rest -> reverse rest

takeFileNameSimple :: FilePath -> FilePath
takeFileNameSimple path =
  case reverse path of
    [] -> ""
    reversed -> reverse (takeWhile (/= '/') reversed)

die :: String -> IO a
die message = hPutStr stderr (message ++ "\n") >> exitFailure
