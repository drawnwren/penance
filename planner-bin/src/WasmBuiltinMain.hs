{-# LANGUAGE ForeignFunctionInterface #-}

module Main (main) where

import Data.Word (Word32, Word8)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (peekArray, withArrayLen)
import Foreign.Ptr (Ptr, nullPtr)
import Penance.Json (Json (..))
import qualified Penance.Json as Json
import Penance.Json.Decode (asObject)
import Penance.Utf8 (decodeUtf8, encodeUtf8)
import Penance.LockLowerer (lowerLockInput)
import Penance.WasmPlanner (normalizeProject)
import System.Environment (getArgs)
import Text.Read (readMaybe)

foreign import ccall unsafe "copy_string"
  copyString :: Word32 -> Ptr Word8 -> Word32 -> IO Word32

foreign import ccall unsafe "make_string"
  makeString :: Ptr Word8 -> Word32 -> IO Word32

foreign import ccall unsafe "return_to_nix"
  returnToNix :: Word32 -> IO ()

foreign import ccall unsafe "panic"
  panicNix :: Ptr Word8 -> Word32 -> IO ()

main :: IO ()
main = do
  args <- getArgs
  case args of
    [valueText]
      | Just valueId <- readMaybe valueText -> do
          inputBytes <- readNixString valueId
          case decodeUtf8 inputBytes >>= dispatchPlanner of
            Left err -> abortToNix ("penance wasm planner failed: " ++ err)
            Right output -> do
              result <- makeNixString (encodeUtf8 output)
              returnToNix result
    _ -> abortToNix "penance wasm planner expected one Nix ValueId argument"

dispatchPlanner :: String -> Either String String
dispatchPlanner input = do
  fields <- Json.parseJson input >>= asObject "planner input"
  case lookup "operation" fields of
    Just (JsonString "lower-lock") -> lowerLockInput input
    Just (JsonString operation) -> Left ("unsupported planner operation `" ++ operation ++ "`")
    Just other -> Left ("planner operation must be a string, got " ++ show other)
    Nothing -> normalizeProject input

readNixString :: Word32 -> IO [Word8]
readNixString valueId = do
  lengthRequired <- copyString valueId nullPtr 0
  allocaBytes (fromIntegral lengthRequired) $ \buffer -> do
    actual <- copyString valueId buffer lengthRequired
    if actual == lengthRequired
      then peekArray (fromIntegral actual) buffer
      else abortToNix "copy_string returned an inconsistent length"

makeNixString :: [Word8] -> IO Word32
makeNixString bytes =
  withArrayLen bytes $ \lengthBytes buffer ->
    makeString buffer (fromIntegral lengthBytes)

abortToNix :: String -> IO a
abortToNix message =
  withArrayLen (encodeUtf8 message) $ \lengthBytes buffer -> do
    panicNix buffer (fromIntegral lengthBytes)
    fail message
