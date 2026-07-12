module Penance.CabalPlan
  ( CabalPlanRequest (..)
  , ExternalSource (..)
  , ExternalUnit (..)
  , HackageUrl (..)
  , SdistHash (..)
  , resolveExternalUnits
  ) where

import Control.Exception (bracket)
import Control.Monad (foldM, unless)
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.Char (digitToInt, isHexDigit)
import Data.List (find, isInfixOf, nub, sortOn)
import Distribution.Parsec (Parsec, simpleParsec)
import Distribution.Pretty (prettyShow)
import Distribution.Types.PackageName (PackageName)
import Distribution.Version (Version)
import Penance.Json (Json (..), parseJson)
import Penance.Types (CompilerId, IndexState, renderCompilerId, renderIndexState)
import System.Directory
  ( canonicalizePath
  , createDirectory
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>), takeDirectory)
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)

data CabalPlanRequest = CabalPlanRequest
  { planProject :: FilePath
  , planCompiler :: CompilerId
  , planGhcPkg :: FilePath
  , planCabal :: FilePath
  , planIndexState :: IndexState
  , planInput :: Maybe FilePath
  }
  deriving (Eq, Show)

data ExternalUnit = ExternalUnit
  { externalUnitName :: PackageName
  , externalUnitVersion :: Version
  , externalUnitSource :: ExternalSource
  }
  deriving (Eq, Show)

data ExternalSource
  = GhcBoot
  | HackageSdist
      { hackageSdistUrl :: HackageUrl
      , hackageSdistSha256 :: SdistHash
      }
  deriving (Eq, Show)

newtype HackageUrl = HackageUrl {renderHackageUrl :: String}
  deriving (Eq, Ord, Show)

newtype SdistHash = SdistHash {renderSdistHash :: String}
  deriving (Eq, Ord, Show)

newtype PlanUnitId = PlanUnitId {renderPlanUnitId :: String}
  deriving (Eq, Ord, Show)

newtype RepositoryUri = RepositoryUri {renderRepositoryUri :: String}
  deriving (Eq, Ord, Show)

newtype HexSha256 = HexSha256 {renderHexSha256 :: String}
  deriving (Eq, Ord, Show)

data PlanUnitOrigin
  = LocalPlanUnit
  | HackagePlanUnit RepositoryUri HexSha256
  | PreExistingPlanUnit
  deriving (Eq, Show)

data PlanUnit = PlanUnit
  { unitId :: PlanUnitId
  , unitPackageName :: PackageName
  , unitPackageVersion :: Version
  , unitOrigin :: PlanUnitOrigin
  , unitDependencies :: [PlanUnitId]
  }
  deriving (Eq, Show)

resolveExternalUnits :: CabalPlanRequest -> IO (Either String [ExternalUnit])
resolveExternalUnits request = do
  contents <-
    case planInput request of
      Just path -> readStrictFile path
      Nothing -> generatePlanJson request
  pure $ do
    units <- decodePlan (planCompiler request) contents
    planned <- externalPlanClosure units
    traverse externalUnitFromPlan planned >>= coalesceExternalUnits

generatePlanJson :: CabalPlanRequest -> IO String
generatePlanJson request =
  withTemporaryDirectory "repent-plan" $ \temporary -> do
    project <- canonicalizePath (planProject request)
    let buildDirectory = temporary </> "dist-newstyle"
        planPath = buildDirectory </> "cache" </> "plan.json"
        ghc = takeDirectory (planGhcPkg request) </> "ghc"
        args =
          [ "build"
          , "all"
          , "--dry-run"
          , "--offline"
          , "--enable-tests"
          , "--enable-benchmarks"
          , "--project-dir=" ++ project
          , "--builddir=" ++ buildDirectory
          , "--index-state=" ++ renderIndexState (planIndexState request)
          , "--with-compiler=" ++ ghc
          , "--with-hc-pkg=" ++ planGhcPkg request
          ]
    (status, stdout, stderr) <- readProcessWithExitCode (planCabal request) args ""
    case status of
      ExitSuccess -> readStrictFile planPath
      ExitFailure code ->
        ioError . userError $
          unlines
            [ "repent: cabal failed to produce plan.json (exit " ++ show code ++ ")"
            , "command: " ++ unwords (planCabal request : args)
            , stderr
            , stdout
            ]

decodePlan :: CompilerId -> String -> Either String [PlanUnit]
decodePlan expectedCompiler contents = do
  root <- parseJson contents >>= expectObject "plan.json"
  _cabalVersion <- stringField "cabal-version" root
  compiler <- stringField "compiler-id" root
  unlessEither
    (compiler == renderCompilerId expectedCompiler)
    ( "plan.json compiler mismatch: expected `"
        ++ renderCompilerId expectedCompiler
        ++ "`, got `"
        ++ compiler
        ++ "`"
    )
  unitValues <- arrayField "install-plan" root
  traverse decodePlanUnit unitValues

decodePlanUnit :: Json -> Either String PlanUnit
decodePlanUnit value = do
  fields <- expectObject "install-plan unit" value
  unitType <- stringField "type" fields
  identifier <- PlanUnitId <$> stringField "id" fields
  packageName <- parsedField "pkg-name" fields
  packageVersion <- parsedField "pkg-version" fields
  depends <- optionalStringArrayField "depends" fields
  executableDepends <- optionalStringArrayField "exe-depends" fields
  components <- optionalObjectField "components" fields
  componentDepends <- concat <$> traverse componentDependencies (map snd components)
  origin <- decodeOrigin unitType fields
  pure
    PlanUnit
      { unitId = identifier
      , unitPackageName = packageName
      , unitPackageVersion = packageVersion
      , unitOrigin = origin
      , unitDependencies =
          nub (map PlanUnitId (depends ++ executableDepends ++ componentDepends))
      }

componentDependencies :: Json -> Either String [String]
componentDependencies value = do
  fields <- expectObject "install-plan component" value
  depends <- optionalStringArrayField "depends" fields
  executableDepends <- optionalStringArrayField "exe-depends" fields
  pure (depends ++ executableDepends)

decodeOrigin :: String -> [(String, Json)] -> Either String PlanUnitOrigin
decodeOrigin unitType fields =
  case unitType of
    "pre-existing" -> Right PreExistingPlanUnit
    "configured" -> do
      style <- stringField "style" fields
      case style of
        "local" -> Right LocalPlanUnit
        "global" -> decodeRepositorySource fields
        _ -> Left ("unsupported configured-unit style in plan.json: `" ++ style ++ "`")
    _ -> Left ("unsupported install-plan unit type: `" ++ unitType ++ "`")

decodeRepositorySource :: [(String, Json)] -> Either String PlanUnitOrigin
decodeRepositorySource fields = do
  source <- objectField "pkg-src" fields
  sourceType <- stringField "type" source
  unlessEither
    (sourceType == "repo-tar")
    ("unsupported external package source in plan.json: `" ++ sourceType ++ "`")
  repository <- objectField "repo" source
  uri <- RepositoryUri <$> stringField "uri" repository
  sha256 <- HexSha256 <$> stringField "pkg-src-sha256" fields
  pure (HackagePlanUnit uri sha256)

externalPlanClosure :: [PlanUnit] -> Either String [PlanUnit]
externalPlanClosure units =
  walk [] [] roots
  where
    roots =
      nub
        [ dependency
        | unit <- units
        , unitOrigin unit == LocalPlanUnit
        , dependency <- unitDependencies unit
        ]

    walk _ selected [] = Right selected
    walk visited selected (identifier : remaining)
      | identifier `elem` visited = walk visited selected remaining
      | otherwise =
          case find ((== identifier) . unitId) units of
            Nothing -> Left ("plan.json references missing unit `" ++ renderPlanUnitId identifier ++ "`")
            Just unit ->
              case unitOrigin unit of
                LocalPlanUnit ->
                  walk (identifier : visited) selected (unitDependencies unit ++ remaining)
                PreExistingPlanUnit ->
                  walk (identifier : visited) (unit : selected) remaining
                HackagePlanUnit _ _ ->
                  walk
                    (identifier : visited)
                    (unit : selected)
                    (unitDependencies unit ++ remaining)

externalUnitFromPlan :: PlanUnit -> Either String ExternalUnit
externalUnitFromPlan unit = do
  source <-
    case unitOrigin unit of
      PreExistingPlanUnit -> Right GhcBoot
      HackagePlanUnit repository sha256 ->
        HackageSdist
          <$> hackageTarballUrl repository (unitPackageName unit) (unitPackageVersion unit)
          <*> (SdistHash <$> sha256Sri sha256)
      LocalPlanUnit -> Left "internal error: local unit escaped the external plan closure"
  pure
    ExternalUnit
      { externalUnitName = unitPackageName unit
      , externalUnitVersion = unitPackageVersion unit
      , externalUnitSource = source
      }

coalesceExternalUnits :: [ExternalUnit] -> Either String [ExternalUnit]
coalesceExternalUnits = foldM insert [] . sortOn (prettyShow . externalUnitName)
  where
    insert units candidate =
      case find ((== externalUnitName candidate) . externalUnitName) units of
        Nothing -> Right (units ++ [candidate])
        Just existing
          | existing == candidate -> Right units
          | otherwise ->
              Left
                ( "penance/lock/1 cannot represent multiple planned instances of `"
                    ++ prettyShow (externalUnitName candidate)
                    ++ "`"
                )

hackageTarballUrl :: RepositoryUri -> PackageName -> Version -> Either String HackageUrl
hackageTarballUrl repository name version = do
  let uri = renderRepositoryUri repository
  unlessEither
    ("hackage.haskell.org" `isInfixOf` uri)
    ("penance/lock/1 cannot represent non-Hackage repository `" ++ uri ++ "`")
  let packageId = prettyShow name ++ "-" ++ prettyShow version
  pure . HackageUrl $
    "https://hackage.haskell.org/package/"
      ++ packageId
      ++ "/"
      ++ packageId
      ++ ".tar.gz"

sha256Sri :: HexSha256 -> Either String String
sha256Sri hash = do
  bytes <- decodeHex (renderHexSha256 hash)
  unlessEither (length bytes == 32) "pkg-src-sha256 is not a 32-byte SHA-256 digest"
  pure ("sha256-" ++ encodeBase64 bytes)

decodeHex :: String -> Either String [Int]
decodeHex value =
  case value of
    [] -> Right []
    high : low : rest
      | isHexDigit high && isHexDigit low ->
          ((digitToInt high * 16 + digitToInt low) :) <$> decodeHex rest
    _ -> Left "pkg-src-sha256 is not an even-length hexadecimal digest"

encodeBase64 :: [Int] -> String
encodeBase64 bytes =
  case bytes of
    first : second : third : rest ->
      base64Digit (first `shiftR` 2)
        : base64Digit (((first .&. 3) `shiftL` 4) .|. (second `shiftR` 4))
        : base64Digit (((second .&. 15) `shiftL` 2) .|. (third `shiftR` 6))
        : base64Digit (third .&. 63)
        : encodeBase64 rest
    [first, second] ->
      [ base64Digit (first `shiftR` 2)
      , base64Digit (((first .&. 3) `shiftL` 4) .|. (second `shiftR` 4))
      , base64Digit ((second .&. 15) `shiftL` 2)
      , '='
      ]
    [first] ->
      [ base64Digit (first `shiftR` 2)
      , base64Digit ((first .&. 3) `shiftL` 4)
      , '='
      , '='
      ]
    [] -> []

base64Digit :: Int -> Char
base64Digit index =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" !! index

expectObject :: String -> Json -> Either String [(String, Json)]
expectObject _ (JsonObject fields) = Right fields
expectObject context _ = Left (context ++ " must be a JSON object")

arrayField :: String -> [(String, Json)] -> Either String [Json]
arrayField name fields =
  case lookup name fields of
    Just (JsonArray values) -> Right values
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be an array")
    Nothing -> Left ("plan.json is missing field `" ++ name ++ "`")

objectField :: String -> [(String, Json)] -> Either String [(String, Json)]
objectField name fields =
  case lookup name fields of
    Just (JsonObject value) -> Right value
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be an object")
    Nothing -> Left ("plan.json is missing field `" ++ name ++ "`")

optionalObjectField :: String -> [(String, Json)] -> Either String [(String, Json)]
optionalObjectField name fields =
  case lookup name fields of
    Nothing -> Right []
    Just (JsonObject value) -> Right value
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be an object")

stringField :: String -> [(String, Json)] -> Either String String
stringField name fields =
  case lookup name fields of
    Just (JsonString value) -> Right value
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be a string")
    Nothing -> Left ("plan.json is missing field `" ++ name ++ "`")

parsedField :: Parsec a => String -> [(String, Json)] -> Either String a
parsedField name fields = do
  value <- stringField name fields
  case simpleParsec value of
    Just parsed -> Right parsed
    Nothing -> Left ("plan.json field `" ++ name ++ "` is invalid: `" ++ value ++ "`")

optionalStringArrayField :: String -> [(String, Json)] -> Either String [String]
optionalStringArrayField name fields =
  case lookup name fields of
    Nothing -> Right []
    Just (JsonArray values) -> traverse asString values
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be an array")
  where
    asString (JsonString value) = Right value
    asString _ = Left ("plan.json field `" ++ name ++ "` must contain only strings")

unlessEither :: Bool -> String -> Either String ()
unlessEither condition message =
  unless condition (Left message)

readStrictFile :: FilePath -> IO String
readStrictFile path = do
  contents <- readFile path
  length contents `seq` pure contents

withTemporaryDirectory :: String -> (FilePath -> IO a) -> IO a
withTemporaryDirectory template =
  bracket create removePathForcibly
  where
    create = do
      parent <- getTemporaryDirectory
      (path, handle) <- openTempFile parent template
      hClose handle
      removeFile path
      createDirectory path
      pure path
