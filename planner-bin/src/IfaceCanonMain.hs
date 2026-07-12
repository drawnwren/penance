{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Word (Word32)
import GHC.Data.FastString (unpackFS)
import GHC.Iface.Binary (TraceBinIFace (QuietBinIFace), getWithUserData, putWithUserData)
import GHC.Iface.Recomp.Binary (computeFingerprint, putNameLiterally)
import GHC.Types.Name.Cache (NameCache, initNameCache)
import GHC.Unit.Module.Deps (Usage (UsageFile), usg_file_path)
import GHC.Unit.Module.ModIface
  ( ModIface
  , ModIfaceBackend (..)
  , mi_ext_fields
  , mi_final_exts
  , mi_src_hash
  , mi_usages
  )
import GHC.Utils.Binary
  ( Binary (get, put_)
  , FixedLengthEncoding
  , openBinMem
  , putAt
  , readBinMem
  , seekBin
  , tellBin
  , writeBinMem
  )
import System.Environment (getArgs)
import System.Exit (die)

data Options = Options
  { optInput :: FilePath
  , optOutput :: FilePath
  , optExpectedVersion :: String
  , optDependencyInterfaces :: [FilePath]
  , optDroppedFilePrefixes :: [FilePath]
  }

data IfaceHeader = IfaceHeader
  { headerMagic :: FixedLengthEncoding Word32
  , headerVersion :: String
  , headerWay :: String
  }

main :: IO ()
main = do
  options <- parseOptions =<< getArgs
  result <- try (canonicalize options)
  case result of
    Left (err :: SomeException) -> die ("penance-iface-canon: " ++ displayException err)
    Right () -> pure ()

canonicalize :: Options -> IO ()
canonicalize options = do
  nameCache <- initNameCache 'p' []
  (header, iface) <- readIfaceUnchecked nameCache (optInput options)
  unless (headerVersion header == optExpectedVersion options) $
    fail $
      "interface version mismatch: expected "
        ++ optExpectedVersion options
        ++ ", got "
        ++ headerVersion header
  let backend = mi_final_exts iface
      abiHash = mi_mod_hash backend
  interfaceHash <-
    computeFingerprint
      putNameLiterally
      (abiHash, sort (optDependencyInterfaces options))
  let canonicalBackend = backend {mi_iface_hash = interfaceHash}
      canonicalUsages =
        filter
          (not . shouldDropUsage (optDroppedFilePrefixes options))
          (mi_usages iface)
      canonicalIface =
        iface
          { mi_src_hash = abiHash
          , mi_final_exts = canonicalBackend
          , mi_usages = canonicalUsages
          }
  writeIfaceWithHeader header canonicalIface (optOutput options)
  putStrLn $
    "penance-iface-canon: ABI "
      ++ show abiHash
      ++ ", interface "
      ++ show interfaceHash

readIfaceUnchecked :: NameCache -> FilePath -> IO (IfaceHeader, ModIface)
readIfaceUnchecked nameCache path = do
  handle <- readBinMem path
  magic <- get handle
  version <- get handle
  way <- get handle
  sourceHash <- get handle
  extFieldsPosition <- get handle
  iface <- getWithUserData nameCache handle
  seekBin handle extFieldsPosition
  extFields <- get handle
  pure
    ( IfaceHeader
        { headerMagic = magic
        , headerVersion = version
        , headerWay = way
        }
    , iface
        { mi_src_hash = sourceHash
        , mi_ext_fields = extFields
        }
    )

writeIfaceWithHeader :: IfaceHeader -> ModIface -> FilePath -> IO ()
writeIfaceWithHeader header iface path = do
  handle <- openBinMem (1024 * 1024)
  put_ handle (headerMagic header)
  put_ handle (headerVersion header)
  put_ handle (headerWay header)
  put_ handle (mi_src_hash iface)
  extFieldsPointerPosition <- tellBin handle
  put_ handle extFieldsPointerPosition
  putWithUserData QuietBinIFace handle iface
  extFieldsPosition <- tellBin handle
  putAt handle extFieldsPointerPosition extFieldsPosition
  seekBin handle extFieldsPosition
  put_ handle (mi_ext_fields iface)
  writeBinMem handle path

parseOptions :: [String] -> IO Options
parseOptions = go Nothing Nothing Nothing [] []
  where
    go input output version dependencies droppedPrefixes args =
      case args of
        [] ->
          case (input, output, version) of
            (Just inputPath, Just outputPath, Just expectedVersion) ->
              pure
                Options
                  { optInput = inputPath
                  , optOutput = outputPath
                  , optExpectedVersion = expectedVersion
                  , optDependencyInterfaces = dependencies
                  , optDroppedFilePrefixes = droppedPrefixes
                  }
            _ -> usage
        "--input" : value : rest ->
          go (Just value) output version dependencies droppedPrefixes rest
        "--output" : value : rest ->
          go input (Just value) version dependencies droppedPrefixes rest
        "--expect-version" : value : rest ->
          go input output (Just value) dependencies droppedPrefixes rest
        "--dependency-interface" : value : rest ->
          go input output version (value : dependencies) droppedPrefixes rest
        "--drop-dependent-file-prefix" : value : rest ->
          go input output version dependencies (value : droppedPrefixes) rest
        _ -> usage

    usage =
      die $
        unlines
          [ "usage: penance-iface-canon --input INPUT.hi --output OUTPUT.hi"
          , "                           --expect-version VERSION"
          , "                           [--dependency-interface PATH ...]"
          , "                           [--drop-dependent-file-prefix PATH ...]"
          ]

shouldDropUsage :: [FilePath] -> Usage -> Bool
shouldDropUsage prefixes usage =
  case usage of
    UsageFile {} ->
      let path = unpackFS (usg_file_path usage)
       in any (`isPrefixOf` path) prefixes
            && (".o" `isSuffixOf` path || ".dyn_o" `isSuffixOf` path)
    _ -> False
