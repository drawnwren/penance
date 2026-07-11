module Penance.Dyndrv
  ( emitBenchDyndrvFromArgs
  )
where

import Control.Monad (foldM)
import Data.Char (isAlphaNum, isLower, isSpace)
import Data.List (intercalate, isPrefixOf, isSuffixOf, sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Penance.Json (Json (..), array, object, renderJson, string)
import qualified Penance.Json as Json
import System.Directory (removeFile)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>), takeFileName)
import System.IO (hClose, hPutStr, openTempFile)
import System.Process (readProcessWithExitCode)

data EmitOptions = EmitOptions
  { optModulePlan :: Maybe FilePath
  , optSrcRoot :: Maybe FilePath
  , optOut :: Maybe FilePath
  , optSystem :: Maybe String
  , optNixBin :: Maybe FilePath
  , optBuilder :: Maybe FilePath
  , optPath :: Maybe String
  , optGhcFlags :: Maybe FilePath
  , optBinName :: Maybe String
  , optSmoke :: Maybe String
  , optPlaceholderOut :: Maybe String
  , optPlaceholderHi :: Maybe String
  , optPlaceholderO :: Maybe String
  , optToolDrvs :: [FilePath]
  }
  deriving (Eq, Show)

data RequiredOptions = RequiredOptions
  { reqModulePlan :: FilePath
  , reqSrcRoot :: FilePath
  , reqOut :: FilePath
  , reqSystem :: String
  , reqNixBin :: FilePath
  , reqBuilder :: FilePath
  , reqPath :: String
  , reqGhcFlags :: FilePath
  , reqBinName :: String
  , reqSmoke :: String
  , reqPlaceholderOut :: String
  , reqPlaceholderHi :: String
  , reqPlaceholderO :: String
  , reqToolDrvs :: [FilePath]
  }
  deriving (Eq, Show)

data PlannedModule = PlannedModule
  { pmSource :: FilePath
  , pmDeps :: [FilePath]
  , pmDb :: String
  , pmIsBoot :: Bool
  }
  deriving (Eq, Show)

data BuiltModule = BuiltModule
  { bmHiDrv :: FilePath
  , bmODrv :: FilePath
  , bmHiPlaceholder :: String
  , bmOPlaceholder :: String
  , bmIsBoot :: Bool
  }
  deriving (Eq, Show)

emitBenchDyndrvFromArgs :: [String] -> IO ()
emitBenchDyndrvFromArgs args = do
  options <- requireOptions (parseOptions emptyOptions args)
  modules <- readModulePlan (reqModulePlan options)
  flags <- filter (not . null) . lines <$> readFile (reqGhcFlags options)
  let dependencySet = Set.fromList (concatMap pmDeps modules)
      dynamicObjectSet =
        Set.fromList
          [ dep
          | modulePlan <- modules
          , pmDb modulePlan == "dbFull"
          , dep <- pmDeps modulePlan
          ]
  built <- foldM (emitModule options flags dependencySet dynamicObjectSet) Map.empty modules
  rootDrv <- emitAssemble options flags (Map.elems built)
  copyDrvText rootDrv (reqOut options)

emptyOptions :: EmitOptions
emptyOptions =
  EmitOptions
    { optModulePlan = Nothing
    , optSrcRoot = Nothing
    , optOut = Nothing
    , optSystem = Nothing
    , optNixBin = Nothing
    , optBuilder = Nothing
    , optPath = Nothing
    , optGhcFlags = Nothing
    , optBinName = Nothing
    , optSmoke = Nothing
    , optPlaceholderOut = Nothing
    , optPlaceholderHi = Nothing
    , optPlaceholderO = Nothing
    , optToolDrvs = []
    }

parseOptions :: EmitOptions -> [String] -> EmitOptions
parseOptions options args =
  case args of
    [] -> options
    "--module-plan" : value : rest -> parseOptions options {optModulePlan = Just value} rest
    "--src-root" : value : rest -> parseOptions options {optSrcRoot = Just value} rest
    "--out" : value : rest -> parseOptions options {optOut = Just value} rest
    "--system" : value : rest -> parseOptions options {optSystem = Just value} rest
    "--nix-bin" : value : rest -> parseOptions options {optNixBin = Just value} rest
    "--builder" : value : rest -> parseOptions options {optBuilder = Just value} rest
    "--path" : value : rest -> parseOptions options {optPath = Just value} rest
    "--ghc-flags" : value : rest -> parseOptions options {optGhcFlags = Just value} rest
    "--bin-name" : value : rest -> parseOptions options {optBinName = Just value} rest
    "--smoke" : value : rest -> parseOptions options {optSmoke = Just value} rest
    "--placeholder-out" : value : rest -> parseOptions options {optPlaceholderOut = Just value} rest
    "--placeholder-hi" : value : rest -> parseOptions options {optPlaceholderHi = Just value} rest
    "--placeholder-o" : value : rest -> parseOptions options {optPlaceholderO = Just value} rest
    "--tool-drv" : value : rest -> parseOptions options {optToolDrvs = optToolDrvs options ++ [value]} rest
    flag : _ -> error ("unknown emit-bench-dyndrv option: " ++ flag)

requireOptions :: EmitOptions -> IO RequiredOptions
requireOptions options = do
  modulePlan <- required "module-plan" (optModulePlan options)
  srcRoot <- required "src-root" (optSrcRoot options)
  out <- required "out" (optOut options)
  system <- required "system" (optSystem options)
  nixBin <- required "nix-bin" (optNixBin options)
  builder <- required "builder" (optBuilder options)
  path <- required "path" (optPath options)
  ghcFlags <- required "ghc-flags" (optGhcFlags options)
  binName <- required "bin-name" (optBinName options)
  smoke <- required "smoke" (optSmoke options)
  placeholderOut <- maybe (selfOutputPlaceholder nixBin "out") pure (optPlaceholderOut options)
  placeholderHi <- maybe (selfOutputPlaceholder nixBin "hi") pure (optPlaceholderHi options)
  placeholderO <- maybe (selfOutputPlaceholder nixBin "o") pure (optPlaceholderO options)
  pure
    RequiredOptions
      { reqModulePlan = modulePlan
      , reqSrcRoot = srcRoot
      , reqOut = out
      , reqSystem = system
      , reqNixBin = nixBin
      , reqBuilder = builder
      , reqPath = path
      , reqGhcFlags = ghcFlags
      , reqBinName = binName
      , reqSmoke = smoke
      , reqPlaceholderOut = placeholderOut
      , reqPlaceholderHi = placeholderHi
      , reqPlaceholderO = placeholderO
      , reqToolDrvs = optToolDrvs options
      }
  where
    required name =
      maybe (die ("missing required --" ++ name)) pure

readModulePlan :: FilePath -> IO [PlannedModule]
readModulePlan path = do
  contents <- readFile path
  case Json.parseJson contents >>= decodeModulePlan of
    Left err -> die ("failed to parse module plan " ++ path ++ ": " ++ err)
    Right modules -> pure modules

decodeModulePlan :: Json -> Either String [PlannedModule]
decodeModulePlan value = do
  fields <- asObject "module plan" value
  modules <- field "modules" fields >>= asArray "modules"
  traverse decodeModule modules

decodeModule :: Json -> Either String PlannedModule
decodeModule value = do
  fields <- asObject "module" value
  source <- field "source" fields >>= asString "module.source"
  deps <- field "deps" fields >>= stringArray "module.deps"
  db <- field "db" fields >>= asString "module.db"
  pure
    PlannedModule
      { pmSource = source
      , pmDeps = deps
      , pmDb = db
      , pmIsBoot = ".hs-boot" `isSuffixOf` source
      }

emitModule :: RequiredOptions -> [String] -> Set.Set FilePath -> Set.Set FilePath -> Map.Map FilePath BuiltModule -> PlannedModule -> IO (Map.Map FilePath BuiltModule)
emitModule options flags dependencySet dynamicObjectSet built modulePlan = do
  let sourcePath = reqSrcRoot options </> pmSource modulePlan
      moduleName = sanitizeName (pmSource modulePlan)
      ifaceName = "penance-dyndrv-iface-" ++ moduleName
      objectName = "penance-dyndrv-module-" ++ moduleName
      needsFull = pmDb modulePlan == "dbFull"
      needsIface = pmSource modulePlan `Set.member` dependencySet
      needsDynamicObject = needsFull || pmSource modulePlan `Set.member` dynamicObjectSet
  addedObjectSource <- runNix options ["store", "add-path", sourcePath]
  depModules <- traverse (lookupDep built (pmSource modulePlan)) (pmDeps modulePlan)
  let depHiPlaceholders = map bmHiPlaceholder depModules
      objectDepModules = filter (not . bmIsBoot) depModules
      depOPlaceholders = if needsFull then map bmOPlaceholder objectDepModules else []
      ifaceInputs =
        mergeInputs
          (toolInputs options ++ [(bmHiDrv dep, ["hi"]) | dep <- depModules])
      objectInputs =
        mergeInputs
          (toolInputs options ++ [(bmHiDrv dep, ["hi"]) | dep <- depModules] ++ [(bmODrv dep, ["o"]) | dep <- objectDepModules, needsFull])
      objectJson =
        derivationJson
          objectName
          (reqSystem options)
          (reqBuilder options)
          (objectArgs options flags modulePlan needsDynamicObject addedObjectSource depHiPlaceholders depOPlaceholders)
          ( moduleEnv
              options
              objectName
              [ ("o", reqPlaceholderO options)
              , ("src", addedObjectSource)
              ]
          )
          objectInputs
          [takeFileName addedObjectSource]
          (caOutputs ["o"])
  if pmIsBoot modulePlan
    then do
      let ifaceJson =
            derivationJson
              ifaceName
              (reqSystem options)
              (reqBuilder options)
              (bootIfaceArgs options flags modulePlan addedObjectSource depHiPlaceholders)
              ( moduleEnv
                  options
                  ifaceName
                  [ ("hi", reqPlaceholderHi options)
                  , ("src", addedObjectSource)
                  ]
              )
              ifaceInputs
              [takeFileName addedObjectSource]
              (caOutputs ["hi"])
      hiDrv <- addDerivation options ifaceJson
      hiPlaceholder <- downstreamPlaceholder options hiDrv "hi"
      pure
        ( Map.insert
            (pmSource modulePlan)
            BuiltModule
              { bmHiDrv = hiDrv
              , bmODrv = ""
              , bmHiPlaceholder = hiPlaceholder
              , bmOPlaceholder = ""
              , bmIsBoot = True
              }
            built
        )
    else do
      (hiDrv, hiPlaceholder) <-
        if needsIface
      then do
        sourceContents <- readFile sourcePath
        let ifaceSource = abiStubSource sourceContents
            ifaceJson =
              derivationJson
                ifaceName
                (reqSystem options)
                (reqBuilder options)
                (ifaceArgs options flags modulePlan ifaceSource depHiPlaceholders)
                ( moduleEnv
                    options
                    ifaceName
                    [ ("hi", reqPlaceholderHi options)
                    ]
                )
                ifaceInputs
                []
                (caOutputs ["hi"])
        drv <- addDerivation options ifaceJson
        placeholder <- downstreamPlaceholder options drv "hi"
        pure (drv, placeholder)
      else pure ("", "")
      oDrv <- addDerivation options objectJson
      oPlaceholder <- downstreamPlaceholder options oDrv "o"
      pure
        ( Map.insert
            (pmSource modulePlan)
            BuiltModule
              { bmHiDrv = hiDrv
              , bmODrv = oDrv
              , bmHiPlaceholder = hiPlaceholder
              , bmOPlaceholder = oPlaceholder
              , bmIsBoot = False
              }
            built
        )

lookupDep :: Map.Map FilePath BuiltModule -> FilePath -> FilePath -> IO BuiltModule
lookupDep built current dep =
  case Map.lookup dep built of
    Just value -> pure value
    Nothing -> die ("module plan is not topologically sorted: " ++ current ++ " depends on missing " ++ dep)

emitAssemble :: RequiredOptions -> [String] -> [BuiltModule] -> IO FilePath
emitAssemble options flags modules = do
  let name = "penance-bench-dyndrv-assemble"
      sortedModules = sortOnDrv (filter (not . bmIsBoot) modules)
      inputDrvs = mergeInputs (toolInputs options ++ [(bmODrv module_, ["o"]) | module_ <- sortedModules])
      outputPlaceholders = map bmOPlaceholder sortedModules
      json =
        derivationJson
          name
          (reqSystem options)
          (reqBuilder options)
          (assembleArgs options flags outputPlaceholders)
          ( moduleEnv
              options
              name
              [ ("out", reqPlaceholderOut options)
              ]
          )
          inputDrvs
          []
          (caOutputs ["out"])
  addDerivation options json

sortOnDrv :: [BuiltModule] -> [BuiltModule]
sortOnDrv =
  sortByKey bmODrv

ifaceArgs :: RequiredOptions -> [String] -> PlannedModule -> String -> [String] -> [String]
ifaceArgs options flags _modulePlan ifaceSource depHiPlaceholders =
  [ "-euc"
  , unlines
      [ "set -euo pipefail"
      , "export PATH=" ++ shellQuote (reqPath options)
      , bashArray "base_ghc_flags" flags
      , bashArray "dep_hi_dirs" depHiPlaceholders
      , "cat > \"$TMPDIR/iface-stub.hs\" <<'PENANCE_IFACE_STUB'"
      , ifaceSource
      , "PENANCE_IFACE_STUB"
      , "mkdir -p \"$hi\" iface-build"
      , "iface_flags=(\"${base_ghc_flags[@]}\" -odir iface-build -hidir iface-build -outputdir iface-build)"
      , "for dep_hi in \"${dep_hi_dirs[@]}\"; do"
      , "  cp -R \"$dep_hi\"/. iface-build/"
      , "  chmod -R u+w iface-build"
      , "  iface_flags+=(\"-i$dep_hi\")"
      , "done"
      , "chmod -R u+w iface-build"
      , "ghc \"${iface_flags[@]}\" -c \"$TMPDIR/iface-stub.hs\""
      , "while IFS= read -r artifact; do"
      , "  rel=\"${artifact#iface-build/}\""
      , "  mkdir -p \"$hi/$(dirname \"$rel\")\""
      , "  cp \"$artifact\" \"$hi/$rel\""
      , "done < <(find iface-build \\( -name '*.hi' -o -name '*.dyn_hi' \\) -type f | sort)"
      , "test -n \"$(find \"$hi\" -name '*.hi' -type f -print -quit)\""
      ]
  ]

bootIfaceArgs :: RequiredOptions -> [String] -> PlannedModule -> FilePath -> [String] -> [String]
bootIfaceArgs options flags modulePlan addedSource depHiPlaceholders =
  [ "-euc"
  , unlines
      [ "set -euo pipefail"
      , "export PATH=" ++ shellQuote (reqPath options)
      , bashArray "base_ghc_flags" flags
      , bashArray "dep_hi_dirs" depHiPlaceholders
      , "mkdir -p \"$hi\" boot-build"
      , "boot_flags=(\"${base_ghc_flags[@]}\" -odir boot-build -hidir boot-build -outputdir boot-build)"
      , "for dep_hi in \"${dep_hi_dirs[@]}\"; do"
      , "  cp -R \"$dep_hi\"/. boot-build/"
      , "  chmod -R u+w boot-build"
      , "  boot_flags+=(\"-i$dep_hi\")"
      , "done"
      , "chmod -R u+w boot-build"
      , "ghc \"${boot_flags[@]}\" -c \"$src\""
      , "while IFS= read -r artifact; do"
      , "  rel=\"${artifact#boot-build/}\""
      , "  mkdir -p \"$hi/$(dirname \"$rel\")\""
      , "  cp \"$artifact\" \"$hi/$rel\""
      , "done < <(find boot-build \\( -name '*.hi-boot' -o -name '*.dyn_hi-boot' \\) -type f | sort)"
      , "test -n \"$(find \"$hi\" -name '*.hi-boot' -type f -print -quit)\""
      , "echo " ++ shellQuote ("compiled penance-dyndrv-module " ++ pmSource modulePlan) ++ " >&2"
      ]
  ]
  where
    _ = addedSource

objectArgs :: RequiredOptions -> [String] -> PlannedModule -> Bool -> FilePath -> [String] -> [String] -> [String]
objectArgs options flags modulePlan needsDynamicObject addedSource depHiPlaceholders depOPlaceholders =
  [ "-euc"
  , unlines
      [ "set -euo pipefail"
      , "export PATH=" ++ shellQuote (reqPath options)
      , bashArray "base_ghc_flags" flags
      , bashArray "dep_hi_dirs" depHiPlaceholders
      , bashArray "dep_o_dirs" depOPlaceholders
      , "mkdir -p \"$o\" object-build"
      , "object_flags=(\"${base_ghc_flags[@]}\" -odir object-build -hidir object-build -outputdir object-build)"
      , "for dep_hi in \"${dep_hi_dirs[@]}\"; do"
      , "  cp -R \"$dep_hi\"/. object-build/"
      , "  chmod -R u+w object-build"
      , "  object_flags+=(\"-i$dep_hi\")"
      , "done"
      , "chmod -R u+w object-build"
      , "for dep_o in \"${dep_o_dirs[@]}\"; do"
      , "  cp -R \"$dep_o\"/. object-build/"
      , "  chmod -R u+w object-build"
      , "done"
      , "chmod -R u+w object-build"
      , "find object-build -type f | sort > \"$TMPDIR/staged-artifacts\""
      , if needsDynamicObject then "object_flags+=(\"-dynamic-too\")" else ":"
      , "ghc \"${object_flags[@]}\" -c \"$src\""
      , "while IFS= read -r artifact; do"
      , "  rel=\"${artifact#object-build/}\""
      , "  mkdir -p \"$o/$(dirname \"$rel\")\""
      , "  cp \"$artifact\" \"$o/$rel\""
      , "done < <(comm -13 \"$TMPDIR/staged-artifacts\" <(find object-build \\( -name '*.o' -o -name '*.dyn_o' -o -name '*.dyn_hi' \\) -type f | sort))"
      , "test -n \"$(find \"$o\" -name '*.o' -type f -print -quit)\""
      , "echo " ++ shellQuote ("compiled penance-dyndrv-module " ++ pmSource modulePlan) ++ " >&2"
      ]
  ]
  where
    _ = addedSource

abiStubSource :: String -> String
abiStubSource =
  unlines . go Nothing . lines
  where
    go _ [] = []
    go pending (line : rest)
      | Just name <- pending
      , shouldSkipBodyLine name line =
          go pending rest
      | Just name <- signatureName line =
          line : (name ++ " = error \"penance iface stub\"") : go (Just name) rest
      | otherwise =
          line : go Nothing rest

shouldSkipBodyLine :: String -> String -> Bool
shouldSkipBodyLine name line =
  all isSpace line
    || beginsWithSpace line
    || beginsWithName name line

beginsWithSpace :: String -> Bool
beginsWithSpace [] = False
beginsWithSpace (ch : _) = isSpace ch

beginsWithName :: String -> String -> Bool
beginsWithName name line =
  name `isPrefixOf` line
    && case drop (length name) line of
      [] -> True
      ch : _ -> not (isIdentifierChar ch)

signatureName :: String -> Maybe String
signatureName line =
  case line of
    ch : _
      | isLower ch || ch == '_' ->
          let (name, rest) = span isIdentifierChar line
           in if "::" `isPrefixOf` dropWhile isSpace rest
                then Just name
                else Nothing
    _ -> Nothing

isIdentifierChar :: Char -> Bool
isIdentifierChar ch =
  isAlphaNum ch || ch == '_' || ch == '\''

assembleArgs :: RequiredOptions -> [String] -> [String] -> [String]
assembleArgs options flags moduleOPlaceholders =
  [ "-euc"
  , unlines
      [ "set -euo pipefail"
      , "export PATH=" ++ shellQuote (reqPath options)
      , bashArray "ghc_flags" flags
      , bashArray "module_o_dirs" moduleOPlaceholders
      , "mkdir -p \"$out/bin\""
      , ": > \"$TMPDIR/objects\""
      , "for module_o in \"${module_o_dirs[@]}\"; do"
      , "  find \"$module_o\" -name '*.o' ! -name '*.dyn_o' -type f"
      , "done | sort > \"$TMPDIR/objects\""
      , "test -s \"$TMPDIR/objects\""
      , "ghc \"${ghc_flags[@]}\" $(cat \"$TMPDIR/objects\") -o \"$out/bin/" ++ reqBinName options ++ "\""
      , "\"$out/bin/" ++ reqBinName options ++ "\" > \"$out/output.txt\""
      , "grep -q " ++ shellQuote (reqSmoke options) ++ " \"$out/output.txt\""
      , "echo " ++ shellQuote "assembled penance-bench-dyndrv" ++ " >&2"
      ]
  ]

moduleEnv :: RequiredOptions -> String -> [(String, String)] -> [(String, Json)]
moduleEnv options name extras =
  [ ("builder", string (reqBuilder options))
  , ("name", string name)
  , ("system", string (reqSystem options))
  , ("PATH", string (reqPath options))
  ]
    ++ [(key, string value) | (key, value) <- extras]

derivationJson ::
  String ->
  String ->
  FilePath ->
  [String] ->
  [(String, Json)] ->
  Map.Map FilePath [String] ->
  [String] ->
  [(String, Json)] ->
  Json
derivationJson name system builder args env inputDrvs inputSrcs outputs =
  object
    [ ("name", string name)
    , ("system", string system)
    , ("builder", string builder)
    , ("args", array (map string args))
    , ("env", object env)
    , ( "inputs"
      , object
          [ ("drvs", inputDrvsJson inputDrvs)
          , ("srcs", array (map string (sort inputSrcs)))
          ]
      )
    , ("outputs", object outputs)
    , ("version", JsonNumber "4")
    ]

inputDrvsJson :: Map.Map FilePath [String] -> Json
inputDrvsJson inputDrvs =
  object
    [ ( takeFileName drv
      , object
          [ ("dynamicOutputs", object [])
          , ("outputs", array (map string outputs))
          ]
      )
    | (drv, outputs) <- Map.toAscList inputDrvs
    ]

caOutputs :: [String] -> [(String, Json)]
caOutputs outputs =
  [ ( output
    , object
        [ ("method", string "nar")
        , ("hashAlgo", string "sha256")
        ]
    )
  | output <- outputs
  ]

toolInputs :: RequiredOptions -> [(FilePath, [String])]
toolInputs options =
  [(drv, ["out"]) | drv <- reqToolDrvs options]

mergeInputs :: [(FilePath, [String])] -> Map.Map FilePath [String]
mergeInputs =
  Map.map Set.toAscList . foldr insertOne Map.empty
  where
    insertOne (drv, outputs) =
      Map.insertWith Set.union drv (Set.fromList outputs)

addDerivation :: RequiredOptions -> Json -> IO FilePath
addDerivation options json = do
  let text = renderJson json ++ "\n"
  withTempText "penance-dyndrv-child.json" text $ \path ->
    runNix options ["derivation", "add", "<", path]

copyDrvText :: FilePath -> FilePath -> IO ()
copyDrvText drv out = do
  contents <- readFile drv
  writeFile out contents

downstreamPlaceholder :: RequiredOptions -> FilePath -> String -> IO String
downstreamPlaceholder options drv output = do
  (hashPart, drvName) <- parseDrvStorePath drv
  let pathName =
        if output == "out" then drvName else drvName ++ "-" ++ output
      clearText =
        "nix-upstream-output:" ++ hashPart ++ ":" ++ pathName
  ("/" ++) <$> nixBase32Sha256 options clearText

parseDrvStorePath :: FilePath -> IO (String, String)
parseDrvStorePath path =
  case break (== '-') (takeFileName path) of
    (hashPart, '-' : rest)
      | ".drv" `isSuffixOf` rest ->
          pure (hashPart, dropSuffix ".drv" rest)
    _ ->
      die ("expected a /nix/store hash-name.drv path, got: " ++ path)

nixBase32Sha256 :: RequiredOptions -> String -> IO String
nixBase32Sha256 options text =
  nixBase32Sha256WithNix (reqNixBin options) text

selfOutputPlaceholder :: FilePath -> String -> IO String
selfOutputPlaceholder nixBin output =
  ("/" ++) <$> nixBase32Sha256WithNix nixBin ("nix-output:" ++ output)

nixBase32Sha256WithNix :: FilePath -> String -> IO String
nixBase32Sha256WithNix nixBin text =
  withTempText "penance-placeholder-input" text $ \path ->
    runCommandTrim nixBin ["hash", "file", "--type", "sha256", "--base32", path] ""

runNix :: RequiredOptions -> [String] -> IO String
runNix options args = do
  let nixBin = reqNixBin options
  runCommandTrim nixBin args ""

runCommandTrim :: FilePath -> [String] -> String -> IO String
runCommandTrim command args stdinText = do
  (exitCode, stdoutText, stderrText) <-
    case args of
      ["derivation", "add", "<", path] ->
        readProcessWithExitCode command ["derivation", "add"] =<< readFile path
      _ ->
        readProcessWithExitCode command args stdinText
  case exitCode of
    ExitSuccess -> pure (trim stdoutText)
    ExitFailure code ->
      die
        ( intercalate
            "\n"
            [ "command failed with exit " ++ show code ++ ": " ++ unwords (command : args)
            , stderrText
            ]
        )

withTempText :: FilePath -> String -> (FilePath -> IO a) -> IO a
withTempText template contents action = do
  (path, handle) <- openTempFile "." template
  hPutStr handle contents
  hClose handle
  result <- action path
  removeFile path
  pure result

field :: String -> [(String, Json)] -> Either String Json
field name fields =
  case lookup name fields of
    Just value -> Right value
    Nothing -> Left ("missing required JSON field `" ++ name ++ "`")

asObject :: String -> Json -> Either String [(String, Json)]
asObject _ (JsonObject fields) = Right fields
asObject context other = Left ("expected object for " ++ context ++ ", got " ++ show other)

asArray :: String -> Json -> Either String [Json]
asArray _ (JsonArray values) = Right values
asArray context other = Left ("expected array for " ++ context ++ ", got " ++ show other)

asString :: String -> Json -> Either String String
asString _ (JsonString value) = Right value
asString context other = Left ("expected string for " ++ context ++ ", got " ++ show other)

stringArray :: String -> Json -> Either String [String]
stringArray context value =
  asArray context value >>= traverse (asString context)

bashArray :: String -> [String] -> String
bashArray name values =
  name ++ "=(\n" ++ concatMap (\value -> "  " ++ shellQuote value ++ "\n") values ++ ")"

shellQuote :: String -> String
shellQuote value =
  "'" ++ concatMap quoteChar value ++ "'"
  where
    quoteChar '\'' = "'\\''"
    quoteChar ch = [ch]

sanitizeName :: String -> String
sanitizeName =
  map sanitizeChar
  where
    sanitizeChar ch
      | ch >= 'A' && ch <= 'Z' = ch
      | ch >= 'a' && ch <= 'z' = ch
      | ch >= '0' && ch <= '9' = ch
      | otherwise = '-'

sortByKey :: Ord key => (a -> key) -> [a] -> [a]
sortByKey =
  sortOn

dropSuffix :: String -> String -> String
dropSuffix suffix value
  | suffix `isSuffixOf` value = take (length value - length suffix) value
  | otherwise = value

trim :: String -> String
trim =
  dropWhileEnd isSpaceLike . dropWhile isSpaceLike

dropWhileEnd :: (a -> Bool) -> [a] -> [a]
dropWhileEnd predicate =
  reverse . dropWhile predicate . reverse

isSpaceLike :: Char -> Bool
isSpaceLike ch =
  ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t'
