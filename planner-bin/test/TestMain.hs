module Main (main) where

import Control.Exception (bracket, try)
import qualified Data.ByteString as BS
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import Distribution.Pretty (prettyShow)
import Penance.Blake3 (hash, hashHex)
import Penance.CabalPlan
  ( ExternalUnit (..)
  , LocalComponentUnit (..)
  , ResolvedPlan (..)
  , decodeResolvedPlan
  , renderFlagAssignment
  , renderUnitId
  )
import Penance.CabalProject
  ( CabalProject (..)
  , parseCabalProject
  , qualifyConstraintForAllScopes
  )
import Penance.Dyndrv
  ( DerivationSpec (..)
  , DrvPath
  , StorePath
  , derivationJson
  , downstreamPlaceholderClearText
  , mergeInputs
  , parseDrvPath
  , parseStorePath
  )
import Penance.Error (PenanceError (..))
import Penance.GhcMakefile (ModuleDep (..), moduleGraphFromMakefile)
import Penance.Json (Json (..), parseJson, renderJson, renderPrettyJson)
import qualified Penance.Json as Json
import Penance.LockLowerer (lowerLockInput)
import Penance.ModulePlan (hasAnnPragma, languagePragmas, needsDbFullFor)
import Penance.Repent.Project (matchGlob)
import Penance.Repent.PackageSet
  ( PackageSet
  , decodePackageSet
  , extendPackageSetWithPlan
  , packageSetConstraints
  , packageSetHash
  , packageSetNix
  )
import Penance.Sha256 (nixBase32Sha256, renderNixBase32Sha256)
import Penance.Skeleton
  ( BackpackSkeleton (..)
  , ExpectedOutputs (..)
  , LocalComponent (..)
  , LocalPackage (..)
  , ProjectSkeleton (..)
  , decodeProjectSkeleton
  , encodeProjectSkeleton
  , mkComponentId
  , mkModuleName
  , mkPkgName
  , planCacheKeyFromDigest
  , projectKeyFromDigest
  )
import Penance.Types
  ( CompilerId (..)
  , ComponentKind (LibraryKind)
  , Granularity (ComponentGranularity)
  )
import Penance.Utf8 (decodeUtf8, decodeUtf8Indexed, encodeUtf8)
import Penance.Utf8.IO (readUtf8File, writeUtf8File)
import Penance.WasmPlanner (normalizeProject)
import Paths_penance_planner (getDataFileName)
import System.Directory (getTemporaryDirectory, removeFile)
import System.FilePath (replaceExtension)
import System.IO (hClose, openTempFile)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, assertFailure, testCase)
import Test.Tasty.QuickCheck (testProperty)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "penance"
        [ hashTests
        , jsonTests
        , utf8Tests
        , pragmaTests
        , cabalProjectTests
        , repentProjectTests
        , cabalConditionalTests
        , normalizerCacheTests
        , ghcMakefileTests
        , cabalPlanTests
        , packageSetTests
        , lockLowererTests
        , dyndrvTests
        , skeletonCodecTests
        ]
    )

hashTests :: TestTree
hashTests =
  testGroup
    "hashes"
    ( [ testCase ("SHA-256 " ++ show size ++ " bytes") $
          renderNixBase32Sha256 (nixBase32Sha256 (replicate size 'a')) @?= expected
      | (size, expected) <- sha256Vectors
      ]
        ++ [ testCase ("BLAKE3 " ++ show size ++ " bytes") $
              hashHex (replicate size 'a') @?= expected
          | (size, expected) <- blake3Vectors
          ]
    )

sha256Vectors :: [(Int, String)]
sha256Vectors =
  [ (3, "1w78gq8ay2cx5y7z4myz3adwhjlclpmm6jf2lmkv2p5hrxnqfd4q")
  , (55, "0623fc7r27lz3hj8w9d54nlv1scs5dgbd5ghr4pdjb8csgw90hwz")
  , (56, "12kkqrp6hw3rxy871phv1zi0qnaz1ypwdqzrssv4h2bgmjj3jm5k")
  , (57, "1ip8vy4nbv8bbigbgwjrkzq82yy8rhdazmidgzs3pssr8rr2sfzi")
  , (63, "0d1gviylbnpjzz3b85ngxrpg1qwqx9c0dv6r9b75pcbxbnh78gkx")
  , (64, "1sv88qaxydvkk6jhngdl3n2kkx09a8fvdy9sbk36vjz0gbz59q7z")
  , (119, "1yywhijymxsjz553zc8nx39dipygb6ix866zd8i0hp1s64fabsri")
  , (120, "07620kwmmigxxnm3mxx579l0s0kw99kv7qg8y055h2y769a36g9g")
  ]

blake3Vectors :: [(Int, String)]
blake3Vectors =
  [ (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
  , (3, "30c0f9c6a167fc2a91285c85be7ea341569b3b39fcc5f77fd34534cade971d20")
  , (1024, "5a1c9e5d85d9898297037e8e24f69bb0e604a84c91c3b3ef4784a374812900d9")
  , (1025, "c59d2e12583df14d951e757a42f1734d355c8c5b1db6b6a33ab2bfabeed40c7d")
  , (2048, "11654ac17d073b0905429320fee0a34776cb5f10a9767287c70b627fc4f45539")
  , (3073, "45bfb0005f625b4dccd82d6b0b550cb0d3c0cf7f4033cdf7ff224036313a571d")
  ]

jsonTests :: TestTree
jsonTests =
  testGroup
    "JSON"
    [ testCase "valid number grammar" $
        parseJson "[-12.5e+3,0,1E-2]"
          @?= Right (JsonArray [JsonNumber "-12.5e+3", JsonNumber "0", JsonNumber "1E-2"])
    , testCase "rejects malformed numbers and keywords" $
        mapM_ assertRejected ["01", "1.", "1e", "-", "trueValue", "nul"]
    , testCase "round trips escaped strings" $
        let value = Json.object [("value", Json.string "line\n\x03bb")]
         in parseJson (renderJson value) @?= Right value
    , testCase "pretty output sorts object keys" $
        renderPrettyJson (Json.object [("z", Json.string "last"), ("a", Json.string "first")])
          @?= "{\n  \"a\": \"first\",\n  \"z\": \"last\"\n}"
    ]
  where
    assertRejected input =
      case parseJson input of
        Left _ -> pure ()
        Right value -> assertFailure ("accepted invalid JSON `" ++ input ++ "` as " ++ show value)

utf8Tests :: TestTree
utf8Tests =
  testGroup
    "UTF-8"
    [ testCase "lone surrogate encodes as U+FFFD" $
        encodeUtf8 ['\xd800'] @?= [0xef, 0xbf, 0xbd]
    , testCase "decodes boundary sequences" $
        decodeUtf8 [0x24, 0xc2, 0xa2, 0xe2, 0x82, 0xac, 0xf0, 0x90, 0x8d, 0x88]
          @?= Right "$\xa2\x20ac\x10348"
    , testCase "rejects malformed and truncated sequences" $
        mapM_ assertUtf8Rejected
          [ [0x80]
          , [0xc0, 0x80]
          , [0xe0, 0x80, 0x80]
          , [0xed, 0xa0, 0x80]
          , [0xf4, 0x90, 0x80, 0x80]
          , [0xf0, 0x9f, 0x92]
          ]
    , testCase "indexed decoder handles a large input without list expansion" $
        let bytes = BS.replicate 100000 0x61
         in decodeUtf8Indexed (BS.length bytes) (BS.index bytes)
              @?= Right (replicate 100000 'a')
    ]
  where
    assertUtf8Rejected bytes =
      case decodeUtf8 bytes of
        Left _ -> pure ()
        Right value -> assertFailure ("accepted invalid UTF-8 as " ++ show value)

pragmaTests :: TestTree
pragmaTests =
  testGroup
    "pragmas"
    [ testCase "multiline LANGUAGE" $
        languagePragmas "{-# LANGUAGE\n TemplateHaskell,\n QuasiQuotes #-}\nmodule A where\n"
          @?= ["QuasiQuotes", "TemplateHaskell"]
    , testCase "compact and lowercase pragma keyword" $
        languagePragmas "{-#language TemplateHaskellQuotes #-}\n{-#LANGUAGE OverloadedStrings #-}"
          @?= ["OverloadedStrings", "TemplateHaskellQuotes"]
    , testCase "ANN is case insensitive" $
        assertBool "ANN pragma not detected" (hasAnnPragma "{-# ann module (\"x\" :: String) #-}")
    , testCase "needsDbFull classifies execution-capable extensions and ANN" $ do
        needsDbFullFor ["TemplateHaskell"] False @?= True
        needsDbFullFor ["QuasiQuotes"] False @?= True
        needsDbFullFor ["OverloadedStrings"] True @?= True
        needsDbFullFor ["OverloadedStrings"] False @?= False
    ]

cabalProjectTests :: TestTree
cabalProjectTests =
  testCase "shared project parser retains packages, index state, and solver constraints" $
    case parseCabalProject projectText of
      Left err -> assertFailure err
      Right project -> do
        projectPackages project @?= ["packages/*/*.cabal"]
        projectOptionalPackages project @?= ["tools/*"]
        projectIndexState project @?= Just "2026-02-01T00:00:00Z"
        projectConstraints project
          @?= [ "happy < 2"
              , "hashable == {1.4.7.0, 1.5.0.0}"
              , "text >= 2.1 && < 2.2"
              ]
        map qualifyConstraintForAllScopes (projectConstraints project)
          @?= [ "any.happy < 2"
              , "any.hashable == {1.4.7.0, 1.5.0.0}"
              , "any.text >= 2.1 && < 2.2"
              ]
        qualifyConstraintForAllScopes "setup.happy < 2" @?= "setup.happy < 2"
  where
    projectText =
      unlines
        [ "packages: packages/*/*.cabal"
        , "optional-packages: tools/*"
        , "index-state: 2026-02-01T00:00:00Z"
        , "constraints:"
        , "  text >= 2.1 && < 2.2,"
        , "  happy < 2,"
        , "  hashable == {1.4.7.0, 1.5.0.0}"
        ]

repentProjectTests :: TestTree
repentProjectTests =
  testCase "repent project glob matching handles stars and single characters" $ do
    matchGlob "packages/*" "packages/model" @?= True
    matchGlob "pkg-?.cabal" "pkg-a.cabal" @?= True
    matchGlob "pkg-?.cabal" "pkg-long.cabal" @?= False

cabalConditionalTests :: TestTree
cabalConditionalTests =
  testCase "normalizer rejects unresolved Cabal conditionals" $
    case normalizeProject conditionalInput of
      Left err -> assertBool err ("conditionals" `isInfixOf` err)
      Right output -> assertFailure ("conditional stanza was accepted: " ++ output)

normalizerCacheTests :: TestTree
normalizerCacheTests =
  testGroup
    "normalizer cache cutoff"
    [ testCase "body/source digest and Cabal formatting edits preserve semantic output" $ do
        baseline <- normalizeOrFail (normalizerInput '1' normalizedCabal)
        bodyEdit <- normalizeOrFail (normalizerInput '2' formattedCabal)
        bodyEdit @?= baseline
    , testCase "semantic Cabal edits change normalized output" $ do
        baseline <- normalizeOrFail (normalizerInput '1' normalizedCabal)
        semanticEdit <- normalizeOrFail (normalizerInput '2' semanticCabal)
        assertBool "semantic edit unexpectedly preserved normalized output" (semanticEdit /= baseline)
    ]
  where
    normalizeOrFail input =
      case normalizeProject input of
        Left err -> assertFailure err >> pure ""
        Right output -> pure output

normalizerInput :: Char -> String -> String
normalizerInput digest cabalText =
  renderJson . Json.object $
    [ ("srcTreeDigest", Json.string ("blake3:" ++ replicate 64 digest))
    , ("compiler", Json.string "ghc-9.10.2")
    , ("indexState", Json.string "2026-02-01T00:00:00Z")
    , ("cabalProjectText", Json.string "packages: .\n")
    , ( "localPackageManifests"
      , Json.array
          [ Json.object
              [ ("path", Json.string ".")
              , ("cabalText", Json.string cabalText)
              ]
          ]
      )
    , ("flags", Json.object [])
    , ("materializationMode", Json.string "dynamic")
    , ("granularity", Json.string "component")
    ]

normalizedCabal :: String
normalizedCabal =
  unlines
    [ "cabal-version: 3.8"
    , "name: cache-cutoff"
    , "version: 0.1.0.0"
    , "license: NONE"
    , "library"
    , "  exposed-modules: Cache.Cutoff"
    , "  hs-source-dirs: src"
    , "  build-depends: base >=4.20 && <5"
    ]

formattedCabal :: String
formattedCabal =
  unlines
    [ "-- formatting-only edit"
    , "cabal-version: 3.8"
    , "name: cache-cutoff"
    , "version: 0.1.0.0"
    , "license: NONE"
    , ""
    , "library"
    , "    exposed-modules:   Cache.Cutoff"
    , "    hs-source-dirs: src"
    , "    build-depends: base >=4.20 && <5"
    ]

semanticCabal :: String
semanticCabal = replaceAll "Cache.Cutoff\n" "Cache.Cutoff, Cache.Extra\n" normalizedCabal

conditionalInput :: String
conditionalInput =
  renderJson . Json.object $
    [ ("srcTreeDigest", Json.string ("blake3:" ++ replicate 64 '0'))
    , ("compiler", Json.string "ghc-9.10.2")
    , ("indexState", Json.string "2026-02-01T00:00:00Z")
    , ("cabalProjectText", Json.string "packages: .")
    , ( "localPackageManifests"
      , Json.array
          [ Json.object
              [ ("path", Json.string ".")
              , ( "cabalText"
                , Json.string
                    ( unlines
                        [ "cabal-version: 3.8"
                        , "name: conditional"
                        , "version: 0.1.0.0"
                        , "flag extra"
                        , "  default: False"
                        , "library"
                        , "  exposed-modules: Base"
                        , "  if flag(extra)"
                        , "    other-modules: Extra"
                        ]
                    )
                )
              ]
          ]
      )
    , ("flags", Json.object [])
    , ("materializationMode", Json.string "dynamic")
    , ("granularity", Json.string "component")
    ]

ghcMakefileTests :: TestTree
ghcMakefileTests =
  testGroup
    "ghc -M"
    [ testCase "real continuations, hs-boot, and escaped spaces" $ do
        templatePath <- getDataFileName "test/data/ghc-makefile.mk"
        root <- getDataFileName "test/data"
        template <- readUtf8File templatePath
        withTempContents (replaceAll "@ROOT@" root template) $ \makefile -> do
          graph <- moduleGraphFromMakefile makefile
          map moduleSource graph
            @?= [ root ++ "/src/Boot.hs-boot"
                , root ++ "/src/Space Module.hs"
                , root ++ "/src/Consumer.hs"
                ]
    , testCase "reports dependency cycles" $
        withTempSource "module CycleA where\n" $ \sourceA ->
          withTempSource "module CycleB where\n" $ \sourceB -> do
            let objectA = replaceExtension sourceA "o"
                objectB = replaceExtension sourceB "o"
                hiA = replaceExtension sourceA "hi"
                hiB = replaceExtension sourceB "hi"
                makefileText =
                  unlines
                    [ objectA ++ ": " ++ sourceA ++ " " ++ hiB
                    , objectB ++ ": " ++ sourceB ++ " " ++ hiA
                    ]
            withTempContents makefileText $ \makefile -> do
              result <- try (moduleGraphFromMakefile makefile) :: IO (Either PenanceError [ModuleDep])
              case result of
                Left (GraphError message) -> assertBool message ("cycle in" `isInfixOf` message)
                Left other -> assertFailure ("expected GraphError, got " ++ show other)
                Right graph -> assertFailure ("cycle unexpectedly sorted: " ++ show graph)
    ]

cabalPlanTests :: TestTree
cabalPlanTests =
  testCase "decodes real cabal-install component-map and exe-depends variants" $ do
    path <- getDataFileName "test/data/plan.json"
    contents <- readUtf8File path
    case decodeResolvedPlan (CompilerId "ghc-9.0.2") contents of
      Left err -> assertFailure err
      Right plan -> do
        let units = resolvedExternalUnits plan
            locals = resolvedLocalComponents plan
            localRows =
              [ ( localUnitComponent unit
                , map renderUnitId (localUnitExternalDepends unit)
                , map renderUnitId (localUnitExternalExeDepends unit)
                )
              | unit <- locals
              ]
        map (prettyShow . externalUnitName) units
          @?= [ "Cabal"
              , "array"
              , "base"
              , "binary"
              , "bytestring"
              , "containers"
              , "deepseq"
              , "directory"
              , "filepath"
              , "ghc-bignum"
              , "ghc-boot-th"
              , "ghc-prim"
              , "hsc2hs"
              , "mtl"
              , "parsec"
              , "pretty"
              , "process"
              , "rts"
              , "template-haskell"
              , "text"
              , "time"
              , "transformers"
              , "unix"
              ]
        localRows
          @?= [ ("exe:real-plan-fixture", ["base-4.15.1.0"], [])
              , ("lib", ["base-4.15.1.0"], ["hsc2hs-0.68.10-251a7e45"])
              , ("setup", ["Cabal-3.4.1.0", "base-4.15.1.0"], [])
              ]
        case filter ((== "hsc2hs") . prettyShow . externalUnitName) units of
          [toolUnit] -> do
            renderUnitId (externalUnitId toolUnit) @?= "hsc2hs-0.68.10-251a7e45"
            renderFlagAssignment (externalUnitFlags toolUnit) @?= [("in-ghc-tree", False)]
            externalUnitComponent toolUnit @?= Just "exe:hsc2hs"
          _ -> assertFailure "fixture unexpectedly decoded without exactly one hsc2hs unit"

lockLowererTests :: TestTree
lockLowererTests =
  testGroup
    "lock lowerer"
    [ testCase "sorts schema-2 external units canonically" $
        lowerLockInput (renderJson (lowererInput [bootUnit "unit-b" [], bootUnit "unit-a" []]))
          @?= Right (renderJson expected)
    , testCase "rejects dangling unit-id edges" $
        case lowerLockInput (renderJson (lowererInput [bootUnit "unit-a" ["missing-unit"]])) of
          Left message -> assertBool message ("missing-unit" `isInfixOf` message)
          Right output -> assertFailure ("dangling edge unexpectedly lowered: " ++ output)
    ]
  where
    expected =
      Json.object
        [ ("schema", Json.string "penance/lowered-lock/2")
        , ("compiler", Json.string "ghc-9.10.2")
        , ("indexState", Json.string "2026-04-01T00:00:00Z")
        , ("packages", Json.array [])
        , ("externalUnits", Json.array [bootUnit "unit-a" [], bootUnit "unit-b" []])
        ]

packageSetTests :: TestTree
packageSetTests =
  testGroup
    "package set"
    [ testCase "canonical hash matches pure Nix" $ do
        packageSet <- readPackageSetFixture
        packageSetHash packageSet
          @?= "sha256:aea907fe68b908e246ce8fc47987a1bb72ccfafe2a186b90d2fdb8a346bc41c6"
        packageSetConstraints packageSet @?= ["any.StateVar==1.2.2"]
        assertBool "generated package set is not Nix" ("\"StateVar\" =" `isInfixOf` packageSetNix packageSet)
    , testCase "rejects a recipe whose flag hash does not match its flags" $ do
        case decodePackageSet (replaceAll "6e46dd10defc" "000000000000" packageSetEvaluation) of
          Left message -> assertBool message ("flagHash" `isInfixOf` message)
          Right _ -> assertFailure "accepted package set with a forged flag hash"
    , testCase "extends a shared set while preserving existing pins" $ do
        packageSet <- readPackageSetFixture
        plan <- readPlanFixture
        extended <- either assertFailure pure (extendPackageSetWithPlan packageSet plan)
        packageSetConstraints extended
          @?= ["any.StateVar==1.2.2", "any.hsc2hs==0.68.10"]
    ]

readPackageSetFixture :: IO PackageSet
readPackageSetFixture = either assertFailure pure (decodePackageSet packageSetEvaluation)

packageSetEvaluation :: String
packageSetEvaluation =
  renderJson $
    Json.object
      [ ("compiler", Json.string "ghc-9.10.2")
      , ("indexState", Json.string "2026-02-01T00:00:00Z")
      , ( "packages"
        , Json.object
            [ ( "StateVar"
              , Json.object
                  [ ( "recipes"
                    , Json.object
                        [ ( "6e46dd10defc"
                          , Json.object
                              [ ("flagHash", Json.string "6e46dd10defc")
                              , ("flags", Json.object [])
                              , ("nixExpression", Json.string "StateVar-1.2.2-6e46dd10defc.nix")
                              , ( "sdist"
                                , Json.object
                                    [ ( "sha256"
                                      , Json.string "sha256-Xks52jlWVqWYJ7AoBQiq/ccDNXmLUOXW/VJZYCYlGCU="
                                      )
                                    , ( "url"
                                      , Json.string
                                          "https://hackage.haskell.org/package/StateVar-1.2.2/StateVar-1.2.2.tar.gz"
                                      )
                                    ]
                                )
                              ]
                          )
                        ]
                    )
                  , ("version", Json.string "1.2.2")
                  ]
              )
            ]
        )
      , ("schema", Json.string "penance/package-set/2")
      , ("stackage", Json.string "lts-24.41")
      ]

readPlanFixture :: IO ResolvedPlan
readPlanFixture = do
  path <- getDataFileName "test/data/plan.json"
  contents <- readUtf8File path
  either assertFailure pure (decodeResolvedPlan (CompilerId "ghc-9.0.2") contents)

lowererInput :: [Json] -> Json
lowererInput units =
  Json.object
    [ ("operation", Json.string "lower-lock")
    , ( "lock"
      , Json.object
          [ ("schema", Json.string "penance/lock/2")
          , ("compiler", Json.string "ghc-9.10.2")
          , ("indexState", Json.string "2026-04-01T00:00:00Z")
          , ("packages", Json.array [])
          , ("externalUnits", Json.array units)
          ]
      )
    ]

bootUnit :: String -> [String] -> Json
bootUnit unitId dependencies =
  Json.object
    [ ("unitId", Json.string unitId)
    , ("name", Json.string unitId)
    , ("version", Json.string "1")
    , ("flags", Json.object [])
    , ("component", Json.JsonNull)
    , ("style", Json.string "global")
    , ("source", Json.string "ghc-boot")
    , ("depends", Json.stringArray dependencies)
    , ("exeDepends", Json.array [])
    , ("instantiatedWith", Json.object [])
    ]

dyndrvTests :: TestTree
dyndrvTests =
  testGroup
    "dynamic derivations"
    [ testCase "mergeInputs unions and sorts outputs by typed drv path" $
        withDyndrvPaths $ \drvA drvB _source ->
          mergeInputs [(drvB, ["out"]), (drvA, ["z", "a"]), (drvA, ["a"])]
            @?= Map.fromList [(drvA, ["a", "z"]), (drvB, ["out"])]
    , testCase "derivation JSON has version-4 typed input shape" $
        withDyndrvPaths $ \drvA _drvB source ->
          derivationJson
            DerivationSpec
              { derivationName = "typed-shape"
              , derivationSystem = "aarch64-darwin"
              , derivationBuilder = "/bin/sh"
              , derivationArgs = ["-c", "true"]
              , derivationEnv = [("name", Json.string "typed-shape")]
              , derivationInputDrvs = Map.fromList [(drvA, ["out"])]
              , derivationInputSrcs = [source]
              , derivationOutputs = [("out", Json.object [("method", Json.string "nar")])]
              }
            @?= Json.object
              [ ("name", Json.string "typed-shape")
              , ("system", Json.string "aarch64-darwin")
              , ("builder", Json.string "/bin/sh")
              , ("args", Json.array [Json.string "-c", Json.string "true"])
              , ("env", Json.object [("name", Json.string "typed-shape")])
              , ( "inputs"
                , Json.object
                    [ ( "drvs"
                      , Json.object
                          [ ( "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a.drv"
                            , Json.object
                                [ ("dynamicOutputs", Json.object [])
                                , ("outputs", Json.array [Json.string "out"])
                                ]
                            )
                          ]
                      )
                    , ("srcs", Json.array [Json.string "cccccccccccccccccccccccccccccccc-source"])
                    ]
                )
              , ("outputs", Json.object [("out", Json.object [("method", Json.string "nar")])])
              , ("version", JsonNumber "4")
              ]
    , testCase "placeholder cleartext names non-out outputs" $
        withDyndrvPaths $ \drvA _drvB _source ->
          downstreamPlaceholderClearText drvA "hi"
            @?= Right
              "nix-upstream-output:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:a-hi"
    ]

withDyndrvPaths :: (DrvPath -> DrvPath -> StorePath -> IO ()) -> IO ()
withDyndrvPaths action =
  case
    ( parseDrvPath "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a.drv"
    , parseDrvPath "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b.drv"
    , parseStorePath "/nix/store/cccccccccccccccccccccccccccccccc-source"
    )
  of
    (Right drvA, Right drvB, Right source) -> action drvA drvB source
    values -> assertFailure ("typed path fixture failed to parse: " ++ show values)

skeletonCodecTests :: TestTree
skeletonCodecTests =
  testProperty "ProjectSkeleton codec round trip" $ \projectKeyValue packageNameValue modules ->
    case
      ( mkPkgName ("pkg-" ++ filter (/= '\0') packageNameValue)
      , mkComponentId "lib"
      , traverse (mkModuleName . ("M" ++) . filter (/= '\0')) modules
      )
    of
      (Right parsedPackageName, Right parsedComponentName, Right parsedModules) ->
        let component =
              LocalComponent
                { componentName = parsedComponentName
                , componentKind = LibraryKind
                , componentProvidedModules = parsedModules
                , componentSignatures = []
                , componentRequiredSignatures = []
                , componentMixins = []
                , componentReexportedModules = []
                }
            package =
              LocalPackage
                { packageName = parsedPackageName
                , packageVersion = "0.1.0.0"
                , packageComponents = [parsedComponentName]
                , packageComponentDetails = [component]
                , packageSignatures = []
                , packageRequiredSignatures = []
                , packageProvidedModules = parsedModules
                }
            skeleton =
              ProjectSkeleton
                { skeletonPath = "/source"
                , projectKey = projectKeyFromDigest (hash projectKeyValue)
                , localPackages = [package]
                , sourceRepos = []
                , planCacheKey = planCacheKeyFromDigest (hash "cache")
                , plannerDrvInputs = []
                , granularity = ComponentGranularity
                , backpack = BackpackSkeleton [] []
                , expectedOutputs = ExpectedOutputs True True True
                }
         in decodeProjectSkeleton "/source" (encodeProjectSkeleton skeleton) == Right skeleton
      _ -> False

withTempContents :: String -> (FilePath -> IO a) -> IO a
withTempContents = withTempNamedContents "penance-ghc-makefile.mk"

withTempSource :: String -> (FilePath -> IO a) -> IO a
withTempSource = withTempNamedContents "penance-cycle.hs"

withTempNamedContents :: FilePath -> String -> (FilePath -> IO a) -> IO a
withTempNamedContents template contents action =
  bracket create removeFile action
  where
    create = do
      directory <- getTemporaryDirectory
      (path, handle) <- openTempFile directory template
      hClose handle
      writeUtf8File path contents
      pure path

replaceAll :: String -> String -> String -> String
replaceAll needle replacement = go
  where
    go [] = []
    go value@(ch : rest)
      | needle `isPrefix` value = replacement ++ go (drop (length needle) value)
      | otherwise = ch : go rest
    isPrefix [] _ = True
    isPrefix _ [] = False
    isPrefix (left : leftRest) (right : rightRest) =
      left == right && isPrefix leftRest rightRest
