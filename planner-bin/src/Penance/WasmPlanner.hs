module Penance.WasmPlanner
  ( normalizeProject
  , runSelfTests
  )
where

import Data.Char (isHexDigit, toLower)
import Data.List (isPrefixOf, sort, sortBy)
import Data.Maybe (fromMaybe, mapMaybe)
import Penance.Blake3 (Blake3Digest, hash, hashHex, renderBlake3Digest)
import Penance.CabalLex
  ( LogicalLine (..)
  , collectContinuation
  , logicalLines
  , sortNub
  , splitField
  , splitSubstring
  , trim
  , trimCommas
  )
import Penance.CabalProject (CabalProject (..), parseCabalProject)
import Penance.Json (Json (..))
import qualified Penance.Json as Json
import Penance.Json.Decode
  ( asObject
  , optionalArray
  , optionalBoolMap
  , optionalString
  , rejectUnknown
  , requiredArray
  , requiredString
  )
import Penance.Skeleton
  ( BackpackSkeleton (..)
  , ExpectedInstantiation (..)
  , ExpectedOutputs (..)
  , IndefiniteUnit (..)
  , LocalComponent (..)
  , LocalPackage (..)
  , ProjectKey
  , ProjectSkeleton (..)
  , encodeLocalPackage
  , encodeProjectSkeleton
  , componentUnitKey
  , mkComponentId
  , mkModuleName
  , mkPkgName
  , planCacheKeyFromDigest
  , projectKeyFromDigest
  , renderProjectKey
  , renderPkgName
  )
import Penance.Types
  ( CompilerId (..)
  , ComponentKind (..)
  , Granularity
  , IndexState (..)
  , MaterializationMode
  , SourceKind
  , parseComponentKind
  , parseGranularity
  , parseMaterializationMode
  , parseSourceKind
  , renderGranularity
  , renderMaterializationMode
  , renderSourceKind
  )

data NormalizeInput = NormalizeInput
  { inputSrcTreeDigest :: Maybe String
  , inputSourceManifest :: [SourceManifestEntry]
  , inputCompiler :: CompilerId
  , inputIndexState :: IndexState
  , inputCabalProjectText :: String
  , inputLocalPackageManifests :: [LocalPackageManifest]
  , inputFlags :: [(String, Bool)]
  , inputMaterializationMode :: MaterializationMode
  , inputGranularity :: Granularity
  }
  deriving (Eq, Show)

data SourceManifestEntry = SourceManifestEntry
  { sourcePath :: String
  , sourceKind :: SourceKind
  , sourceSha256 :: String
  }
  deriving (Eq, Ord, Show)

data LocalPackageManifest = LocalPackageManifest
  { manifestPath :: String
  , manifestCabalText :: String
  }
  deriving (Eq, Ord, Show)

data CabalComponent = CabalComponent
  { cabalComponentId :: String
  , cabalComponentKind :: ComponentKind
  , cabalComponentName :: Maybe String
  , cabalProvidedModules :: [String]
  , cabalSignatures :: [String]
  , cabalRequiredSignatures :: [String]
  , cabalMixins :: [String]
  , cabalReexportedModules :: [String]
  }
  deriving (Eq, Ord, Show)

data CabalPackage = CabalPackage
  { cabalPackageName :: String
  , cabalPackageVersion :: String
  , cabalPackageComponents :: [CabalComponent]
  }
  deriving (Eq, Show)

data StanzaHeader
  = MainLibraryHeader
  | NamedComponentHeader ComponentKind String
  deriving (Eq, Show)

normalizeProject :: String -> Either String String
normalizeProject inputText = parseNormalizeInput inputText >>= normalizeProjectWorker

normalizeProjectWorker :: NormalizeInput -> Either String String
normalizeProjectWorker input = do
  sourceDigest <- resolveSourceDigest input
  require
    ("blake3:" `isPrefixOf` sourceDigest)
    ("srcTreeDigest must be a blake3 digest, got `" ++ sourceDigest ++ "`")
  cabalProject <- parseCabalProject (inputCabalProjectText input)
  cabalPackages <- mapM parseManifest manifests
  parsedPackages <- mapM localPackageFromCabal cabalPackages
  parsedInstantiations <- concat <$> mapM instantiationsFromPackage parsedPackages
  let normalizedPackages = sortBy comparePackage parsedPackages
      parsedIndefiniteUnits = sort (concatMap indefiniteUnitsFromPackage parsedPackages)
      expectedInstantiationUnits = sort parsedInstantiations
      projectKeyValue =
        projectKeyFromDigest
          (digestJson (canonicalProjectJson input flags normalizedPackages cabalProject))
      planCacheKeyValue =
        planCacheKeyFromDigest (digestJson (planKeyJson projectKeyValue))
  pure
    ( Json.renderJson
        ( encodeProjectSkeleton
            ProjectSkeleton
              { skeletonPath = "" -- native-only provenance; unused on the WASM side
              , projectKey = projectKeyValue
              , localPackages = normalizedPackages
              , sourceRepos = projectSourceRepos cabalProject
              , planCacheKey = planCacheKeyValue
              , plannerDrvInputs = []
              , granularity = inputGranularity input
              , backpack =
                  BackpackSkeleton
                    { indefiniteUnits = parsedIndefiniteUnits
                    , expectedInstantiations = expectedInstantiationUnits
                    }
              , expectedOutputs =
                  ExpectedOutputs
                    { componentGraphDrv = True
                    , moduleGraphDrv = True
                    , backpackGraphDrv = True
                    }
              }
        )
    )
  where
    flags = normalizeFlags (inputFlags input)
    manifests = sort [manifest {manifestPath = normalizePath (manifestPath manifest)} | manifest <- inputLocalPackageManifests input]

parseManifest :: LocalPackageManifest -> Either String CabalPackage
parseManifest manifest = parseCabalFile (manifestPath manifest) (manifestCabalText manifest)

comparePackage :: LocalPackage -> LocalPackage -> Ordering
comparePackage left right =
  compare
    (renderPkgName (packageName left), packageVersion left, packageComponents left)
    (renderPkgName (packageName right), packageVersion right, packageComponents right)

parseNormalizeInput :: String -> Either String NormalizeInput
parseNormalizeInput text = do
  value <- mapLeft ("invalid input JSON: " ++) (Json.parseJson text)
  fields <- asObject "input" value
  rejectUnknown
    "input"
    [ "srcTreeDigest"
    , "sourceManifest"
    , "compiler"
    , "indexState"
    , "cabalProjectText"
    , "localPackageManifests"
    , "flags"
    , "materializationMode"
    , "granularity"
    ]
    fields
  NormalizeInput
    <$> optionalString "srcTreeDigest" fields
    <*> optionalArray "sourceManifest" parseSourceManifestEntry fields
    <*> (CompilerId <$> requiredString "compiler" fields)
    <*> (IndexState <$> requiredString "indexState" fields)
    <*> requiredString "cabalProjectText" fields
    <*> requiredArray "localPackageManifests" parseLocalPackageManifest fields
    <*> optionalBoolMap "flags" fields
    <*> requiredParsed "materializationMode" parseMaterializationMode fields
    <*> requiredParsed "granularity" parseGranularity fields

parseSourceManifestEntry :: Json -> Either String SourceManifestEntry
parseSourceManifestEntry value = do
  fields <- asObject "sourceManifest entry" value
  rejectUnknown "sourceManifest entry" ["path", "kind", "sha256"] fields
  SourceManifestEntry
    <$> requiredString "path" fields
    <*> requiredParsed "kind" parseSourceKind fields
    <*> requiredString "sha256" fields

parseLocalPackageManifest :: Json -> Either String LocalPackageManifest
parseLocalPackageManifest value = do
  fields <- asObject "localPackageManifest" value
  rejectUnknown "localPackageManifest" ["path", "cabalText"] fields
  LocalPackageManifest
    <$> requiredString "path" fields
    <*> requiredString "cabalText" fields

resolveSourceDigest :: NormalizeInput -> Either String String
resolveSourceDigest input
  | null (inputSourceManifest input) =
      maybe
        (Left "input must include either srcTreeDigest or sourceManifest")
        Right
        (inputSrcTreeDigest input)
  | otherwise = do
      normalized <- normalizeSourceManifest (inputSourceManifest input)
      let computed = "blake3:" ++ renderBlake3Digest (digestJson (Json.array (map sourceManifestJson normalized)))
      case inputSrcTreeDigest input of
        Just provided
          | provided /= computed ->
              Left
                ( "srcTreeDigest `"
                    ++ provided
                    ++ "` does not match digest derived from sourceManifest `"
                    ++ computed
                    ++ "`"
                )
        _ -> Right computed

normalizeSourceManifest :: [SourceManifestEntry] -> Either String [SourceManifestEntry]
normalizeSourceManifest entries = do
  normalized <- mapM normalizeEntry entries
  let ordered = sort normalized
      duplicates = duplicatePaths ordered
  case duplicates of
    path : _ -> Left ("source manifest contains duplicate path `" ++ path ++ "`")
    [] -> Right ordered
  where
    normalizeEntry entry = do
      let path = normalizePath (sourcePath entry)
          sha = sourceSha256 entry
      require
        (path /= "." && not ("/" `isPrefixOf` path) && ".." `notElem` splitOn '/' path)
        ("source manifest path must be relative and non-empty, got `" ++ sourcePath entry ++ "`")
      require
        (length sha == 64 && all isLowerHex sha)
        ("source manifest sha256 must be 64 lowercase hex characters at `" ++ path ++ "`")
      pure entry {sourcePath = path}
    isLowerHex ch = isHexDigit ch && not (ch >= 'A' && ch <= 'F')
    duplicatePaths (left : right : rest)
      | sourcePath left == sourcePath right = sourcePath left : duplicatePaths (right : rest)
      | otherwise = duplicatePaths (right : rest)
    duplicatePaths _ = []

normalizeFlags :: [(String, Bool)] -> [(String, Bool)]
normalizeFlags = sort . foldl insertNormalized [] . sort
  where
    insertNormalized flags (name, enabled) =
      let normalized = map toLower (trim name)
       in (normalized, enabled) : filter ((/= normalized) . fst) flags

parseCabalFile :: String -> String -> Either String CabalPackage
parseCabalFile path text = go (logicalLines text) [] []
  where
    go [] topFields components = finish topFields components
    go allLines@(line : rest) topFields components
      | conditionalOrImport (logicalText line) = unsupportedConditional path line
      | logicalIndent line /= 0 = malformed line
      | Just header <- parseStanzaHeader (logicalText line) = do
          (component, remaining) <- parseComponent path header rest []
          go remaining topFields (component : components)
      | shouldSkipTopLevelStanza (logicalText line) =
          go (skipStanza allLines) topFields components
      | looksLikeUnsupportedStanza (logicalText line) = unsupported line
      | otherwise = do
          (field, firstValue) <- splitField path line
          let (value, remaining) = collectContinuation (logicalIndent line) firstValue rest
          go remaining (appendField (map toLower field) value topFields) components
    finish fields components = do
      name <- requiredTextField path "name" fields
      version <- requiredTextField path "version" fields
      pure (CabalPackage name version (sort components))
    malformed line =
      Left
        ( path
            ++ ": line "
            ++ show (logicalNumber line)
            ++ ": expected `key: value`, got `"
            ++ logicalText line
            ++ "`"
        )
    unsupported line =
      Left
        ( path
            ++ ": line "
            ++ show (logicalNumber line)
            ++ ": unsupported Cabal stanza `"
            ++ logicalText line
            ++ "`"
        )

parseComponent :: String -> StanzaHeader -> [LogicalLine] -> [(String, String)] -> Either String (CabalComponent, [LogicalLine])
parseComponent path header allLines fields =
  case allLines of
    [] -> finish []
    line : rest
      | conditionalOrImport (logicalText line) -> unsupportedConditional path line
      | logicalIndent line == 0 -> finish allLines
      | parseStanzaHeader (logicalText line) /= Nothing || looksLikeUnsupportedStanza (logicalText line) ->
          Left
            ( path
                ++ ": line "
                ++ show (logicalNumber line)
                ++ ": unsupported Cabal stanza `"
                ++ logicalText line
                ++ "`"
            )
      | otherwise -> do
          (field, firstValue) <- splitField path line
          let (value, remaining) = collectContinuation (logicalIndent line) firstValue rest
          parseComponent path header remaining (appendField (map toLower field) value fields)
  where
    finish remaining =
      let modules =
            sortNub
              ( concatMap
                  (splitModuleList . (`lookup` fields))
                  ["exposed-modules", "other-modules", "generated-other-modules"]
                  ++ [ "Main"
                     | stanzaKind header `elem` [ExecutableKind, TestSuiteKind, BenchmarkKind]
                     , lookup "main-is" fields /= Nothing
                     ]
              )
          signatures = splitModuleList (lookup "signatures" fields)
          mixins = splitTopLevelList (lookup "mixins" fields)
          reexports = splitTopLevelList (lookup "reexported-modules" fields)
       in Right
            ( CabalComponent
                { cabalComponentId = componentId header
                , cabalComponentKind = stanzaKind header
                , cabalComponentName = stanzaName header
                , cabalProvidedModules = modules
                , cabalSignatures = signatures
                , cabalRequiredSignatures = signatures
                , cabalMixins = mixins
                , cabalReexportedModules = reexports
                }
            , remaining
            )

parseStanzaHeader :: String -> Maybe StanzaHeader
parseStanzaHeader text =
  case words text of
    [kind]
      | Right LibraryKind <- parseComponentKind (lower kind) -> Just MainLibraryHeader
    [kind, name] -> NamedComponentHeader <$> eitherToMaybe (parseComponentKind (lower kind)) <*> pure name
    _ -> Nothing

stanzaKind :: StanzaHeader -> ComponentKind
stanzaKind header =
  case header of
    MainLibraryHeader -> LibraryKind
    NamedComponentHeader kind _ -> kind

stanzaName :: StanzaHeader -> Maybe String
stanzaName header =
  case header of
    MainLibraryHeader -> Nothing
    NamedComponentHeader _ name -> Just name

componentId :: StanzaHeader -> String
componentId header =
  case header of
    MainLibraryHeader -> "lib"
    NamedComponentHeader LibraryKind name -> "lib:" ++ name
    NamedComponentHeader ExecutableKind name -> "exe:" ++ name
    NamedComponentHeader TestSuiteKind name -> "test:" ++ name
    NamedComponentHeader BenchmarkKind name -> "bench:" ++ name

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe value =
  case value of
    Left _ -> Nothing
    Right result -> Just result

localPackageFromCabal :: CabalPackage -> Either String LocalPackage
localPackageFromCabal package = do
  parsedPackageName <- mkPkgName (cabalPackageName package)
  parsedComponents <- mapM localComponentFromCabal (cabalPackageComponents package)
  Right
    LocalPackage
    { packageName = parsedPackageName
    , packageVersion = cabalPackageVersion package
    , packageComponents = sortNub (map componentName parsedComponents)
    , packageComponentDetails = sort parsedComponents
    , packageSignatures = sortNub (concatMap componentSignatures parsedComponents)
    , packageRequiredSignatures = sortNub (concatMap componentRequiredSignatures parsedComponents)
    , packageProvidedModules = sortNub (concatMap componentProvidedModules parsedComponents)
    }

localComponentFromCabal :: CabalComponent -> Either String LocalComponent
localComponentFromCabal component = do
  parsedComponentName <- mkComponentId (cabalComponentId component)
  parsedProvidedModules <- mapM mkModuleName (cabalProvidedModules component)
  parsedSignatures <- mapM mkModuleName (cabalSignatures component)
  parsedRequiredSignatures <- mapM mkModuleName (cabalRequiredSignatures component)
  Right
    LocalComponent
    { componentName = parsedComponentName
    , componentKind = cabalComponentKind component
    , componentProvidedModules = parsedProvidedModules
    , componentSignatures = parsedSignatures
    , componentRequiredSignatures = parsedRequiredSignatures
    , componentMixins = cabalMixins component
    , componentReexportedModules = cabalReexportedModules component
    }

indefiniteUnitsFromPackage :: LocalPackage -> [IndefiniteUnit]
indefiniteUnitsFromPackage package =
  [ IndefiniteUnit
      { indefiniteUnit = componentUnitKey (packageName package) (componentName component)
      , indefinitePackage = packageName package
      , indefiniteComponent = componentName component
      , indefiniteSignatures = componentSignatures component
      , indefiniteRequiredSignatures = componentRequiredSignatures component
      , indefiniteMixins = componentMixins component
      , indefiniteReexportedModules = componentReexportedModules component
      }
  | component <- packageComponentDetails package
  , not (null (componentRequiredSignatures component))
  ]

instantiationsFromPackage :: LocalPackage -> Either String [ExpectedInstantiation]
instantiationsFromPackage package =
  concat <$> mapM fromComponent (packageComponentDetails package)
  where
    fromComponent component = concat <$> mapM (fromMixin component) (componentMixins component)
    fromMixin component mixin =
      case holesFromMixin mixin of
        Nothing -> Right []
        Just holes
          | null holes -> Right []
          | otherwise -> do
              parsedHoles <- mapM parseHole holes
              Right
                [ ExpectedInstantiation
                    { instantiationUnit = componentUnitKey (packageName package) (componentName component)
                    , instantiationHoles = parsedHoles
                    }
                ]
    parseHole (name, provider) = do
      parsedName <- mkModuleName name
      Right (parsedName, provider)

holesFromMixin :: String -> Maybe [(String, String)]
holesFromMixin mixin = do
  (_, contents0) <- splitOnce '(' mixin
  let contents = trim (removeSuffix ")" contents0)
      entries = splitTopLevelCommas contents
      holes = sort (mapMaybe hole entries)
  pure holes
  where
    hole entry
      | "hiding " `isPrefixOf` entry = Nothing
      | Just (name, provider) <- splitOnce '=' entry = Just (trim name, trim provider)
      | Just (provider, name) <- splitSubstring " as " entry = Just (trim name, trim provider)
      | otherwise = Nothing

canonicalProjectJson :: NormalizeInput -> [(String, Bool)] -> [LocalPackage] -> CabalProject -> Json
canonicalProjectJson input flags normalizedPackages cabalProject =
  Json.object
    [ ("compiler", Json.string (renderCompilerId (inputCompiler input)))
    , ("indexState", Json.string (renderIndexState (inputIndexState input)))
    , ( "cabalProjectPackages"
      , Json.stringArray (sortNub (projectPackages cabalProject ++ projectOptionalPackages cabalProject))
      )
    , ("sourceRepos", Json.array (map stringMapJson (projectSourceRepos cabalProject)))
    , ("localPackages", Json.array (map encodeLocalPackage normalizedPackages))
    , ("flags", boolMapJson flags)
    , ("materializationMode", Json.string (renderMaterializationMode (inputMaterializationMode input)))
    , ("granularity", Json.string (renderGranularity (inputGranularity input)))
    ]

planKeyJson :: ProjectKey -> Json
planKeyJson key =
  Json.object
    [("projectKey", Json.string (renderProjectKey key))]

digestJson :: Json -> Blake3Digest
digestJson = hash . Json.renderJson

sourceManifestJson :: SourceManifestEntry -> Json
sourceManifestJson entry =
  Json.object
    [ ("path", Json.string (sourcePath entry))
    , ("kind", Json.string (renderSourceKind (sourceKind entry)))
    , ("sha256", Json.string (sourceSha256 entry))
    ]

stringMapJson :: [(String, String)] -> Json
stringMapJson = Json.object . map (\(key, value) -> (key, Json.string value))

boolMapJson :: [(String, Bool)] -> Json
boolMapJson = Json.object . map (\(name, value) -> (name, Json.bool value)) . sort

conditionalOrImport :: String -> Bool
conditionalOrImport text =
  let value = lower (trim text)
   in "if " `isPrefixOf` value
        || value == "else"
        || "elif " `isPrefixOf` value
        || "import " `isPrefixOf` value

unsupportedConditional :: String -> LogicalLine -> Either String a
unsupportedConditional path line =
  Left
    ( path
        ++ ": line "
        ++ show (logicalNumber line)
        ++ ": Cabal conditionals and common-stanza imports must be resolved by repent before normalization: `"
        ++ logicalText line
        ++ "`"
    )

shouldSkipTopLevelStanza :: String -> Bool
shouldSkipTopLevelStanza text = lower (headWord text) `elem` ["flag", "common", "custom-setup", "source-repository"]

looksLikeUnsupportedStanza :: String -> Bool
looksLikeUnsupportedStanza text = lower (headWord text) == "foreign-library"

skipStanza :: [LogicalLine] -> [LogicalLine]
skipStanza [] = []
skipStanza (line : rest) = dropWhile ((> logicalIndent line) . logicalIndent) rest

splitModuleList :: Maybe String -> [String]
splitModuleList = sortNub . concatMap (map (trimCommas) . words) . splitTopLevelList

splitTopLevelList :: Maybe String -> [String]
splitTopLevelList Nothing = []
splitTopLevelList (Just value) = sortNub (splitTopLevelCommas value)

splitTopLevelCommas :: String -> [String]
splitTopLevelCommas = filter (not . null) . map trim . go 0 ""
  where
    go :: Int -> String -> String -> [String]
    go _ current [] = [reverse current]
    go depth current (ch : rest)
      | ch == '(' = go (depth + 1) (ch : current) rest
      | ch == ')' = go (depth - 1) (ch : current) rest
      | ch == ',' && depth == 0 = reverse current : go depth "" rest
      | otherwise = go depth (ch : current) rest

normalizePath :: String -> String
normalizePath path =
  case dropDotSlash (trim path) of
    "" -> "."
    normalized -> normalized
  where
    dropDotSlash value
      | "./" `isPrefixOf` value = dropDotSlash (drop 2 value)
      | otherwise = value

requiredTextField :: String -> String -> [(String, String)] -> Either String String
requiredTextField path field fields =
  maybe
    (Left (path ++ ": missing required top-level `" ++ field ++ ":` field"))
    Right
    (lookup field fields)

appendField :: String -> String -> [(String, String)] -> [(String, String)]
appendField name value fields =
  case lookup name fields of
    Nothing -> (name, value) : fields
    Just existing -> (name, joinNonEmpty existing value) : filter ((/= name) . fst) fields

joinNonEmpty :: String -> String -> String
joinNonEmpty left right
  | null left = right
  | null right = left
  | otherwise = left ++ "\n" ++ right

requiredParsed :: String -> (String -> Either String a) -> [(String, Json)] -> Either String a
requiredParsed name parser fields = do
  value <- requiredString name fields
  mapLeft (\err -> "input field `" ++ name ++ "`: " ++ err) (parser value)

require :: Bool -> String -> Either String ()
require True _ = Right ()
require False message = Left message

lower :: String -> String
lower = map toLower

headWord :: String -> String
headWord = fromMaybe "" . safeHead . words

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (value : _) = Just value

removeSuffix :: String -> String -> String
removeSuffix suffix value
  | reverse suffix `isPrefixOf` reverse value = reverse (drop (length suffix) (reverse value))
  | otherwise = value

splitOnce :: Char -> String -> Maybe (String, String)
splitOnce delimiter value =
  case break (== delimiter) value of
    (_, []) -> Nothing
    (left, _ : right) -> Just (left, right)

splitOn :: Char -> String -> [String]
splitOn delimiter value =
  case break (== delimiter) value of
    (part, []) -> [part]
    (part, _ : rest) -> part : splitOn delimiter rest

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f result =
  case result of
    Left value -> Left (f value)
    Right value -> Right value

runSelfTests :: Either String ()
runSelfTests = do
  assertEqual
    "BLAKE3 empty vector"
    "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
    (hashHex "")
  assertEqual
    "BLAKE3 abc vector"
    "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
    (hashHex "abc")
  first <- normalizeProjectWorker =<< parseNormalizeInput simpleInput
  second <- normalizeProjectWorker =<< parseNormalizeInput equivalentInput
  assertEqual "normalization determinism" first second
  parsed <- mapLeft ("self-test output JSON: " ++) (Json.parseJson first)
  fields <- asObject "self-test output" parsed
  packages <- requiredArray "localPackages" Right fields
  require (length packages == 1) "self-test expected one local package"
  where
    assertEqual label expected actual =
      require (expected == actual) (label ++ " failed: expected " ++ expected ++ ", got " ++ actual)

simpleInput :: String
simpleInput =
  Json.renderJson
    ( Json.object
        [ ("srcTreeDigest", Json.string ("blake3:" ++ replicate 64 'c'))
        , ("compiler", Json.string "test-compiler")
        , ("indexState", Json.string "2026-04-01T00:00:00Z")
        , ("cabalProjectText", Json.string "packages: .\n")
        , ( "localPackageManifests"
          , Json.array
              [ Json.object
                  [ ("path", Json.string "./.")
                  , ("cabalText", Json.string simpleCabal)
                  ]
              ]
          )
        , ( "flags"
          , Json.object
              [ ("Simple-Lib:DEV", Json.bool False)
              , ("simple-lib:bench", Json.bool True)
              ]
          )
        , ("materializationMode", Json.string "dynamic")
        , ("granularity", Json.string "component")
        ]
    )

equivalentInput :: String
equivalentInput =
  Json.renderJson
    ( Json.object
        [ ("granularity", Json.string "component")
        , ("materializationMode", Json.string "dynamic")
        , ( "flags"
          , Json.object
              [ ("simple-lib:bench", Json.bool True)
              , ("simple-lib:dev", Json.bool False)
              ]
          )
        , ( "localPackageManifests"
          , Json.array
              [ Json.object
                  [ ("cabalText", Json.string simpleCabal)
                  , ("path", Json.string ".")
                  ]
              ]
          )
        , ("cabalProjectText", Json.string "packages: .\n")
        , ("indexState", Json.string "2026-04-01T00:00:00Z")
        , ("compiler", Json.string "test-compiler")
        , ("srcTreeDigest", Json.string ("blake3:" ++ replicate 64 'c'))
        ]
    )

simpleCabal :: String
simpleCabal =
  unlines
    [ "cabal-version: 3.8"
    , "name: simple-lib"
    , "version: 0.1.0.0"
    , "build-type: Simple"
    , "license: NONE"
    , ""
    , "library"
    , "  exposed-modules: Simple"
    , "  hs-source-dirs: src"
    , "  build-depends: base >=4.20 && <5"
    , "  default-language: Haskell2010"
    ]
