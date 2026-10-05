module Main (main) where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_, handle, onException)
import Control.Monad (filterM, forM_, unless, when)
import Data.Char (isSpace)
import Data.List (dropWhileEnd)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Distribution.Pretty (prettyShow)
import GHC.Conc (getNumProcessors)
import Penance.CabalProject (qualifyConstraintForAllScopes)
import Penance.CabalPlan
  ( CabalPlanRequest (..)
  , ExternalSource (..)
  , ExternalUnit (..)
  , ResolvedPlan (..)
  , renderFlagAssignment
  )
import qualified Penance.CabalPlan as CabalPlan
import Penance.Error (renderPenanceError)
import qualified Penance.Json as Json
import Penance.Repent.Lock (externalUnitExpressionName, lockJson)
import Penance.Repent.PackageSet
  ( PackageSet
  , decodePackageSet
  , extendPackageSetWithPlan
  , packageSetCompiler
  , packageSetConstraints
  , packageSetFromPlan
  , packageSetHash
  , packageSetIndexState
  , packageSetNix
  , packageSetStackage
  , validatePackageSetPlan
  )
import Penance.Repent.Project
  ( readProjectConstraints
  , readProjectIndexState
  , readProjectPackages
  )
import Penance.Types
  ( CompilerId (..)
  , IndexState (..)
  , renderCompilerId
  )
import Penance.Utf8.IO (readUtf8File, writeUtf8File)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , findExecutable
  , listDirectory
  , removeFile
  , renameFile
  )
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), die, exitFailure, exitSuccess)
import System.FilePath
  ( (</>)
  , takeDirectory
  , takeExtension
  )
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

data Options = Options
  { optProject :: FilePath
  , optCompiler :: CompilerId
  , optGhcPkg :: FilePath
  , optCabal :: FilePath
  , optCabal2nix :: FilePath
  , optIndexState :: IndexState
  , optPlanJson :: Maybe FilePath
  , optOut :: Maybe FilePath
  , optCheck :: Maybe FilePath
  , optHackageNixDir :: Maybe FilePath
  , optPackageSet :: Maybe PackageSet
  , optPackageSetBase :: Maybe PackageSet
  , optPackageSetOut :: Maybe FilePath
  , optStackage :: Maybe String
  , optJobs :: Int
  , optRefreshHackageNix :: Bool
  }
  deriving (Eq, Show)

data OptionState = OptionState
  { stateProject :: FilePath
  , stateCompiler :: Maybe CompilerId
  , stateGhcPkg :: Maybe FilePath
  , stateCabal :: FilePath
  , stateCabal2nix :: FilePath
  , stateNix :: FilePath
  , stateIndexState :: Maybe IndexState
  , statePlanJson :: Maybe FilePath
  , stateOut :: Maybe FilePath
  , stateCheck :: Maybe FilePath
  , stateHackageNixDir :: Maybe FilePath
  , statePackageSet :: Maybe FilePath
  , statePackageSetOut :: Maybe FilePath
  , stateStackage :: Maybe String
  , stateJobs :: Int
  , stateRefreshHackageNix :: Bool
  }
  deriving (Eq, Show)

main :: IO ()
main = handle (die . renderPenanceError) run

run :: IO ()
run = do
  opts <- parseOptions =<< getArgs
  packages <- readProjectPackages (optProject opts)
  projectConstraints <- readProjectConstraints (optProject opts)
  let constraintSet =
        case optPackageSet opts of
          Just packageSet -> Just packageSet
          Nothing -> optPackageSetBase opts
  plan <-
    CabalPlan.resolvePlan
      CabalPlanRequest
        { planProject = optProject opts
        , planCompiler = optCompiler opts
        , planGhcPkg = optGhcPkg opts
        , planCabal = optCabal opts
        , planIndexState = optIndexState opts
        , planConstraints =
            map qualifyConstraintForAllScopes projectConstraints
              ++ maybe [] packageSetConstraints constraintSet
        , planInput = optPlanJson opts
        }
      >>= either die pure
  case optPackageSet opts of
    Just packageSet -> either die pure (validatePackageSetPlan packageSet plan)
    Nothing -> pure ()
  generatedPackageSet <-
    case optPackageSetOut opts of
      Just _ ->
        either die (pure . Just) $
          case optPackageSetBase opts of
            Just packageSet -> extendPackageSetWithPlan packageSet plan
            Nothing -> packageSetFromPlan (optCompiler opts) (optIndexState opts) (optStackage opts) plan
      Nothing -> pure Nothing
  let activePackageSet =
        case optPackageSet opts of
          Just packageSet -> Just packageSet
          Nothing -> generatedPackageSet
  rendered <-
    either die (pure . (++ "\n") . Json.renderPrettyJson) (
      lockJson
        (optCompiler opts)
        (optIndexState opts)
        (packageSetHash <$> activePackageSet)
        packages
        plan
    )
  case optCheck opts of
    Just path -> do
      expected <- readUtf8File path
      unless (expected == rendered) $ do
        putStrLn ("repent: lock is stale: " ++ path)
        putStrLn "expected checked-in lock to match generated lock"
        exitFailure
    Nothing ->
      pure ()
  case optHackageNixDir opts of
    Just directory ->
      writeHackageExpressions
        opts
        directory
        (resolvedExternalUnits plan)
        (optPackageSet opts == Nothing && optPackageSetOut opts == Nothing)
    Nothing -> pure ()
  case (optPackageSetOut opts, generatedPackageSet) of
    (Just path, Just packageSet) -> do
      writeUtf8File path (packageSetNix packageSet)
      putStrLn ("repent: wrote " ++ path)
    _ -> pure ()
  case optOut opts of
    Just path -> do
      writeUtf8File path rendered
      putStrLn ("repent: wrote " ++ path)
    Nothing ->
      when (optCheck opts == Nothing) (putStr rendered)
  exitSuccess

parseOptions :: [String] -> IO Options
parseOptions args = do
  envProject <- lookupEnv "PENANCE_PROJECT"
  envCompiler <- fmap CompilerId <$> lookupEnv "PENANCE_COMPILER"
  envGhcPkg <- lookupEnv "PENANCE_GHC_PKG"
  envCabal <- lookupEnv "PENANCE_CABAL"
  envCabal2nix <- lookupEnv "PENANCE_CABAL2NIX"
  envNix <- lookupEnv "PENANCE_NIX"
  envIndexState <- fmap IndexState <$> lookupEnv "PENANCE_INDEX_STATE"
  envOut <- lookupEnv "PENANCE_LOCK_OUT"
  envHackageNixDir <- lookupEnv "PENANCE_HACKAGE_NIX_DIR"
  envPackageSet <- lookupEnv "PENANCE_PACKAGE_SET"
  envPackageSetOut <- lookupEnv "PENANCE_PACKAGE_SET_OUT"
  envStackage <- lookupEnv "PENANCE_STACKAGE"
  envJobs <- lookupEnv "PENANCE_JOBS"
  processorCount <- getNumProcessors
  jobs <- maybe (pure (max 1 processorCount)) parseJobs envJobs
  let initial =
        OptionState
          { stateProject = fromMaybe "." envProject
          , stateCompiler = envCompiler
          , stateGhcPkg = envGhcPkg
          , stateCabal = fromMaybe "cabal" envCabal
          , stateCabal2nix = fromMaybe "cabal2nix" envCabal2nix
          , stateNix = fromMaybe "nix" envNix
          , stateIndexState = envIndexState
          , statePlanJson = Nothing
          , stateOut = envOut
          , stateCheck = Nothing
          , stateHackageNixDir = envHackageNixDir
          , statePackageSet = envPackageSet
          , statePackageSetOut = envPackageSetOut
          , stateStackage = envStackage
          , stateJobs = jobs
          , stateRefreshHackageNix = False
          }
  go initial args >>= requireOptions
  where
    go state remainingArgs =
      case remainingArgs of
        [] -> pure state
        "--project" : value : rest -> go state {stateProject = value} rest
        "--compiler" : value : rest -> go state {stateCompiler = Just (CompilerId value)} rest
        "--ghc-pkg" : value : rest -> go state {stateGhcPkg = Just value} rest
        "--cabal" : value : rest -> go state {stateCabal = value} rest
        "--cabal2nix" : value : rest -> go state {stateCabal2nix = value} rest
        "--nix" : value : rest -> go state {stateNix = value} rest
        "--index-state" : value : rest -> go state {stateIndexState = Just (IndexState value)} rest
        "--plan-json" : value : rest -> go state {statePlanJson = Just value} rest
        "--out" : value : rest -> go state {stateOut = Just value} rest
        "--check" : value : rest -> go state {stateCheck = Just value} rest
        "--hackage-nix-dir" : value : rest -> go state {stateHackageNixDir = Just value} rest
        "--package-set" : value : rest ->
          go state {statePackageSet = Just value, statePackageSetOut = Nothing} rest
        "--package-set-out" : value : rest ->
          go state {statePackageSet = Nothing, statePackageSetOut = Just value} rest
        "--stackage" : value : rest -> go state {stateStackage = Just value} rest
        "--jobs" : value : rest -> do
          parsedJobs <- parseJobs value
          go state {stateJobs = parsedJobs} rest
        "--refresh" : rest -> go state {stateRefreshHackageNix = True} rest
        "-h" : _ -> usage >> exitSuccess
        "--help" : _ -> usage >> exitSuccess
        flag : _ -> die ("unknown option: " ++ flag)

    requireOptions state = do
      when (statePackageSet state /= Nothing && statePackageSetOut state /= Nothing) $
        die "repent: --package-set and --package-set-out are mutually exclusive"
      packageSet <- traverse (readPackageSet (stateNix state)) (statePackageSet state)
      packageSetBase <-
        case statePackageSetOut state of
          Just path -> do
            exists <- doesFileExist path
            if exists then Just <$> readPackageSet (stateNix state) path else pure Nothing
          Nothing -> pure Nothing
      let constraintSet =
            case packageSet of
              Just value -> Just value
              Nothing -> packageSetBase
      ghcPkg <-
        case stateGhcPkg state of
          Just path -> pure path
          Nothing -> findExecutable "ghc-pkg" >>= maybe (die "repent: cannot find ghc-pkg in PATH") pure
      compiler <- maybe (inferCompiler ghcPkg) pure (stateCompiler state)
      case constraintSet of
        Just value ->
          unless (packageSetCompiler value == compiler) $
            die
              ( "repent: package-set compiler mismatch: expected "
                  ++ renderCompilerId (packageSetCompiler value)
                  ++ ", got "
                  ++ renderCompilerId compiler
              )
        Nothing -> pure ()
      case (stateStackage state, constraintSet) of
        (Just requested, Just existing) ->
          unless (packageSetStackage existing == Just requested) $
            die "repent: --stackage does not match the existing package set"
        _ -> pure ()
      let project = stateProject state
          check = stateCheck state
          output =
            case stateOut state of
              Just path -> Just path
              Nothing
                | check == Nothing -> Just (project </> "penance.lock")
                | otherwise -> Nothing
          hackageNixDir =
            case stateHackageNixDir state of
              Just path -> Just path
              Nothing
                | statePackageSet state /= Nothing -> Nothing
              Nothing
                | Just packageSetOut <- statePackageSetOut state ->
                    Just (takeDirectory packageSetOut </> "nix" </> "penance-hackage")
              Nothing
                | stateOut state == Nothing && check == Nothing -> Just (project </> "nix" </> "penance-hackage")
                | otherwise -> Nothing
      indexState <-
        case stateIndexState state of
          Just value -> pure value
          Nothing -> maybe (readProjectIndexState project) (pure . packageSetIndexState) constraintSet
      pure
        Options
          { optProject = project
          , optCompiler = compiler
          , optGhcPkg = ghcPkg
          , optCabal = stateCabal state
          , optCabal2nix = stateCabal2nix state
          , optIndexState = indexState
          , optPlanJson = statePlanJson state
          , optOut = output
          , optCheck = check
          , optHackageNixDir = hackageNixDir
          , optPackageSet = packageSet
          , optPackageSetBase = packageSetBase
          , optPackageSetOut = statePackageSetOut state
          , optStackage = stateStackage state
          , optJobs = stateJobs state
          , optRefreshHackageNix = stateRefreshHackageNix state
          }

usage :: IO ()
usage =
  putStrLn $
    unlines
      [ "usage: repent [--project DIR] [--compiler GHC] [--ghc-pkg FILE] [--cabal FILE] [--cabal2nix FILE] [--nix FILE] [--index-state TS] [--plan-json FILE] [--out FILE] [--check FILE] [--hackage-nix-dir DIR] [--package-set FILE | --package-set-out FILE] [--stackage RESOLVER] [--jobs N] [--refresh]"
      , ""
      , "Generate a deterministic unit lock from Cabal's elaborated plan.json."
      , "By default repent runs cabal build --dry-run; --plan-json consumes an existing plan."
      , "With no arguments, repent writes penance.lock and committed Hackage expressions in nix/penance-hackage."
      , "--package-set constrains and validates the solve against a shared package set."
      , "--package-set-out creates or extends a Nix package set from the solved external units and records its hash in the project lock."
      , "--jobs bounds concurrent cabal2nix processes; PENANCE_JOBS and the processor count provide its defaults."
      , "--refresh regenerates Hackage expressions that are already present."
      , "--check compares the generated bytes with an existing lock file."
      ]

inferCompiler :: FilePath -> IO CompilerId
inferCompiler ghcPkg = do
  let ghc = takeDirectory ghcPkg </> "ghc"
  (status, stdout, stderr) <- readProcessWithExitCode ghc ["--numeric-version"] ""
  case status of
    ExitSuccess -> pure (CompilerId ("ghc-" ++ trim stdout))
    ExitFailure code ->
      die . unlines $
        [ "repent: could not infer the compiler from " ++ ghc
        , "ghc exited with " ++ show code
        , stderr
        ]

writeHackageExpressions :: Options -> FilePath -> [ExternalUnit] -> Bool -> IO ()
writeHackageExpressions opts directory externalUnits prune = do
  createDirectoryIfMissing True directory
  let hackageUnits =
        uniqueBy externalUnitExpressionName
          [ unit
          | unit <- externalUnits
          , HackageSdist {} <- [externalUnitSource unit]
          ]
      expressionName = externalUnitExpressionName
      expected = map expressionName hackageUnits
  hackageUnitsToRefresh <-
    if optRefreshHackageNix opts
      then pure hackageUnits
      else filterM (fmap not . doesFileExist . (directory </>) . expressionName) hackageUnits
  if null hackageUnitsToRefresh
    then putStrLn ("repent: Hackage expressions are current in " ++ directory)
    else do
      let jobs = min (optJobs opts) (length hackageUnitsToRefresh)
      putStrLn $
        "repent: refreshing "
          ++ show (length hackageUnitsToRefresh)
          ++ " Hackage expressions in "
          ++ directory
          ++ " with "
          ++ show jobs
          ++ " jobs"
      semaphore <- newQSem jobs
      mapConcurrently_
        (withSemaphore semaphore . writeExpression expressionName)
        hackageUnitsToRefresh
  when prune $ do
    entries <- listDirectory directory
    forM_ entries $ \entry ->
      when (takeExtension entry == ".nix" && entry `notElem` expected) $
        removeFile (directory </> entry)
  where
    writeExpression expressionName unit = do
      let packageId =
            prettyShow (externalUnitName unit)
              ++ "-"
              ++ prettyShow (externalUnitVersion unit)
          expression = directory </> expressionName unit
          temporary = expression ++ ".tmp"
      putStrLn ("repent: cabal2nix " ++ packageId)
      (status, stdout, stderr) <-
        readProcessWithExitCode
          (optCabal2nix opts)
          (concatMap renderFlag (renderFlagAssignment (externalUnitFlags unit)) ++ ["cabal://" ++ packageId])
          ""
      case status of
        ExitSuccess ->
          (writeUtf8File temporary (hackageExpressionHeader ++ stdout) >> renameFile temporary expression)
            `onException` removeIfExists temporary
        ExitFailure code ->
          die . unlines $
            [ "repent: cabal2nix failed for " ++ packageId ++ " (exit " ++ show code ++ ")"
            , stderr
            ]
    renderFlag (name, enabled) = ["--flag", if enabled then name else '-' : name]

withSemaphore :: QSem -> IO a -> IO a
withSemaphore semaphore = bracket_ (waitQSem semaphore) (signalQSem semaphore)

uniqueBy :: Ord key => (value -> key) -> [value] -> [value]
uniqueBy key = go Set.empty
  where
    go _ [] = []
    go seen (value : rest)
      | Set.member valueKey seen = go seen rest
      | otherwise = value : go (Set.insert valueKey seen) rest
      where
        valueKey = key value

parseJobs :: String -> IO Int
parseJobs value =
  case readMaybe value of
    Just jobs
      | jobs > 0 -> pure jobs
    _ -> die "repent: --jobs/PENANCE_JOBS must be a positive integer"

hackageExpressionHeader :: String
hackageExpressionHeader =
  unlines
    [ "# Generated by repent 0.1.0.0. DO NOT EDIT."
    , "# Regenerate together with penance.lock so Cabal metadata and sdist hashes stay reviewable."
    ]

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  exists <- doesFileExist path
  when exists (removeFile path)

readPackageSet :: FilePath -> FilePath -> IO PackageSet
readPackageSet nix path = do
  (status, stdout, stderr) <- readProcessWithExitCode nix ["eval", "--json", "--file", path] ""
  case status of
    ExitSuccess ->
      either (die . (("repent: invalid package set " ++ path ++ ": ") ++)) pure (decodePackageSet stdout)
    ExitFailure code ->
      die . unlines $
        [ "repent: could not evaluate Nix package set " ++ path ++ " (exit " ++ show code ++ ")"
        , stderr
        ]

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace
