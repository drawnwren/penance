module Main (main) where

import Control.Exception (onException)
import Control.Monad (forM, forM_, unless, when)
import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (dropWhileEnd, isPrefixOf, nub, sort, sortOn, stripPrefix)
import Data.Maybe (fromMaybe)
import Distribution.Fields.ParseResult (runParseResult)
import Distribution.PackageDescription
  ( Benchmark (..)
  , BenchmarkInterface (..)
  , BuildInfo (..)
  , Executable (..)
  , Library (..)
  , PackageDescription (..)
  , TestSuite (..)
  , TestSuiteInterface (..)
  , buildType
  , pkgName
  , pkgVersion
  )
import Distribution.PackageDescription.Configuration (flattenPackageDescription)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription)
import Distribution.Pretty (prettyShow)
import Distribution.Types.LibraryName (LibraryName (..))
import Penance.CabalPlan
  ( CabalPlanRequest (..)
  , ExternalSource (..)
  , ExternalUnit (..)
  , HackageUrl (..)
  , SdistHash (..)
  )
import qualified Penance.CabalPlan as CabalPlan
import Penance.Json (Json)
import qualified Penance.Json as Json
import Penance.Types
  ( CompilerId (..)
  , ComponentKind (..)
  , IndexState (..)
  , PenanceSchema (..)
  , ProjectPathBase (..)
  , renderComponentKind
  , renderPenanceSchema
  , renderProjectPathBase
  )
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
import System.FilePath ((</>), takeDirectory, takeExtension, takeFileName)
import System.Process (readProcessWithExitCode)

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
  }
  deriving (Eq, Show)

data OptionState = OptionState
  { stateProject :: FilePath
  , stateCompiler :: Maybe CompilerId
  , stateGhcPkg :: Maybe FilePath
  , stateCabal :: FilePath
  , stateCabal2nix :: FilePath
  , stateIndexState :: Maybe IndexState
  , statePlanJson :: Maybe FilePath
  , stateOut :: Maybe FilePath
  , stateCheck :: Maybe FilePath
  , stateHackageNixDir :: Maybe FilePath
  }
  deriving (Eq, Show)

data PackageLock = PackageLock
  { lockPackagePath :: FilePath
  , lockCabalFile :: FilePath
  , lockDescription :: PackageDescription
  }

newtype LockComponentName = LockComponentName {renderLockComponentName :: String}
  deriving (Eq, Ord, Show)

data LockComponent = LockComponent
  { lockComponentName :: LockComponentName
  , lockComponentKind :: ComponentKind
  , lockComponentBuildInfo :: BuildInfo
  , lockComponentModules :: [String]
  , lockComponentSignatures :: [String]
  , lockComponentMain :: Maybe FilePath
  }

main :: IO ()
main = do
  opts <- parseOptions =<< getArgs
  packages <- readProjectPackages opts
  externalUnits <-
    CabalPlan.resolveExternalUnits
      CabalPlanRequest
        { planProject = optProject opts
        , planCompiler = optCompiler opts
        , planGhcPkg = optGhcPkg opts
        , planCabal = optCabal opts
        , planIndexState = optIndexState opts
        , planInput = optPlanJson opts
        }
      >>= either die pure
  let rendered = Json.renderJson (lockJson opts packages externalUnits) ++ "\n"
  case optCheck opts of
    Just path -> do
      expected <- readFile path
      unless (expected == rendered) $ do
        putStrLn ("repent: lock is stale: " ++ path)
        putStrLn "expected checked-in lock to match generated lock"
        exitFailure
    Nothing ->
      pure ()
  case optHackageNixDir opts of
    Just directory -> writeHackageExpressions opts directory externalUnits
    Nothing -> pure ()
  case optOut opts of
    Just path -> do
      writeFile path rendered
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
  envIndexState <- fmap IndexState <$> lookupEnv "PENANCE_INDEX_STATE"
  envOut <- lookupEnv "PENANCE_LOCK_OUT"
  envHackageNixDir <- lookupEnv "PENANCE_HACKAGE_NIX_DIR"
  let initial =
        OptionState
          { stateProject = fromMaybe "." envProject
          , stateCompiler = envCompiler
          , stateGhcPkg = envGhcPkg
          , stateCabal = fromMaybe "cabal" envCabal
          , stateCabal2nix = fromMaybe "cabal2nix" envCabal2nix
          , stateIndexState = envIndexState
          , statePlanJson = Nothing
          , stateOut = envOut
          , stateCheck = Nothing
          , stateHackageNixDir = envHackageNixDir
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
        "--index-state" : value : rest -> go state {stateIndexState = Just (IndexState value)} rest
        "--plan-json" : value : rest -> go state {statePlanJson = Just value} rest
        "--out" : value : rest -> go state {stateOut = Just value} rest
        "--check" : value : rest -> go state {stateCheck = Just value} rest
        "--hackage-nix-dir" : value : rest -> go state {stateHackageNixDir = Just value} rest
        "-h" : _ -> usage >> exitSuccess
        "--help" : _ -> usage >> exitSuccess
        flag : _ -> die ("unknown option: " ++ flag)

    requireOptions state = do
      ghcPkg <-
        case stateGhcPkg state of
          Just path -> pure path
          Nothing -> findExecutable "ghc-pkg" >>= maybe (die "repent: cannot find ghc-pkg in PATH") pure
      compiler <- maybe (inferCompiler ghcPkg) pure (stateCompiler state)
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
                | stateOut state == Nothing && check == Nothing -> Just (project </> "nix" </> "penance-hackage")
                | otherwise -> Nothing
      pure
        Options
          { optProject = project
          , optCompiler = compiler
          , optGhcPkg = ghcPkg
          , optCabal = stateCabal state
          , optCabal2nix = stateCabal2nix state
          , optIndexState = fromMaybe (IndexState "2026-02-01T00:00:00Z") (stateIndexState state)
          , optPlanJson = statePlanJson state
          , optOut = output
          , optCheck = check
          , optHackageNixDir = hackageNixDir
          }

usage :: IO ()
usage =
  putStrLn $
    unlines
      [ "usage: repent [--project DIR] [--compiler GHC] [--ghc-pkg FILE] [--cabal FILE] [--cabal2nix FILE] [--index-state TS] [--plan-json FILE] [--out FILE] [--check FILE] [--hackage-nix-dir DIR]"
      , ""
      , "Generate a deterministic unit lock from Cabal's elaborated plan.json."
      , "By default repent runs cabal build --dry-run; --plan-json consumes an existing plan."
      , "With no arguments, repent writes penance.lock and committed Hackage expressions in nix/penance-hackage."
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

writeHackageExpressions :: Options -> FilePath -> [ExternalUnit] -> IO ()
writeHackageExpressions opts directory externalUnits = do
  createDirectoryIfMissing True directory
  let hackageUnits =
        [ unit
        | unit <- externalUnits
        , HackageSdist {} <- [externalUnitSource unit]
        ]
      expressionName unit =
        prettyShow (externalUnitName unit)
          ++ "-"
          ++ prettyShow (externalUnitVersion unit)
          ++ ".nix"
      expected = map expressionName hackageUnits
  putStrLn $
    "repent: refreshing "
      ++ show (length hackageUnits)
      ++ " Hackage expressions in "
      ++ directory
  forM_ hackageUnits $ \unit -> do
    let packageId =
          prettyShow (externalUnitName unit)
            ++ "-"
            ++ prettyShow (externalUnitVersion unit)
        expression = directory </> expressionName unit
        temporary = expression ++ ".tmp"
    putStrLn ("repent: cabal2nix " ++ packageId)
    (status, stdout, stderr) <-
      readProcessWithExitCode (optCabal2nix opts) ["cabal://" ++ packageId] ""
    case status of
      ExitSuccess ->
        (writeFile temporary stdout >> renameFile temporary expression)
          `onException` removeIfExists temporary
      ExitFailure code ->
        die . unlines $
          [ "repent: cabal2nix failed for " ++ packageId ++ " (exit " ++ show code ++ ")"
          , stderr
          ]
  entries <- listDirectory directory
  forM_ entries $ \entry ->
    when (takeExtension entry == ".nix" && entry `notElem` expected) $
      removeFile (directory </> entry)

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  exists <- doesFileExist path
  when exists (removeFile path)

readProjectPackages :: Options -> IO [PackageLock]
readProjectPackages opts = do
  projectText <- readFile (optProject opts </> "cabal.project")
  let packagePaths = simpleProjectPackages projectText
  locks <- forM packagePaths $ \packagePath -> do
    cabalFile <- findCabalFile (optProject opts) packagePath
    cabalBytes <- BS.readFile cabalFile
    generic <-
      case runParseResult (parseGenericPackageDescription cabalBytes) of
        (_warnings, Right value) -> pure value
        (_warnings, Left err) -> die ("repent: failed to parse " ++ cabalFile ++ ": " ++ show err)
    pure
      PackageLock
        { lockPackagePath = packagePath
        , lockCabalFile = makeRelativeProject packagePath cabalFile
        , lockDescription = flattenPackageDescription generic
        }
  pure (sortOnPackage locks)

findCabalFile :: FilePath -> FilePath -> IO FilePath
findCabalFile projectRoot packagePath = do
  let dir = if packagePath == "." then projectRoot else projectRoot </> packagePath
  entries <- listDirectory dir
  let cabalFiles = sort [entry | entry <- entries, takeExtension entry == ".cabal"]
  case cabalFiles of
    [name] -> pure (dir </> name)
    [] -> die ("repent: no .cabal file found in " ++ dir)
    _ -> die ("repent: multiple .cabal files found in " ++ dir)

makeRelativeProject :: FilePath -> FilePath -> FilePath
makeRelativeProject packagePath cabalFile =
  if packagePath == "."
    then takeFileName cabalFile
    else packagePath </> takeFileName cabalFile

simpleProjectPackages :: String -> [FilePath]
simpleProjectPackages text =
  case collectProjectFieldPackages "packages" (projectLineRecords text) of
    [] -> ["."]
    paths -> sort (nub paths)

projectLineRecords :: String -> [(String, Bool)]
projectLineRecords text =
  [ (trim (stripComment line), isIndented (stripComment line))
  | line <- lines text
  , trim (stripComment line) /= ""
  ]

collectProjectFieldPackages :: String -> [(String, Bool)] -> [FilePath]
collectProjectFieldPackages field records =
  case records of
    [] -> []
    (line, indented) : rest
      | not indented && (field ++ ":") `isPrefixOf` line ->
          let inline = trim (drop (length field + 1) line)
              (continuation, remaining) = span snd rest
              value = unlines (inline : map fst continuation)
           in splitProjectPackageWords value ++ collectProjectFieldPackages field remaining
      | otherwise -> collectProjectFieldPackages field rest

splitProjectPackageWords :: String -> [FilePath]
splitProjectPackageWords value =
  filter (/= "") $
    map (trim . removeSuffix ",") $
      words (map (\ch -> if ch == '\t' || ch == '\n' then ' ' else ch) value)

lockJson :: Options -> [PackageLock] -> [ExternalUnit] -> Json
lockJson opts packages externalUnits =
  Json.object
    [ ("schema", Json.string (renderPenanceSchema LockSchemaV1))
    , ("compiler", Json.string (renderCompilerId (optCompiler opts)))
    , ("indexState", Json.string (renderIndexState (optIndexState opts)))
    , ( "project"
      , Json.object
          [ ("root", Json.string ".")
          , ("pathBase", Json.string (renderProjectPathBase ProjectRootPathBase))
          , ("cabalProject", Json.string "cabal.project")
          , ("packages", Json.array (map (Json.string . lockPackagePath) packages))
          ]
      )
    , ("packages", Json.array (map packageJson packages))
    , ("externalUnits", Json.array (map externalUnitJson externalUnits))
    ]

packageJson :: PackageLock -> Json
packageJson packageLock =
  let desc = lockDescription packageLock
   in Json.object
        [ ("name", Json.string (prettyShow (pkgName (package desc))))
        , ("version", Json.string (prettyShow (pkgVersion (package desc))))
        , ("path", Json.string (lockPackagePath packageLock))
        , ("cabalFile", Json.string (lockCabalFile packageLock))
        , ("setupType", Json.string (prettyShow (buildType desc)))
        , ("components", Json.array (componentsJson desc))
        ]

componentsJson :: PackageDescription -> [Json]
componentsJson = map componentJson . sortOn lockComponentName . lockComponents

lockComponents :: PackageDescription -> [LockComponent]
lockComponents desc =
  maybe [] (\lib -> [libraryComponent (LockComponentName "lib") lib]) (library desc)
    ++ map subLibraryComponent (subLibraries desc)
    ++ map executableComponent (executables desc)
    ++ map testSuiteComponent (testSuites desc)
    ++ map benchmarkComponent (benchmarks desc)

libraryComponent :: LockComponentName -> Library -> LockComponent
libraryComponent name lib =
  LockComponent
    { lockComponentName = name
    , lockComponentKind = LibraryKind
    , lockComponentBuildInfo = libBuildInfo lib
    , lockComponentModules = map prettyShow (exposedModules lib)
    , lockComponentSignatures = map prettyShow (signatures lib)
    , lockComponentMain = Nothing
    }

subLibraryComponent :: Library -> LockComponent
subLibraryComponent lib =
  libraryComponent (libraryComponentName (libName lib)) lib

executableComponent :: Executable -> LockComponent
executableComponent exe =
  LockComponent
    { lockComponentName = LockComponentName ("exe:" ++ prettyShow (exeName exe))
    , lockComponentKind = ExecutableKind
    , lockComponentBuildInfo = buildInfo exe
    , lockComponentModules = [modulePath exe]
    , lockComponentSignatures = []
    , lockComponentMain = Just (modulePath exe)
    }

testSuiteComponent :: TestSuite -> LockComponent
testSuiteComponent test =
  LockComponent
    { lockComponentName = LockComponentName ("test:" ++ prettyShow (testName test))
    , lockComponentKind = TestSuiteKind
    , lockComponentBuildInfo = testBuildInfo test
    , lockComponentModules = maybe [] (: []) mainPath
    , lockComponentSignatures = []
    , lockComponentMain = mainPath
    }
  where
    mainPath = testSuiteMainPath test

benchmarkComponent :: Benchmark -> LockComponent
benchmarkComponent bench =
  LockComponent
    { lockComponentName = LockComponentName ("bench:" ++ prettyShow (benchmarkName bench))
    , lockComponentKind = BenchmarkKind
    , lockComponentBuildInfo = benchmarkBuildInfo bench
    , lockComponentModules = maybe [] (: []) mainPath
    , lockComponentSignatures = []
    , lockComponentMain = mainPath
    }
  where
    mainPath = benchmarkMainPath bench

libraryComponentName :: LibraryName -> LockComponentName
libraryComponentName libraryName =
  case libraryName of
    LMainLibName -> LockComponentName "lib"
    LSubLibName name -> LockComponentName ("lib:" ++ prettyShow name)

componentJson :: LockComponent -> Json
componentJson component =
  Json.object
    [ ("name", Json.string (renderLockComponentName (lockComponentName component)))
    , ("kind", Json.string (renderComponentKind (lockComponentKind component)))
    , ("sourceDirs", stringArray (sort (map prettyShow (hsSourceDirs buildInfo'))))
    , ("modules", stringArray (sort (lockComponentModules component)))
    , ("main", maybe Json.JsonNull Json.string (lockComponentMain component))
    , ("signatures", stringArray (sort (lockComponentSignatures component)))
    , ("dependencies", stringArray (sort (map prettyShow (targetBuildDepends buildInfo'))))
    , ("defaultExtensions", stringArray (sort (map prettyShow (defaultExtensions buildInfo'))))
    ]
  where
    buildInfo' = lockComponentBuildInfo component

testSuiteMainPath :: TestSuite -> Maybe FilePath
testSuiteMainPath test =
  case testInterface test of
    TestSuiteExeV10 _ path -> Just path
    TestSuiteLibV09 _ moduleName -> Just (moduleNameToPath (prettyShow moduleName))
    TestSuiteUnsupported _ -> Nothing

benchmarkMainPath :: Benchmark -> Maybe FilePath
benchmarkMainPath bench =
  case benchmarkInterface bench of
    BenchmarkExeV10 _ path -> Just path
    BenchmarkUnsupported _ -> Nothing

moduleNameToPath :: String -> FilePath
moduleNameToPath =
  map (\ch -> if ch == '.' then '/' else ch) . (++ ".hs")

externalUnitJson :: ExternalUnit -> Json
externalUnitJson unit =
  Json.object $
    [ ("name", Json.string (prettyShow (externalUnitName unit)))
    , ("version", Json.string (prettyShow (externalUnitVersion unit)))
    ]
      ++ case externalUnitSource unit of
        GhcBoot ->
          [("source", Json.string "ghc-boot")]
        HackageSdist url sha256 ->
          [ ("source", Json.string "hackage")
          , ( "sdist"
            , Json.object
                [ ("url", Json.string (renderHackageUrl url))
                , ("sha256", Json.string (renderSdistHash sha256))
                ]
            )
          ]

sortOnPackage :: [PackageLock] -> [PackageLock]
sortOnPackage =
  sortOn (prettyShow . pkgName . package . lockDescription)

stringArray :: [String] -> Json
stringArray = Json.array . map Json.string

stripComment :: String -> String
stripComment = stripDoubleDash

stripDoubleDash :: String -> String
stripDoubleDash input =
  case input of
    '-' : '-' : _ -> ""
    ch : rest -> ch : stripDoubleDash rest
    "" -> ""

isIndented :: String -> Bool
isIndented (ch : _) = ch == ' ' || ch == '\t'
isIndented "" = False

trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace

removeSuffix :: Eq a => [a] -> [a] -> [a]
removeSuffix suffix value =
  fromMaybe value (stripSuffix suffix value)

stripSuffix :: Eq a => [a] -> [a] -> Maybe [a]
stripSuffix suffix value =
  fmap reverse (stripPrefix (reverse suffix) (reverse value))
