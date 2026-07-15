module Penance.Utf8.IO
  ( appendUtf8File
  , readUtf8File
  , readUtf8Stdin
  , writeUtf8File
  )
where

import qualified Data.ByteString as BS
import Penance.Utf8 (decodeUtf8Indexed, encodeUtf8)

readUtf8File :: FilePath -> IO String
readUtf8File path = do
  bytes <- BS.readFile path
  decodeBytes path bytes

readUtf8Stdin :: IO String
readUtf8Stdin = BS.getContents >>= decodeBytes "stdin"

decodeBytes :: String -> BS.ByteString -> IO String
decodeBytes source bytes =
  case decodeUtf8Indexed (BS.length bytes) (BS.index bytes) of
    Left err -> ioError (userError (source ++ ": " ++ err))
    Right contents -> pure contents

writeUtf8File :: FilePath -> String -> IO ()
writeUtf8File path = BS.writeFile path . BS.pack . encodeUtf8

appendUtf8File :: FilePath -> String -> IO ()
appendUtf8File path = BS.appendFile path . BS.pack . encodeUtf8
