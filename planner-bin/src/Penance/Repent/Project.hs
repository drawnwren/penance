module Penance.Repent.Project
  ( PackageLock (..)
  , LockComponentName (..)
  , LockComponent (..)
  , readProjectPackages
  , readProjectIndexState
  , readProjectConstraints
  , matchGlob
  )
where

import Control.Monad (forM)
import qualified Data.ByteString as BS
import Data.List (nub, sort, sortOn)
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
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
  , pkgName
  )
import Distribution.PackageDescription.Configuration (flattenPackageDescription)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription)
import Distribution.Pretty (prettyShow)
import Distribution.Types.LibraryName (LibraryName (..))
import Penance.CabalProject (CabalProject (..), parseCabalProject)
import Penance.Error (throwCabalParseError, throwPlanError)
import Penance.ModulePlan (hasAnnPragma, languagePragmas, needsDbFullFor)
import Penance.Types (ComponentKind (..), IndexState (..))
import Penance.Utf8.IO (readUtf8File)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.FilePath
  ( (</>)
  , normalise
  , splitDirectories
  , takeDirectory
  , takeExtension
  , takeFileName
  )

data PackageLock = PackageLock
  { lockPackagePath :: FilePath
  , lockCabalFile :: FilePath
  , lockDescription :: PackageDescription
  , lockComponents :: [LockComponent]
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
  , lockComponentNeedsFullDb :: Bool
  }

readProjectPackages :: FilePath -> IO [PackageLock]
readProjectPackages projectRoot = do
  projectText <- readUtf8File (projectRoot </> "cabal.project")
  project <- either (throwCabalParseError . ("repent: " ++)) pure (parseCabalProject projectText)
  required <- concat <$> traverse (expandProjectPackage projectRoot False) (defaultPackages project)
  optional <- concat <$> traverse (expandProjectPackage projectRoot True) (projectOptionalPackages project)
  let packagePaths = sort (Set.toAscList (Set.fromList (required ++ optional)))
  locks <- forM packagePaths $ \packagePath -> do
    cabalFile <- findCabalFile projectRoot packagePath
    cabalBytes <- BS.readFile cabalFile
    generic <-
      case runParseResult (parseGenericPackageDescription cabalBytes) of
        (_warnings, Right value) -> pure value
        (_warnings, Left err) ->
          throwCabalParseError ("repent: failed to parse " ++ cabalFile ++ ": " ++ show err)
    let packageDescription = flattenPackageDescription generic
        packageRoot = if packagePath == "." then projectRoot else projectRoot </> packagePath
    components <- traverse (classifyLockComponent packageRoot) (componentsFromDescription packageDescription)
    pure
      PackageLock
        { lockPackagePath = packagePath
        , lockCabalFile = makeRelativeProject packagePath cabalFile
        , lockDescription = packageDescription
        , lockComponents = components
        }
  pure (sortOnPackage locks)

readProjectIndexState :: FilePath -> IO IndexState
readProjectIndexState projectRoot = do
  let path = projectRoot </> "cabal.project"
  contents <- readUtf8File path
  project <- either (throwCabalParseError . ("repent: " ++)) pure (parseCabalProject contents)
  case projectIndexState project of
    Just value -> pure (IndexState value)
    Nothing ->
      throwPlanError
        ( "repent: no index-state was provided; add `index-state:` to "
            ++ path
            ++ " or set PENANCE_INDEX_STATE"
        )

readProjectConstraints :: FilePath -> IO [String]
readProjectConstraints projectRoot = do
  contents <- readUtf8File (projectRoot </> "cabal.project")
  project <- either (throwCabalParseError . ("repent: " ++)) pure (parseCabalProject contents)
  pure (projectConstraints project)

defaultPackages :: CabalProject -> [FilePath]
defaultPackages project =
  case projectPackages project of
    [] -> ["."]
    packages -> packages

expandProjectPackage :: FilePath -> Bool -> FilePath -> IO [FilePath]
expandProjectPackage projectRoot optional patternText = do
  matches <- expandPattern projectRoot (splitDirectories (normalise patternText))
  let packagePaths = Set.toAscList . Set.fromList $ map packagePath matches
  if null packagePaths && not optional
    then throwPlanError ("repent: cabal.project package pattern matched nothing: " ++ patternText)
    else pure packagePaths
  where
    packagePath path
      | takeExtension path == ".cabal" = normalizeRelative (takeDirectory path)
      | otherwise = normalizeRelative path

expandPattern :: FilePath -> [FilePath] -> IO [FilePath]
expandPattern projectRoot = go projectRoot ""
  where
    go _ relative [] = pure [normalizeRelative relative]
    go directory relative (segment : remaining)
      | segment == "." = go directory relative remaining
      | segment == "**" = do
          here <- go directory relative remaining
          entries <- sortedDirectoryEntries directory
          below <- fmap concat . forM entries $ \entry -> do
            let absolute = directory </> entry
                child = appendRelative relative entry
            isDirectory <- doesDirectoryExist absolute
            if isDirectory then go absolute child (segment : remaining) else pure []
          pure (here ++ below)
      | hasGlob segment = do
          entries <- sortedDirectoryEntries directory
          fmap concat . forM (filter (matchGlob segment) entries) $ \entry ->
            descend directory relative entry remaining
      | otherwise = descend directory relative segment remaining

    descend directory relative entry remaining = do
      let absolute = directory </> entry
          child = appendRelative relative entry
      existsFile <- doesFileExist absolute
      existsDirectory <- doesDirectoryExist absolute
      case remaining of
        [] | existsFile || existsDirectory -> pure [child]
        _ | existsDirectory -> go absolute child remaining
        _ -> pure []

sortedDirectoryEntries :: FilePath -> IO [FilePath]
sortedDirectoryEntries directory = do
  exists <- doesDirectoryExist directory
  if exists then sort <$> listDirectory directory else pure []

appendRelative :: FilePath -> FilePath -> FilePath
appendRelative "" entry = entry
appendRelative relative entry = relative </> entry

normalizeRelative :: FilePath -> FilePath
normalizeRelative value =
  case normalise value of
    "" -> "."
    normalized -> normalized

hasGlob :: String -> Bool
hasGlob = any (`elem` ("*?" :: String))

matchGlob :: String -> String -> Bool
matchGlob patternText value =
  case patternText of
    [] -> null value
    '*' : patternRest ->
      matchGlob patternRest value
        || case value of
          _ : valueRest -> matchGlob patternText valueRest
          [] -> False
    '?' : patternRest ->
      case value of
        _ : valueRest -> matchGlob patternRest valueRest
        [] -> False
    patternChar : patternRest ->
      case value of
        valueChar : valueRest -> patternChar == valueChar && matchGlob patternRest valueRest
        [] -> False

findCabalFile :: FilePath -> FilePath -> IO FilePath
findCabalFile projectRoot packagePath = do
  let dir = if packagePath == "." then projectRoot else projectRoot </> packagePath
  entries <- listDirectory dir
  let cabalFiles = sort [entry | entry <- entries, takeExtension entry == ".cabal"]
  case cabalFiles of
    [name] -> pure (dir </> name)
    [] -> throwPlanError ("repent: no .cabal file found in " ++ dir)
    _ -> throwPlanError ("repent: multiple .cabal files found in " ++ dir)

makeRelativeProject :: FilePath -> FilePath -> FilePath
makeRelativeProject packagePath cabalFile =
  if packagePath == "."
    then takeFileName cabalFile
    else packagePath </> takeFileName cabalFile

componentsFromDescription :: PackageDescription -> [LockComponent]
componentsFromDescription desc =
  maybe [] (\lib -> [libraryComponent (LockComponentName "lib") lib]) (library desc)
    ++ map subLibraryComponent (subLibraries desc)
    ++ map executableComponent (executables desc)
    ++ map testSuiteComponent (testSuites desc)
    ++ map benchmarkComponent (benchmarks desc)

libraryComponent :: LockComponentName -> Library -> LockComponent
libraryComponent name lib =
  let buildInfo' = libBuildInfo lib
   in LockComponent
        { lockComponentName = name
        , lockComponentKind = LibraryKind
        , lockComponentBuildInfo = buildInfo'
        , lockComponentModules = map prettyShow (exposedModules lib ++ otherModules buildInfo')
        , lockComponentSignatures = map prettyShow (signatures lib)
        , lockComponentMain = Nothing
        , lockComponentNeedsFullDb = False
        }

subLibraryComponent :: Library -> LockComponent
subLibraryComponent lib = libraryComponent (libraryComponentName (libName lib)) lib

executableComponent :: Executable -> LockComponent
executableComponent exe =
  let buildInfo' = buildInfo exe
   in LockComponent
        { lockComponentName = LockComponentName ("exe:" ++ prettyShow (exeName exe))
        , lockComponentKind = ExecutableKind
        , lockComponentBuildInfo = buildInfo'
        , lockComponentModules = modulePath exe : map prettyShow (otherModules buildInfo')
        , lockComponentSignatures = []
        , lockComponentMain = Just (modulePath exe)
        , lockComponentNeedsFullDb = False
        }

testSuiteComponent :: TestSuite -> LockComponent
testSuiteComponent test =
  let buildInfo' = testBuildInfo test
      mainPath = testSuiteMainPath test
   in LockComponent
        { lockComponentName = LockComponentName ("test:" ++ prettyShow (testName test))
        , lockComponentKind = TestSuiteKind
        , lockComponentBuildInfo = buildInfo'
        , lockComponentModules = maybe [] (: []) mainPath ++ map prettyShow (otherModules buildInfo')
        , lockComponentSignatures = []
        , lockComponentMain = mainPath
        , lockComponentNeedsFullDb = False
        }

benchmarkComponent :: Benchmark -> LockComponent
benchmarkComponent bench =
  let buildInfo' = benchmarkBuildInfo bench
      mainPath = benchmarkMainPath bench
   in LockComponent
        { lockComponentName = LockComponentName ("bench:" ++ prettyShow (benchmarkName bench))
        , lockComponentKind = BenchmarkKind
        , lockComponentBuildInfo = buildInfo'
        , lockComponentModules = maybe [] (: []) mainPath ++ map prettyShow (otherModules buildInfo')
        , lockComponentSignatures = []
        , lockComponentMain = mainPath
        , lockComponentNeedsFullDb = False
        }

libraryComponentName :: LibraryName -> LockComponentName
libraryComponentName libraryName =
  case libraryName of
    LMainLibName -> LockComponentName "lib"
    LSubLibName name -> LockComponentName ("lib:" ++ prettyShow name)

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
moduleNameToPath = map (\ch -> if ch == '.' then '/' else ch) . (++ ".hs")

classifyLockComponent :: FilePath -> LockComponent -> IO LockComponent
classifyLockComponent packageRoot component = do
  sourceTexts <- catMaybes <$> traverse readFirstExisting (componentSourceCandidates packageRoot component)
  let extensions = map prettyShow (defaultExtensions (lockComponentBuildInfo component))
      sourceNeedsFullDb source = needsDbFullFor (languagePragmas source) (hasAnnPragma source)
  pure
    component
      { lockComponentNeedsFullDb =
          needsDbFullFor extensions False || any sourceNeedsFullDb sourceTexts
      }

componentSourceCandidates :: FilePath -> LockComponent -> [[FilePath]]
componentSourceCandidates packageRoot component =
  [ [packageRoot </> sourceDir </> relative | relative <- sourceVariants source]
  | source <- nub (lockComponentModules component ++ maybe [] (: []) (lockComponentMain component))
  , sourceDir <- sourceDirs
  ]
  where
    configuredSourceDirs = map prettyShow (hsSourceDirs (lockComponentBuildInfo component))
    sourceDirs = if null configuredSourceDirs then ["."] else configuredSourceDirs

sourceVariants :: FilePath -> [FilePath]
sourceVariants source
  | takeExtension source `elem` [".hs", ".lhs", ".hsig"] = [source]
  | otherwise =
      let moduleSource = map (\ch -> if ch == '.' then '/' else ch) source
       in map (moduleSource ++) [".hs", ".lhs", ".hsig"]

readFirstExisting :: [FilePath] -> IO (Maybe String)
readFirstExisting candidates = do
  existing <- traverse (\path -> do exists <- doesFileExist path; pure (path, exists)) candidates
  case [path | (path, True) <- existing] of
    path : _ -> Just <$> readUtf8File path
    [] -> pure Nothing

sortOnPackage :: [PackageLock] -> [PackageLock]
sortOnPackage = sortOn (prettyShow . pkgName . package . lockDescription)
