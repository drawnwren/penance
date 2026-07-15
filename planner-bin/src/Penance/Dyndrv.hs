module Penance.Dyndrv
  ( emitBenchDyndrvFromArgs
  , DrvPath
  , StorePath
  , DerivationSpec (..)
  , derivationJson
  , mergeInputs
  , parseDrvPath
  , parseStorePath
  , renderDrvPath
  , renderStorePath
  , downstreamPlaceholderClearText
  )
where

import Control.Monad (foldM)
import Data.List (dropWhileEnd, intercalate, isPrefixOf, isSuffixOf, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Penance.Error
  ( throwArgumentError
  , throwGraphError
  , throwJsonError
  , throwNixError
  )
import Penance.Json (Json (..), array, object, renderJson, string)
import qualified Penance.Json as Json
import Penance.Json.Decode (asArray, asObject, asString, field, stringArray)
import qualified Penance.Sha256 as Sha256
import Penance.Types (PackageDbKind (..), parsePackageDbKind)
import Penance.Utf8.IO (readUtf8File, writeUtf8File)
import System.Exit (ExitCode (..))
import System.FilePath ((</>), takeFileName)
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
  , reqToolDrvs :: [DrvPath]
  }
  deriving (Eq, Show)

data PlannedModule = PlannedModule
  { pmSource :: FilePath
  , pmDeps :: [FilePath]
  , pmDb :: PackageDbKind
  , pmIsBoot :: Bool
  }
  deriving (Eq, Show)

data BuiltIface = BuiltIface
  { builtHiDrv :: DrvPath
  , builtHiPlaceholder :: String
  }
  deriving (Eq, Show)

data BuiltModule
  = BuiltBoot BuiltIface
  | BuiltObject
      { builtObjectDrv :: DrvPath
      , builtObjectPlaceholder :: String
      , builtObjectIface :: Maybe BuiltIface
      }
  deriving (Eq, Show)

newtype StorePath = StorePath FilePath
  deriving (Eq, Ord, Show)

newtype DrvPath = DrvPath FilePath
  deriving (Eq, Ord, Show)

renderStorePath :: StorePath -> FilePath
renderStorePath (StorePath path) = path

renderDrvPath :: DrvPath -> FilePath
renderDrvPath (DrvPath path) = path

parseStorePath :: FilePath -> Either String StorePath
parseStorePath path
  | "/nix/store/" `isPrefixOf` path = Right (StorePath path)
  | otherwise = Left ("expected a Nix store path, got: " ++ path)

parseDrvPath :: FilePath -> Either String DrvPath
parseDrvPath path
  | ".drv" `isSuffixOf` path = DrvPath . renderStorePath <$> parseStorePath path
  | otherwise = Left ("expected a Nix derivation path, got: " ++ path)

data DerivationSpec = DerivationSpec
  { derivationName :: String
  , derivationSystem :: String
  , derivationBuilder :: FilePath
  , derivationArgs :: [String]
  , derivationEnv :: [(String, Json)]
  , derivationInputDrvs :: Map.Map DrvPath [String]
  , derivationInputSrcs :: [StorePath]
  , derivationOutputs :: [(String, Json)]
  }
  deriving (Eq, Show)

data ObjectArgs = ObjectArgs
  { objectOptions :: RequiredOptions
  , objectFlags :: [String]
  , objectModule :: PlannedModule
  , objectNeedsDynamic :: Bool
  , objectSource :: StorePath
  , objectDependencyIfaces :: [String]
  , objectDependencyObjects :: [String]
  }

emitBenchDyndrvFromArgs :: [String] -> IO ()
emitBenchDyndrvFromArgs args = do
  parsed <- either throwArgumentError pure (parseOptions emptyOptions args)
  options <- requireOptions parsed
  modules <- readModulePlan (reqModulePlan options)
  flags <- filter (not . null) . lines <$> readUtf8File (reqGhcFlags options)
  let modulesBySource = Map.fromList [(pmSource modulePlan, modulePlan) | modulePlan <- modules]
      dependencySet = Set.fromList (concatMap pmDeps modules)
      dynamicObjectSet =
        Set.unions
          [ transitiveDependencies modulesBySource modulePlan
          | modulePlan <- modules
          , pmDb modulePlan == FullPackageDb
          ]
  built <- foldM (emitModule options flags modulesBySource dependencySet dynamicObjectSet) Map.empty modules
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

parseOptions :: EmitOptions -> [String] -> Either String EmitOptions
parseOptions options args =
  case args of
    [] -> Right options
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
    flag : _ -> Left ("unknown emit-bench-dyndrv option: " ++ flag)

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
  toolDrvs <- traverse (either throwNixError pure . parseDrvPath) (optToolDrvs options)
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
      , reqToolDrvs = toolDrvs
      }
  where
    required name =
      maybe (throwArgumentError ("missing required --" ++ name)) pure

readModulePlan :: FilePath -> IO [PlannedModule]
readModulePlan path = do
  contents <- readUtf8File path
  case Json.parseJson contents >>= decodeModulePlan of
    Left err -> throwJsonError ("failed to parse module plan " ++ path ++ ": " ++ err)
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
  dbText <- field "db" fields >>= asString "module.db"
  db <- parsePackageDbKind dbText
  pure
    PlannedModule
      { pmSource = source
      , pmDeps = deps
      , pmDb = db
      , pmIsBoot = ".hs-boot" `isSuffixOf` source
      }

transitiveDependencies :: Map.Map FilePath PlannedModule -> PlannedModule -> Set.Set FilePath
transitiveDependencies modulesBySource root = go Set.empty (pmDeps root)
  where
    go seen [] = seen
    go seen (source : rest)
      | source `Set.member` seen = go seen rest
      | otherwise =
          let nested = maybe [] pmDeps (Map.lookup source modulesBySource)
           in go (Set.insert source seen) (nested ++ rest)

emitModule :: RequiredOptions -> [String] -> Map.Map FilePath PlannedModule -> Set.Set FilePath -> Set.Set FilePath -> Map.Map FilePath BuiltModule -> PlannedModule -> IO (Map.Map FilePath BuiltModule)
emitModule options flags modulesBySource dependencySet dynamicObjectSet built modulePlan = do
  let sourcePath = reqSrcRoot options </> pmSource modulePlan
      moduleName = sanitizeName (pmSource modulePlan)
      ifaceName = "penance-dyndrv-iface-" ++ moduleName
      objectName = "penance-dyndrv-module-" ++ moduleName
      needsFull = pmDb modulePlan == FullPackageDb
      needsIface = pmSource modulePlan `Set.member` dependencySet
      needsDynamicObject = needsFull || pmSource modulePlan `Set.member` dynamicObjectSet
  addedObjectSourceText <- runNix options ["store", "add-path", sourcePath]
  addedObjectSource <- either throwNixError pure (parseStorePath addedObjectSourceText)
  depModules <- traverse (lookupDep built (pmSource modulePlan)) (pmDeps modulePlan)
  transitiveObjectModules <-
    if needsDynamicObject
      then
        traverse
          (lookupDep built (pmSource modulePlan))
          (Set.toAscList (transitiveDependencies modulesBySource modulePlan))
      else pure []
  let compileDepModules = if needsDynamicObject then transitiveObjectModules else depModules
  directDepIfaces <- traverse (requireBuiltIface (pmSource modulePlan)) depModules
  compileDepIfaces <- traverse (requireBuiltIface (pmSource modulePlan)) compileDepModules
  let directDepHiPlaceholders = map builtHiPlaceholder directDepIfaces
      compileDepHiPlaceholders = map builtHiPlaceholder compileDepIfaces
      objectDeps = mapMaybe builtObjectOutput transitiveObjectModules
      depOPlaceholders = if needsDynamicObject then map snd objectDeps else []
      bootIfaceInputs =
        mergeInputs
          (toolInputs options ++ [(builtHiDrv dep, ["hi"]) | dep <- directDepIfaces])
      objectInputs =
        mergeInputs
          ( toolInputs options
              ++ [(builtHiDrv dep, ["hi"]) | dep <- compileDepIfaces]
              ++ [(drv, ["o"]) | (drv, _placeholder) <- objectDeps, needsDynamicObject]
          )
      objectJson =
        derivationJson
          DerivationSpec
            { derivationName = objectName
            , derivationSystem = reqSystem options
            , derivationBuilder = reqBuilder options
            , derivationArgs =
                objectArgs
                  ObjectArgs
                    { objectOptions = options
                    , objectFlags = flags
                    , objectModule = modulePlan
                    , objectNeedsDynamic = needsDynamicObject
                    , objectSource = addedObjectSource
                    , objectDependencyIfaces = compileDepHiPlaceholders
                    , objectDependencyObjects = depOPlaceholders
                    }
            , derivationEnv =
                moduleEnv
                  options
                  objectName
                  [ ("o", reqPlaceholderO options)
                  , ("src", renderStorePath addedObjectSource)
                  ]
            , derivationInputDrvs = objectInputs
            , derivationInputSrcs = [addedObjectSource]
            , derivationOutputs = caOutputs ["o"]
            }
  if pmIsBoot modulePlan
    then do
      let ifaceJson =
            derivationJson
              DerivationSpec
                { derivationName = ifaceName
                , derivationSystem = reqSystem options
                , derivationBuilder = reqBuilder options
                , derivationArgs = bootIfaceArgs options flags modulePlan addedObjectSource directDepHiPlaceholders
                , derivationEnv =
                    moduleEnv
                      options
                      ifaceName
                      [ ("hi", reqPlaceholderHi options)
                      , ("src", renderStorePath addedObjectSource)
                      ]
                , derivationInputDrvs = bootIfaceInputs
                , derivationInputSrcs = [addedObjectSource]
                , derivationOutputs = caOutputs ["hi"]
                }
      hiDrv <- addDerivation options ifaceJson
      hiPlaceholder <- downstreamPlaceholder hiDrv "hi"
      pure
          ( Map.insert
              (pmSource modulePlan)
              (BuiltBoot (BuiltIface hiDrv hiPlaceholder))
              built
          )
    else do
      oDrv <- addDerivation options objectJson
      oPlaceholder <- downstreamPlaceholder oDrv "o"
      builtIface <-
        if needsIface
          then do
            let ifaceInputs =
                  mergeInputs
                    ( toolInputs options
                        ++ [(oDrv, ["o"])]
                        ++ [(builtHiDrv dep, ["hi"]) | dep <- directDepIfaces]
                    )
                ifaceJson =
                  derivationJson
                    DerivationSpec
                      { derivationName = ifaceName
                      , derivationSystem = reqSystem options
                      , derivationBuilder = reqBuilder options
                      , derivationArgs = ifaceArgs options directDepHiPlaceholders
                      , derivationEnv =
                          moduleEnv
                            options
                            ifaceName
                            [ ("hi", reqPlaceholderHi options)
                            , ("real_o", oPlaceholder)
                            ]
                      , derivationInputDrvs = ifaceInputs
                      , derivationInputSrcs = []
                      , derivationOutputs = caOutputs ["hi"]
                      }
            drv <- addDerivation options ifaceJson
            placeholder <- downstreamPlaceholder drv "hi"
            pure (Just (BuiltIface drv placeholder))
          else pure Nothing
      pure
        ( Map.insert
            (pmSource modulePlan)
            BuiltObject
              { builtObjectDrv = oDrv
              , builtObjectPlaceholder = oPlaceholder
              , builtObjectIface = builtIface
              }
            built
        )

lookupDep :: Map.Map FilePath BuiltModule -> FilePath -> FilePath -> IO BuiltModule
lookupDep built current dep =
  case Map.lookup dep built of
    Just value -> pure value
    Nothing -> throwGraphError ("module plan is not topologically sorted: " ++ current ++ " depends on missing " ++ dep)

requireBuiltIface :: FilePath -> BuiltModule -> IO BuiltIface
requireBuiltIface _ (BuiltBoot iface) = pure iface
requireBuiltIface _ BuiltObject {builtObjectIface = Just iface} = pure iface
requireBuiltIface current BuiltObject {builtObjectIface = Nothing} =
  throwGraphError ("module plan omitted a required interface dependency while building " ++ current)

builtObjectOutput :: BuiltModule -> Maybe (DrvPath, String)
builtObjectOutput (BuiltBoot _) = Nothing
builtObjectOutput BuiltObject {builtObjectDrv = drv, builtObjectPlaceholder = placeholder} =
  Just (drv, placeholder)

emitAssemble :: RequiredOptions -> [String] -> [BuiltModule] -> IO DrvPath
emitAssemble options flags modules = do
  let name = "penance-bench-dyndrv-assemble"
      sortedObjects = sortOn fst (mapMaybe builtObjectOutput modules)
      inputDrvs = mergeInputs (toolInputs options ++ [(drv, ["o"]) | (drv, _placeholder) <- sortedObjects])
      outputPlaceholders = map snd sortedObjects
      json =
        derivationJson
          DerivationSpec
            { derivationName = name
            , derivationSystem = reqSystem options
            , derivationBuilder = reqBuilder options
            , derivationArgs = assembleArgs options flags outputPlaceholders
            , derivationEnv =
                moduleEnv
                  options
                  name
                  [ ("out", reqPlaceholderOut options)
                  ]
            , derivationInputDrvs = inputDrvs
            , derivationInputSrcs = []
            , derivationOutputs = caOutputs ["out"]
            }
  addDerivation options json

ifaceArgs :: RequiredOptions -> [String] -> [String]
ifaceArgs options depHiPlaceholders =
  [ "-euc"
  , unlines
      [ "set -euo pipefail"
      , "export PATH=" ++ shellQuote (reqPath options)
      , "compiler_version=$(ghc --numeric-version)"
      , "iface_version=$(printf '%s' \"$compiler_version\" | tr -d .)"
      , "case \"$iface_version\" in ''|*[!0-9]*) echo \"penance-dyndrv: cannot derive interface version from GHC $compiler_version\" >&2; exit 1;; esac"
      , "mkdir -p \"$hi\""
      , "while IFS= read -r artifact; do"
      , "  rel=\"${artifact#$real_o/}\""
      , "  mkdir -p \"$hi/$(dirname \"$rel\")\""
      , "  penance-iface-canon --input \"$artifact\" --output \"$hi/$rel\" --expect-version \"$iface_version\""
          ++ " --drop-dependent-file-prefix object-build/"
          ++ concatMap (\path -> " --dependency-interface " ++ shellQuote path) depHiPlaceholders
      , "done < <(find \"$real_o\" -name '*.hi' -type f | sort)"
      , "test -n \"$(find \"$hi\" -name '*.hi' -type f -print -quit)\""
      ]
  ]

bootIfaceArgs :: RequiredOptions -> [String] -> PlannedModule -> StorePath -> [String] -> [String]
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

objectArgs :: ObjectArgs -> [String]
objectArgs spec =
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
      , "  while IFS= read -r artifact; do"
      , "    rel=\"${artifact#$dep_o/}\""
      , "    mkdir -p \"object-build/$(dirname \"$rel\")\""
      , "    cp \"$artifact\" \"object-build/$rel\""
      , "  done < <(find \"$dep_o\" \\( -name '*.o' -o -name '*.dyn_o' -o -name '*.dyn_hi' \\) -type f | sort)"
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
      , "done < <(comm -13 \"$TMPDIR/staged-artifacts\" <(find object-build \\( -name '*.o' -o -name '*.hi' -o -name '*.dyn_o' -o -name '*.dyn_hi' \\) -type f | sort))"
      , "test -n \"$(find \"$o\" -name '*.o' -type f -print -quit)\""
      , "echo " ++ shellQuote ("compiled penance-dyndrv-module " ++ pmSource modulePlan) ++ " >&2"
      ]
  ]
  where
    options = objectOptions spec
    flags = objectFlags spec
    modulePlan = objectModule spec
    needsDynamicObject = objectNeedsDynamic spec
    depHiPlaceholders = objectDependencyIfaces spec
    depOPlaceholders = objectDependencyObjects spec
    _ = objectSource spec

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

derivationJson :: DerivationSpec -> Json
derivationJson spec =
  object
    [ ("name", string (derivationName spec))
    , ("system", string (derivationSystem spec))
    , ("builder", string (derivationBuilder spec))
    , ("args", array (map string (derivationArgs spec)))
    , ("env", object (derivationEnv spec))
    , ( "inputs"
      , object
          [ ("drvs", inputDrvsJson (derivationInputDrvs spec))
          , ("srcs", array (map (string . takeFileName . renderStorePath) (sort (derivationInputSrcs spec))))
          ]
      )
    , ("outputs", object (derivationOutputs spec))
    , ("version", JsonNumber "4")
    ]

inputDrvsJson :: Map.Map DrvPath [String] -> Json
inputDrvsJson inputDrvs =
  object
    [ ( takeFileName (renderDrvPath drv)
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

toolInputs :: RequiredOptions -> [(DrvPath, [String])]
toolInputs options =
  [(drv, ["out"]) | drv <- reqToolDrvs options]

mergeInputs :: [(DrvPath, [String])] -> Map.Map DrvPath [String]
mergeInputs =
  Map.map Set.toAscList . foldr insertOne Map.empty
  where
    insertOne (drv, outputs) =
      Map.insertWith Set.union drv (Set.fromList outputs)

addDerivation :: RequiredOptions -> Json -> IO DrvPath
addDerivation options json = do
  let text = renderJson json ++ "\n"
  result <- runCommandTrim (reqNixBin options) ["derivation", "add"] text
  either throwNixError pure (parseDrvPath result)

copyDrvText :: DrvPath -> FilePath -> IO ()
copyDrvText drv out = do
  contents <- readUtf8File (renderDrvPath drv)
  writeUtf8File out contents

downstreamPlaceholder :: DrvPath -> String -> IO String
downstreamPlaceholder drv output = do
  clearText <- either throwNixError pure (downstreamPlaceholderClearText drv output)
  pure ("/" ++ Sha256.renderNixBase32Sha256 (Sha256.nixBase32Sha256 clearText))

downstreamPlaceholderClearText :: DrvPath -> String -> Either String String
downstreamPlaceholderClearText drv output = do
  (hashPart, drvName) <- parseDrvStorePath drv
  let pathName =
        if output == "out" then drvName else drvName ++ "-" ++ output
  pure ("nix-upstream-output:" ++ hashPart ++ ":" ++ pathName)

parseDrvStorePath :: DrvPath -> Either String (String, String)
parseDrvStorePath drv =
  case break (== '-') (takeFileName path) of
    (hashPart, '-' : rest)
      | ".drv" `isSuffixOf` rest ->
          Right (hashPart, dropSuffix ".drv" rest)
    _ ->
      Left ("expected a /nix/store hash-name.drv path, got: " ++ path)
  where
    path = renderDrvPath drv

selfOutputPlaceholder :: FilePath -> String -> IO String
selfOutputPlaceholder _ output =
  pure ("/" ++ Sha256.renderNixBase32Sha256 (Sha256.nixBase32Sha256 ("nix-output:" ++ output)))

runNix :: RequiredOptions -> [String] -> IO String
runNix options args = do
  let nixBin = reqNixBin options
  runCommandTrim nixBin args ""

runCommandTrim :: FilePath -> [String] -> String -> IO String
runCommandTrim command args stdinText = do
  (exitCode, stdoutText, stderrText) <-
    readProcessWithExitCode command args stdinText
  case exitCode of
    ExitSuccess -> pure (trim stdoutText)
    ExitFailure code ->
      throwNixError
        ( intercalate
            "\n"
            [ "command failed with exit " ++ show code ++ ": " ++ unwords (command : args)
            , stderrText
            ]
        )

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

dropSuffix :: String -> String -> String
dropSuffix suffix value
  | suffix `isSuffixOf` value = take (length value - length suffix) value
  | otherwise = value

trim :: String -> String
trim =
  dropWhileEnd isSpaceLike . dropWhile isSpaceLike

isSpaceLike :: Char -> Bool
isSpaceLike ch =
  ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t'
