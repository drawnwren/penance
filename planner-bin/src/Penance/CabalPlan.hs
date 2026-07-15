module Penance.CabalPlan
  ( CabalPlanRequest (..)
  , ResolvedPlan (..)
  , LocalComponentUnit (..)
  , ExternalSource (..)
  , ExternalUnit (..)
  , HackageUrl (..)
  , SdistHash (..)
  , UnitId
  , mkUnitId
  , renderUnitId
  , FlagAssignment
  , flagAssignment
  , renderFlagAssignment
  , decodeResolvedPlan
  , resolvePlan
  ) where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.Char (digitToInt, isHexDigit)
import Data.List (isInfixOf, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Distribution.Parsec (Parsec, simpleParsec)
import Distribution.Pretty (prettyShow)
import Distribution.Types.PackageName (PackageName)
import Distribution.Version (Version)
import Penance.Json (Json (..), parseJson)
import Penance.Json.Decode (asObject, asString)
import Penance.Types (CompilerId, IndexState, renderCompilerId, renderIndexState)
import Penance.Utf8.IO (readUtf8File)
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
  , planConstraints :: [String]
  , planInput :: Maybe FilePath
  }
  deriving (Eq, Show)

data ExternalUnit = ExternalUnit
  { externalUnitId :: UnitId
  , externalUnitName :: PackageName
  , externalUnitVersion :: Version
  , externalUnitFlags :: FlagAssignment
  , externalUnitComponent :: Maybe String
  , externalUnitStyle :: String
  , externalUnitSource :: ExternalSource
  , externalUnitDepends :: [UnitId]
  , externalUnitExeDepends :: [UnitId]
  , externalUnitInstantiatedWith :: [(String, UnitId)]
  }
  deriving (Eq, Show)

data LocalComponentUnit = LocalComponentUnit
  { localUnitId :: UnitId
  , localUnitPackageName :: PackageName
  , localUnitComponent :: String
  , localUnitExternalDepends :: [UnitId]
  , localUnitExternalExeDepends :: [UnitId]
  }
  deriving (Eq, Show)

data ResolvedPlan = ResolvedPlan
  { resolvedExternalUnits :: [ExternalUnit]
  , resolvedLocalComponents :: [LocalComponentUnit]
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

newtype UnitId = UnitId String
  deriving (Eq, Ord, Show)

mkUnitId :: String -> Either String UnitId
mkUnitId value
  | null value = Left "plan.json unit id must not be empty"
  | otherwise = Right (UnitId value)

renderUnitId :: UnitId -> String
renderUnitId (UnitId value) = value

newtype FlagAssignment = FlagAssignment [(String, Bool)]
  deriving (Eq, Ord, Show)

flagAssignment :: [(String, Bool)] -> Either String FlagAssignment
flagAssignment entries = do
  let ordered = sortOn fst entries
      names = map fst ordered
  unlessEither (all (not . null) names) "plan.json flag names must not be empty"
  unlessEither (length names == Set.size (Set.fromList names)) "plan.json flag assignment contains duplicate names"
  pure (FlagAssignment ordered)

renderFlagAssignment :: FlagAssignment -> [(String, Bool)]
renderFlagAssignment (FlagAssignment entries) = entries

newtype RepositoryUri = RepositoryUri {renderRepositoryUri :: String}
  deriving (Eq, Ord, Show)

newtype HexSha256 = HexSha256 {renderHexSha256 :: String}
  deriving (Eq, Ord, Show)

data PlanUnitOrigin
  = LocalPlanUnit
  | HackagePlanUnit String RepositoryUri HexSha256
  | PreExistingPlanUnit
  deriving (Eq, Show)

data PlanComponent = PlanComponent
  { planComponentName :: String
  , planComponentDependencies :: [UnitId]
  , planComponentExecutableDependencies :: [UnitId]
  }
  deriving (Eq, Show)

data PlanUnit = PlanUnit
  { unitId :: UnitId
  , unitPackageName :: PackageName
  , unitPackageVersion :: Version
  , unitFlags :: FlagAssignment
  , unitComponent :: Maybe String
  , unitOrigin :: PlanUnitOrigin
  , unitDependencies :: [UnitId]
  , unitExecutableDependencies :: [UnitId]
  , unitInstantiatedWith :: [(String, UnitId)]
  , unitComponents :: [PlanComponent]
  }
  deriving (Eq, Show)

resolvePlan :: CabalPlanRequest -> IO (Either String ResolvedPlan)
resolvePlan request = do
  contents <-
    case planInput request of
      Just path -> readStrictFile path
      Nothing -> generatePlanJson request
  pure (decodeResolvedPlan (planCompiler request) contents)

decodeResolvedPlan :: CompilerId -> String -> Either String ResolvedPlan
decodeResolvedPlan compiler contents = do
  units <- decodePlan compiler contents
  externalPlanClosure units

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
            ++ map ("--constraint=" ++) (planConstraints request)
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
  root <- parseJson contents >>= asObject "plan.json"
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
  fields <- asObject "install-plan unit" value
  unitType <- stringField "type" fields
  identifier <- stringField "id" fields >>= mkUnitId
  packageName <- parsedField "pkg-name" fields
  packageVersion <- parsedField "pkg-version" fields
  flags <- optionalBoolObjectField "flags" fields >>= flagAssignment
  component <- optionalStringField "component-name" fields
  depends <- optionalStringArrayField "depends" fields
  executableDepends <- optionalStringArrayField "exe-depends" fields
  instantiatedWith <- optionalStringObjectField "instantiated-with" fields
  components <- optionalObjectField "components" fields >>= traverse decodePlanComponent
  origin <- decodeOrigin unitType fields
  directDependencies <- traverse mkUnitId depends
  directExecutableDependencies <- traverse mkUnitId executableDepends
  instantiations <-
    traverse
      (\(name, target) -> fmap (\targetUnitId -> (name, targetUnitId)) (mkUnitId target))
      instantiatedWith
  let dependencies = canonicalUnitIds (directDependencies ++ concatMap planComponentDependencies components)
      executableDependencies =
        canonicalUnitIds
          (directExecutableDependencies ++ concatMap planComponentExecutableDependencies components)
  pure
    PlanUnit
      { unitId = identifier
      , unitPackageName = packageName
      , unitPackageVersion = packageVersion
      , unitFlags = flags
      , unitComponent = component
      , unitOrigin = origin
      , unitDependencies = dependencies
      , unitExecutableDependencies = executableDependencies
      , unitInstantiatedWith = sortOn fst instantiations
      , unitComponents = sortOn planComponentName components
      }

decodePlanComponent :: (String, Json) -> Either String PlanComponent
decodePlanComponent (name, value) = do
  fields <- asObject "install-plan component" value
  dependencies <- optionalStringArrayField "depends" fields >>= traverse mkUnitId
  executableDependencies <- optionalStringArrayField "exe-depends" fields >>= traverse mkUnitId
  pure
    PlanComponent
      { planComponentName = name
      , planComponentDependencies = canonicalUnitIds dependencies
      , planComponentExecutableDependencies = canonicalUnitIds executableDependencies
      }

decodeOrigin :: String -> [(String, Json)] -> Either String PlanUnitOrigin
decodeOrigin unitType fields =
  case unitType of
    "pre-existing" -> Right PreExistingPlanUnit
    "configured" -> do
      style <- stringField "style" fields
      case style of
        "local" -> Right LocalPlanUnit
        "global" -> decodeRepositorySource style fields
        _ -> Left ("unsupported configured-unit style in plan.json: `" ++ style ++ "`")
    _ -> Left ("unsupported install-plan unit type: `" ++ unitType ++ "`")

decodeRepositorySource :: String -> [(String, Json)] -> Either String PlanUnitOrigin
decodeRepositorySource style fields = do
  source <- objectField "pkg-src" fields
  sourceType <- stringField "type" source
  unlessEither
    (sourceType == "repo-tar")
    ("unsupported external package source in plan.json: `" ++ sourceType ++ "`")
  repository <- objectField "repo" source
  uri <- RepositoryUri <$> stringField "uri" repository
  sha256 <- HexSha256 <$> stringField "pkg-src-sha256" fields
  pure (HackagePlanUnit style uri sha256)

externalPlanClosure :: [PlanUnit] -> Either String ResolvedPlan
externalPlanClosure units =
  finish =<< walk Set.empty [] roots
  where
    unitsById = Map.fromList [(unitId unit, unit) | unit <- units]
    roots =
      Set.toAscList . Set.fromList $
        [ dependency
        | unit <- units
        , unitOrigin unit == LocalPlanUnit
        , dependency <- unitDependencies unit ++ unitExecutableDependencies unit
        ]

    walk _ selected [] = Right selected
    walk visited selected (identifier : remaining)
      | Set.member identifier visited = walk visited selected remaining
      | otherwise =
          case Map.lookup identifier unitsById of
            Nothing -> Left ("plan.json references missing unit `" ++ renderUnitId identifier ++ "`")
            Just unit ->
              case unitOrigin unit of
                LocalPlanUnit ->
                  walk (Set.insert identifier visited) selected (allDependencies unit ++ remaining)
                PreExistingPlanUnit ->
                  walk
                    (Set.insert identifier visited)
                    (unit : selected)
                    (allDependencies unit ++ remaining)
                HackagePlanUnit _ _ _ ->
                  walk
                    (Set.insert identifier visited)
                    (unit : selected)
                    (allDependencies unit ++ remaining)

    allDependencies unit = unitDependencies unit ++ unitExecutableDependencies unit

    finish selected = do
      externalUnits <- traverse externalUnitFromPlan (sortOn unitId selected)
      let externalIds = Set.fromList (map externalUnitId externalUnits)
      locals <-
        concat
          <$> traverse
            (localComponentsFromPlan externalIds)
            (filter ((== LocalPlanUnit) . unitOrigin) units)
      pure
        ResolvedPlan
          { resolvedExternalUnits = externalUnits
          , resolvedLocalComponents = sortOn (\unit -> (localUnitPackageName unit, localUnitComponent unit)) locals
          }

localComponentsFromPlan :: Set.Set UnitId -> PlanUnit -> Either String [LocalComponentUnit]
localComponentsFromPlan externalIds unit =
  case (unitComponent unit, unitComponents unit) of
    (Just component, []) ->
      Right [localComponent component (unitDependencies unit) (unitExecutableDependencies unit)]
    (Nothing, components@(_ : _)) ->
      Right
        [ localComponent
            (planComponentName component)
            (planComponentDependencies component)
            (planComponentExecutableDependencies component)
        | component <- components
        ]
    (Just _, _ : _) ->
      Left ("local plan unit `" ++ identifier ++ "` has both component-name and components")
    (Nothing, []) ->
      Left ("local plan unit `" ++ identifier ++ "` has neither component-name nor components")
  where
    identifier = renderUnitId (unitId unit)
    localComponent component dependencies executableDependencies =
      LocalComponentUnit
        { localUnitId = unitId unit
        , localUnitPackageName = unitPackageName unit
        , localUnitComponent = component
        , localUnitExternalDepends = filter (`Set.member` externalIds) dependencies
        , localUnitExternalExeDepends = filter (`Set.member` externalIds) executableDependencies
        }

canonicalUnitIds :: [UnitId] -> [UnitId]
canonicalUnitIds = Set.toAscList . Set.fromList

externalUnitFromPlan :: PlanUnit -> Either String ExternalUnit
externalUnitFromPlan unit = do
  source <-
    case unitOrigin unit of
      PreExistingPlanUnit -> Right GhcBoot
      HackagePlanUnit _ repository sha256 ->
        HackageSdist
          <$> hackageTarballUrl repository (unitPackageName unit) (unitPackageVersion unit)
          <*> (SdistHash <$> sha256Sri sha256)
      LocalPlanUnit -> Left "internal error: local unit escaped the external plan closure"
  pure
    ExternalUnit
      { externalUnitId = unitId unit
      , externalUnitName = unitPackageName unit
      , externalUnitVersion = unitPackageVersion unit
      , externalUnitFlags = unitFlags unit
      , externalUnitComponent = unitComponent unit
      , externalUnitStyle =
          case unitOrigin unit of
            HackagePlanUnit style _ _ -> style
            PreExistingPlanUnit -> "global"
            LocalPlanUnit -> "local"
      , externalUnitSource = source
      , externalUnitDepends = unitDependencies unit
      , externalUnitExeDepends = unitExecutableDependencies unit
      , externalUnitInstantiatedWith = unitInstantiatedWith unit
      }

hackageTarballUrl :: RepositoryUri -> PackageName -> Version -> Either String HackageUrl
hackageTarballUrl repository name version = do
  let uri = renderRepositoryUri repository
  unlessEither
    ("hackage.haskell.org" `isInfixOf` uri)
    ("penance/lock/2 cannot represent non-Hackage repository `" ++ uri ++ "`")
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

optionalStringField :: String -> [(String, Json)] -> Either String (Maybe String)
optionalStringField name fields =
  case lookup name fields of
    Nothing -> Right Nothing
    Just JsonNull -> Right Nothing
    Just (JsonString value) -> Right (Just value)
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be a string or null")

optionalBoolObjectField :: String -> [(String, Json)] -> Either String [(String, Bool)]
optionalBoolObjectField name fields =
  case lookup name fields of
    Nothing -> Right []
    Just (JsonObject entries) -> traverse parseEntry entries
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be an object")
  where
    parseEntry (key, JsonBool value) = Right (key, value)
    parseEntry (key, _) = Left ("plan.json flag `" ++ key ++ "` must be boolean")

optionalStringObjectField :: String -> [(String, Json)] -> Either String [(String, String)]
optionalStringObjectField name fields =
  case lookup name fields of
    Nothing -> Right []
    Just JsonNull -> Right []
    Just (JsonObject entries) -> traverse parseEntry entries
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be an object or null")
  where
    parseEntry (key, JsonString value) = Right (key, value)
    parseEntry (key, _) = Left ("plan.json field `" ++ name ++ "." ++ key ++ "` must be a string")

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
    Just (JsonArray values) -> traverse parseString values
    Just _ -> Left ("plan.json field `" ++ name ++ "` must be an array")
  where
    parseString value = asString ("plan.json field `" ++ name ++ "` item") value

unlessEither :: Bool -> String -> Either String ()
unlessEither condition message =
  unless condition (Left message)

readStrictFile :: FilePath -> IO String
readStrictFile path = do
  contents <- readUtf8File path
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
