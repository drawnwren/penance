module Penance.WasmPlanner
  ( normalizeProject
  , runSelfTests
  )
where

import Data.Char (isHexDigit, isSpace, toLower)
import Data.List (intercalate, isPrefixOf, nub, sort, sortBy)
import Data.Maybe (fromMaybe, mapMaybe)
import Penance.Blake3 (hashHex)
import Penance.Json (Json (..))
import qualified Penance.Json as Json

data NormalizeInput = NormalizeInput
  { inputSrcTreeDigest :: Maybe String
  , inputSourceManifest :: [SourceManifestEntry]
  , inputCompiler :: String
  , inputIndexState :: String
  , inputCabalProjectText :: String
  , inputLocalPackageManifests :: [LocalPackageManifest]
  , inputFlags :: [(String, Bool)]
  , inputMaterializationMode :: String
  , inputGranularity :: String
  }
  deriving (Eq, Show)

data SourceManifestEntry = SourceManifestEntry
  { sourcePath :: String
  , sourceKind :: String
  , sourceSha256 :: String
  }
  deriving (Eq, Ord, Show)

data LocalPackageManifest = LocalPackageManifest
  { manifestPath :: String
  , manifestCabalText :: String
  }
  deriving (Eq, Ord, Show)

data CabalProject = CabalProject
  { projectPackages :: [String]
  , projectSourceRepos :: [[(String, String)]]
  }
  deriving (Eq, Show)

data ComponentKind = Library | Executable | TestSuite | Benchmark
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

data LocalComponent = LocalComponent
  { localComponentId :: String
  , localComponentKind :: String
  , localProvidedModules :: [String]
  , localSignatures :: [String]
  , localRequiredSignatures :: [String]
  , localMixins :: [String]
  , localReexportedModules :: [String]
  }
  deriving (Eq, Ord, Show)

data LocalPackage = LocalPackage
  { localPackageName :: String
  , localPackageVersion :: String
  , localPackageComponents :: [String]
  , localComponentDetails :: [LocalComponent]
  , localPackageSignatures :: [String]
  , localPackageRequiredSignatures :: [String]
  , localPackageProvidedModules :: [String]
  }
  deriving (Eq, Ord, Show)

data IndefiniteUnit = IndefiniteUnit
  { indefiniteUnit :: String
  , indefinitePackage :: String
  , indefiniteComponent :: String
  , indefiniteSignatures :: [String]
  , indefiniteRequiredSignatures :: [String]
  , indefiniteMixins :: [String]
  , indefiniteReexportedModules :: [String]
  }
  deriving (Eq, Ord, Show)

data ExpectedInstantiation = ExpectedInstantiation
  { instantiationUnit :: String
  , instantiationHoles :: [(String, String)]
  }
  deriving (Eq, Ord, Show)

data LogicalLine = LogicalLine
  { logicalNumber :: Int
  , logicalIndent :: Int
  , logicalText :: String
  }
  deriving (Eq, Show)

data StanzaHeader = StanzaHeader
  { stanzaKind :: ComponentKind
  , stanzaName :: Maybe String
  }
  deriving (Eq, Show)

normalizeProject :: String -> Either String String
normalizeProject inputText = parseNormalizeInput inputText >>= normalizeProjectWorker

normalizeProjectWorker :: NormalizeInput -> Either String String
normalizeProjectWorker input = do
  sourceDigest <- resolveSourceDigest input
  require
    ("blake3:" `isPrefixOf` sourceDigest)
    ("srcTreeDigest must be a blake3 digest, got `" ++ sourceDigest ++ "`")
  require
    (inputMaterializationMode input == "dynamic")
    ( "unsupported materializationMode `"
        ++ inputMaterializationMode input
        ++ "`; expected `dynamic`"
    )
  require
    (inputGranularity input `elem` ["component", "module"])
    ( "unsupported granularity `"
        ++ inputGranularity input
        ++ "`; expected `component` or `module`"
    )
  cabalProject <- parseCabalProject (inputCabalProjectText input)
  cabalPackages <- mapM parseManifest manifests
  let localPackages = sortBy comparePackage (map localPackageFromCabal cabalPackages)
      indefiniteUnits = sort (concatMap indefiniteUnitsFromPackage cabalPackages)
      expectedInstantiations = sort (concatMap instantiationsFromPackage cabalPackages)
      projectKey =
        digestJson
          (canonicalProjectJson input sourceDigest flags manifests localPackages cabalProject)
      planCacheKey =
        digestJson
          ( planKeyJson
              projectKey
              (inputCompiler input)
              (inputIndexState input)
              (inputGranularity input)
              flags
              localPackages
          )
  pure
    ( Json.renderJson
        ( Json.object
            [ ("projectKey", Json.string projectKey)
            , ("localPackages", Json.array (map localPackageJson localPackages))
            , ("sourceRepos", Json.array (map stringMapJson (projectSourceRepos cabalProject)))
            , ("planCacheKey", Json.string planCacheKey)
            , ("plannerDrvInputs", Json.array [])
            , ("granularity", Json.string (inputGranularity input))
            , ( "backpack"
              , Json.object
                  [ ("indefiniteUnits", Json.array (map indefiniteUnitJson indefiniteUnits))
                  , ("expectedInstantiations", Json.array (map expectedInstantiationJson expectedInstantiations))
                  ]
              )
            , ( "expectedOutputs"
              , Json.object
                  [ ("componentGraphDrv", Json.bool True)
                  , ("moduleGraphDrv", Json.bool True)
                  , ("backpackGraphDrv", Json.bool True)
                  ]
              )
            ]
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
    (localPackageName left, localPackageVersion left, localPackageComponents left)
    (localPackageName right, localPackageVersion right, localPackageComponents right)

parseNormalizeInput :: String -> Either String NormalizeInput
parseNormalizeInput text = do
  value <- mapLeft ("invalid input JSON: " ++) (Json.parseJson text)
  fields <- expectObject "input" value
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
    <*> requiredString "compiler" fields
    <*> requiredString "indexState" fields
    <*> requiredString "cabalProjectText" fields
    <*> requiredArray "localPackageManifests" parseLocalPackageManifest fields
    <*> optionalBoolMap "flags" fields
    <*> requiredString "materializationMode" fields
    <*> requiredString "granularity" fields

parseSourceManifestEntry :: Json -> Either String SourceManifestEntry
parseSourceManifestEntry value = do
  fields <- expectObject "sourceManifest entry" value
  rejectUnknown "sourceManifest entry" ["path", "kind", "sha256"] fields
  SourceManifestEntry
    <$> requiredString "path" fields
    <*> requiredString "kind" fields
    <*> requiredString "sha256" fields

parseLocalPackageManifest :: Json -> Either String LocalPackageManifest
parseLocalPackageManifest value = do
  fields <- expectObject "localPackageManifest" value
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
      let computed = digestJson (Json.array (map sourceManifestJson normalized))
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
        (sourceKind entry == "regular")
        ( "source manifest only supports regular files, got `"
            ++ sourceKind entry
            ++ "` at `"
            ++ path
            ++ "`"
        )
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
normalizeFlags = sort . map (\(name, enabled) -> (map toLower (trim name), enabled))

parseCabalProject :: String -> Either String CabalProject
parseCabalProject text = go (logicalLines text) [] []
  where
    go [] packages repos = Right (CabalProject (sortNub packages) (sort repos))
    go allLines@(line : rest) packages repos
      | logicalIndent line /= 0 = malformed line
      | logicalText line == "source-repository-package" = do
          (repo, remaining) <- parseSourceRepo rest []
          go remaining packages (sort repo : repos)
      | otherwise = do
          (field, firstValue) <- splitField line
          let (value, remaining) = collectContinuation (logicalIndent line) firstValue rest
          case field of
            "packages" -> go remaining (splitWords value ++ packages) repos
            "optional-packages" -> go remaining (splitWords value ++ packages) repos
            _
              | field `elem` ignoredProjectFields -> go remaining packages repos
              | otherwise ->
                  Left
                    ( "cabal.project line "
                        ++ show (logicalNumber line)
                        ++ ": unsupported cabal.project construct `"
                        ++ field
                        ++ "`"
                    )
      where
        malformed bad =
          Left
            ( "cabal.project line "
                ++ show (logicalNumber bad)
                ++ ": expected `key: value`, got `"
                ++ logicalText bad
                ++ "`"
            )
    parseSourceRepo allLines fields =
      case allLines of
        [] -> Right (fields, [])
        line : rest
          | logicalIndent line == 0 -> Right (fields, allLines)
          | otherwise -> do
              (field, firstValue) <- splitField line
              let (value, remaining) = collectContinuation (logicalIndent line) firstValue rest
              parseSourceRepo remaining (insertField field value fields)

ignoredProjectFields :: [String]
ignoredProjectFields =
  [ "constraints"
  , "allow-newer"
  , "allow-older"
  , "with-compiler"
  , "index-state"
  , "repository"
  , "remote-repo-cache"
  , "jobs"
  ]

parseCabalFile :: String -> String -> Either String CabalPackage
parseCabalFile path text = go (logicalLines text) [] []
  where
    go [] topFields components = finish topFields components
    go allLines@(line : rest) topFields components
      | conditionalOrImport (logicalText line) = go rest topFields components
      | logicalIndent line /= 0 = malformed line
      | Just header <- parseStanzaHeader (logicalText line) = do
          (component, remaining) <- parseComponent path header rest []
          go remaining topFields (component : components)
      | shouldSkipTopLevelStanza (logicalText line) =
          go (skipStanza allLines) topFields components
      | looksLikeUnsupportedStanza (logicalText line) = unsupported line
      | otherwise = do
          (field, firstValue) <- splitField line
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
      | conditionalOrImport (logicalText line) -> parseComponent path header rest fields
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
          (field, firstValue) <- splitField line
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
                     | stanzaKind header `elem` [Executable, TestSuite, Benchmark]
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
      | lower kind == "library" -> Just (StanzaHeader Library Nothing)
    [kind, name] ->
      case lower kind of
        "library" -> Just (StanzaHeader Library (Just name))
        "executable" -> Just (StanzaHeader Executable (Just name))
        "test-suite" -> Just (StanzaHeader TestSuite (Just name))
        "benchmark" -> Just (StanzaHeader Benchmark (Just name))
        _ -> Nothing
    _ -> Nothing

componentId :: StanzaHeader -> String
componentId header =
  case (stanzaKind header, stanzaName header) of
    (Library, Nothing) -> "lib"
    (Library, Just name) -> "lib:" ++ name
    (Executable, Just name) -> "exe:" ++ name
    (TestSuite, Just name) -> "test:" ++ name
    (Benchmark, Just name) -> "bench:" ++ name
    _ -> "unknown"

localPackageFromCabal :: CabalPackage -> LocalPackage
localPackageFromCabal package =
  LocalPackage
    { localPackageName = cabalPackageName package
    , localPackageVersion = cabalPackageVersion package
    , localPackageComponents = sortNub (map cabalComponentId components)
    , localComponentDetails = sort (map localComponentFromCabal components)
    , localPackageSignatures = sortNub (concatMap cabalSignatures components)
    , localPackageRequiredSignatures = sortNub (concatMap cabalRequiredSignatures components)
    , localPackageProvidedModules = sortNub (concatMap cabalProvidedModules components)
    }
  where
    components = cabalPackageComponents package

localComponentFromCabal :: CabalComponent -> LocalComponent
localComponentFromCabal component =
  LocalComponent
    { localComponentId = cabalComponentId component
    , localComponentKind = componentKindName (cabalComponentKind component)
    , localProvidedModules = cabalProvidedModules component
    , localSignatures = cabalSignatures component
    , localRequiredSignatures = cabalRequiredSignatures component
    , localMixins = cabalMixins component
    , localReexportedModules = cabalReexportedModules component
    }

indefiniteUnitsFromPackage :: CabalPackage -> [IndefiniteUnit]
indefiniteUnitsFromPackage package =
  [ IndefiniteUnit
      { indefiniteUnit = cabalPackageName package ++ ":" ++ cabalComponentId component
      , indefinitePackage = cabalPackageName package
      , indefiniteComponent = cabalComponentId component
      , indefiniteSignatures = cabalSignatures component
      , indefiniteRequiredSignatures = cabalRequiredSignatures component
      , indefiniteMixins = cabalMixins component
      , indefiniteReexportedModules = cabalReexportedModules component
      }
  | component <- cabalPackageComponents package
  , not (null (cabalRequiredSignatures component))
  ]

instantiationsFromPackage :: CabalPackage -> [ExpectedInstantiation]
instantiationsFromPackage package =
  concatMap fromComponent (cabalPackageComponents package)
  where
    fromComponent component =
      [ ExpectedInstantiation
          { instantiationUnit = cabalPackageName package ++ ":" ++ cabalComponentId component
          , instantiationHoles = holes
          }
      | mixin <- cabalMixins component
      , Just holes <- [holesFromMixin mixin]
      , not (null holes)
      ]

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

canonicalProjectJson :: NormalizeInput -> String -> [(String, Bool)] -> [LocalPackageManifest] -> [LocalPackage] -> CabalProject -> Json
canonicalProjectJson input sourceDigest flags manifests localPackages cabalProject =
  Json.object
    [ ("srcTreeDigest", Json.string sourceDigest)
    , ("compiler", Json.string (inputCompiler input))
    , ("indexState", Json.string (inputIndexState input))
    , ("cabalProjectText", Json.string (inputCabalProjectText input))
    , ("cabalProjectPackages", stringArray (projectPackages cabalProject))
    , ("localPackageManifests", Json.array (map localPackageManifestJson manifests))
    , ("localPackages", Json.array (map localPackageJson localPackages))
    , ("flags", boolMapJson flags)
    , ("materializationMode", Json.string (inputMaterializationMode input))
    , ("granularity", Json.string (inputGranularity input))
    ]

planKeyJson :: String -> String -> String -> String -> [(String, Bool)] -> [LocalPackage] -> Json
planKeyJson projectKey compiler indexState granularity flags localPackages =
  Json.object
    [ ("projectKey", Json.string projectKey)
    , ("compiler", Json.string compiler)
    , ("indexState", Json.string indexState)
    , ("granularity", Json.string granularity)
    , ("flags", boolMapJson flags)
    , ("localPackages", Json.array (map localPackageJson localPackages))
    ]

digestJson :: Json -> String
digestJson = ("blake3:" ++) . hashHex . Json.renderJson

sourceManifestJson :: SourceManifestEntry -> Json
sourceManifestJson entry =
  Json.object
    [ ("path", Json.string (sourcePath entry))
    , ("kind", Json.string (sourceKind entry))
    , ("sha256", Json.string (sourceSha256 entry))
    ]

localPackageManifestJson :: LocalPackageManifest -> Json
localPackageManifestJson manifest =
  Json.object
    [ ("path", Json.string (manifestPath manifest))
    , ("cabalText", Json.string (manifestCabalText manifest))
    ]

localPackageJson :: LocalPackage -> Json
localPackageJson package =
  Json.object
    [ ("name", Json.string (localPackageName package))
    , ("version", Json.string (localPackageVersion package))
    , ("components", stringArray (localPackageComponents package))
    , ("componentDetails", Json.array (map localComponentJson (localComponentDetails package)))
    , ("signatures", stringArray (localPackageSignatures package))
    , ("requiredSignatures", stringArray (localPackageRequiredSignatures package))
    , ("providedModules", stringArray (localPackageProvidedModules package))
    ]

localComponentJson :: LocalComponent -> Json
localComponentJson component =
  Json.object
    [ ("component", Json.string (localComponentId component))
    , ("kind", Json.string (localComponentKind component))
    , ("providedModules", stringArray (localProvidedModules component))
    , ("signatures", stringArray (localSignatures component))
    , ("requiredSignatures", stringArray (localRequiredSignatures component))
    , ("mixins", stringArray (localMixins component))
    , ("reexportedModules", stringArray (localReexportedModules component))
    ]

indefiniteUnitJson :: IndefiniteUnit -> Json
indefiniteUnitJson unit =
  Json.object
    [ ("unit", Json.string (indefiniteUnit unit))
    , ("package", Json.string (indefinitePackage unit))
    , ("component", Json.string (indefiniteComponent unit))
    , ("signatures", stringArray (indefiniteSignatures unit))
    , ("requiredSignatures", stringArray (indefiniteRequiredSignatures unit))
    , ("mixins", stringArray (indefiniteMixins unit))
    , ("reexportedModules", stringArray (indefiniteReexportedModules unit))
    ]

expectedInstantiationJson :: ExpectedInstantiation -> Json
expectedInstantiationJson instantiation =
  Json.object
    [ ("unit", Json.string (instantiationUnit instantiation))
    , ("holes", stringMapJson (instantiationHoles instantiation))
    ]

stringArray :: [String] -> Json
stringArray = Json.array . map Json.string

stringMapJson :: [(String, String)] -> Json
stringMapJson = Json.object . map (\(name, value) -> (name, Json.string value)) . sort

boolMapJson :: [(String, Bool)] -> Json
boolMapJson = Json.object . map (\(name, value) -> (name, Json.bool value)) . sort

componentKindName :: ComponentKind -> String
componentKindName kind =
  case kind of
    Library -> "library"
    Executable -> "executable"
    TestSuite -> "test-suite"
    Benchmark -> "benchmark"

logicalLines :: String -> [LogicalLine]
logicalLines text =
  [ LogicalLine number (length (takeWhile isSpace uncommented)) (trim uncommented)
  | (number, raw) <- zip [1 ..] (lines text)
  , let uncommented = stripComment raw
  , not (null (trim uncommented))
  ]

stripComment :: String -> String
stripComment text = maybe text fst (splitSubstring "--" text)

splitField :: LogicalLine -> Either String (String, String)
splitField line =
  case splitOnce ':' (logicalText line) of
    Just (field, value) -> Right (trim field, trim value)
    Nothing ->
      Left
        ( "line "
            ++ show (logicalNumber line)
            ++ ": expected `key: value`, got `"
            ++ logicalText line
            ++ "`"
        )

collectContinuation :: Int -> String -> [LogicalLine] -> (String, [LogicalLine])
collectContinuation fieldIndent firstValue allLines =
  let (continuation, remaining) = span ((> fieldIndent) . logicalIndent) allLines
      values = filter (not . null) (trim firstValue : map (trim . logicalText) continuation)
   in (intercalate "\n" values, remaining)

conditionalOrImport :: String -> Bool
conditionalOrImport text =
  let value = lower (trim text)
   in "if " `isPrefixOf` value
        || value == "else"
        || "elif " `isPrefixOf` value
        || "import " `isPrefixOf` value

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
    go _ current [] = [reverse current]
    go depth current (ch : rest)
      | ch == '(' = go (depth + 1) (ch : current) rest
      | ch == ')' = go (depth - 1) (ch : current) rest
      | ch == ',' && depth == 0 = reverse current : go depth "" rest
      | otherwise = go depth (ch : current) rest

splitWords :: String -> [String]
splitWords = filter (not . null) . map trimCommas . words

trimCommas :: String -> String
trimCommas = dropWhile (== ',') . reverse . dropWhile (== ',') . reverse

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

insertField :: String -> String -> [(String, String)] -> [(String, String)]
insertField name value fields = (name, value) : filter ((/= name) . fst) fields

joinNonEmpty :: String -> String -> String
joinNonEmpty left right
  | null left = right
  | null right = left
  | otherwise = left ++ "\n" ++ right

expectObject :: String -> Json -> Either String [(String, Json)]
expectObject _ (JsonObject fields) = Right fields
expectObject context _ = Left (context ++ " must be a JSON object")

requiredString :: String -> [(String, Json)] -> Either String String
requiredString name fields =
  case lookup name fields of
    Just (JsonString value) -> Right value
    Just _ -> Left ("input field `" ++ name ++ "` must be a string")
    Nothing -> Left ("input is missing required field `" ++ name ++ "`")

optionalString :: String -> [(String, Json)] -> Either String (Maybe String)
optionalString name fields =
  case lookup name fields of
    Nothing -> Right Nothing
    Just JsonNull -> Right Nothing
    Just (JsonString value) -> Right (Just value)
    Just _ -> Left ("input field `" ++ name ++ "` must be a string or null")

requiredArray :: String -> (Json -> Either String a) -> [(String, Json)] -> Either String [a]
requiredArray name parser fields =
  case lookup name fields of
    Just (JsonArray values) -> mapM parser values
    Just _ -> Left ("input field `" ++ name ++ "` must be an array")
    Nothing -> Left ("input is missing required field `" ++ name ++ "`")

optionalArray :: String -> (Json -> Either String a) -> [(String, Json)] -> Either String [a]
optionalArray name parser fields =
  case lookup name fields of
    Nothing -> Right []
    Just (JsonArray values) -> mapM parser values
    Just _ -> Left ("input field `" ++ name ++ "` must be an array")

optionalBoolMap :: String -> [(String, Json)] -> Either String [(String, Bool)]
optionalBoolMap name fields =
  case lookup name fields of
    Nothing -> Right []
    Just (JsonObject values) -> mapM parseBool values
    Just _ -> Left ("input field `" ++ name ++ "` must be an object")
  where
    parseBool (key, JsonBool value) = Right (key, value)
    parseBool (key, _) = Left ("input flag `" ++ key ++ "` must be a boolean")

rejectUnknown :: String -> [String] -> [(String, Json)] -> Either String ()
rejectUnknown context allowed fields =
  case [name | (name, _) <- fields, name `notElem` allowed] of
    name : _ -> Left (context ++ " contains unknown field `" ++ name ++ "`")
    [] -> Right ()

require :: Bool -> String -> Either String ()
require True _ = Right ()
require False message = Left message

sortNub :: Ord a => [a] -> [a]
sortNub = nub . sort

lower :: String -> String
lower = map toLower

headWord :: String -> String
headWord = fromMaybe "" . safeHead . words

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (value : _) = Just value

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

removeSuffix :: String -> String -> String
removeSuffix suffix value
  | reverse suffix `isPrefixOf` reverse value = reverse (drop (length suffix) (reverse value))
  | otherwise = value

splitOnce :: Char -> String -> Maybe (String, String)
splitOnce delimiter value =
  case break (== delimiter) value of
    (_, []) -> Nothing
    (left, _ : right) -> Just (left, right)

splitSubstring :: String -> String -> Maybe (String, String)
splitSubstring needle = go ""
  where
    go _ [] = Nothing
    go prefix rest
      | needle `isPrefixOf` rest = Just (reverse prefix, drop (length needle) rest)
      | ch : remaining <- rest = go (ch : prefix) remaining
      | otherwise = Nothing

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
  fields <- expectObject "self-test output" parsed
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
        , ("compiler", Json.string "ghc-9.10.2")
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
        , ("compiler", Json.string "ghc-9.10.2")
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
    , "license: MIT"
    , ""
    , "library"
    , "  exposed-modules: Simple"
    , "  hs-source-dirs: src"
    , "  build-depends: base >=4.18 && <5"
    , "  default-language: Haskell2010"
    ]
