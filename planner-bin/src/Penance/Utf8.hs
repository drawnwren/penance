module Penance.Utf8 (decodeUtf8, encodeUtf8) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Char (chr, ord)
import Data.Word (Word8)

encodeUtf8 :: String -> [Word8]
encodeUtf8 = concatMap encode
  where
    encode ch
      | code <= 0x7f = [fromIntegral code]
      | code <= 0x7ff =
          [ fromIntegral (0xc0 .|. (code `shiftR` 6))
          , continuation code
          ]
      | code <= 0xffff =
          [ fromIntegral (0xe0 .|. (code `shiftR` 12))
          , continuation (code `shiftR` 6)
          , continuation code
          ]
      | otherwise =
          [ fromIntegral (0xf0 .|. (code `shiftR` 18))
          , continuation (code `shiftR` 12)
          , continuation (code `shiftR` 6)
          , continuation code
          ]
      where
        code = ord ch
    continuation code = fromIntegral (0x80 .|. (code .&. 0x3f))

decodeUtf8 :: [Word8] -> Either String String
decodeUtf8 = go
  where
    go [] = Right []
    go (a : rest)
      | a < 0x80 = (chr (fromIntegral a) :) <$> go rest
      | a >= 0xc2 && a <= 0xdf = do
          (b, suffix) <- one rest
          prepend ((fromIntegral (a .&. 0x1f) `shiftL` 6) .|. fromIntegral (b .&. 0x3f)) suffix
      | a >= 0xe0 && a <= 0xef = do
          (b, c, suffix) <- two rest
          let code =
                (fromIntegral (a .&. 0x0f) `shiftL` 12)
                  .|. (fromIntegral (b .&. 0x3f) `shiftL` 6)
                  .|. fromIntegral (c .&. 0x3f)
          if code < 0x800 || (code >= 0xd800 && code <= 0xdfff)
            then Left "invalid UTF-8 sequence"
            else prepend code suffix
      | a >= 0xf0 && a <= 0xf4 = do
          (b, c, d, suffix) <- three rest
          let code =
                (fromIntegral (a .&. 0x07) `shiftL` 18)
                  .|. (fromIntegral (b .&. 0x3f) `shiftL` 12)
                  .|. (fromIntegral (c .&. 0x3f) `shiftL` 6)
                  .|. fromIntegral (d .&. 0x3f)
          if code < 0x10000 || code > 0x10ffff
            then Left "invalid UTF-8 sequence"
            else prepend code suffix
      | otherwise = Left "invalid UTF-8 leading byte"
    prepend code suffix = (chr code :) <$> go suffix
    one (b : suffix) | continuationByte b = Right (b, suffix)
    one _ = Left "truncated or invalid UTF-8 sequence"
    two (b : c : suffix) | continuationByte b && continuationByte c = Right (b, c, suffix)
    two _ = Left "truncated or invalid UTF-8 sequence"
    three (b : c : d : suffix)
      | all continuationByte [b, c, d] = Right (b, c, d, suffix)
    three _ = Left "truncated or invalid UTF-8 sequence"
    continuationByte byte = byte >= 0x80 && byte <= 0xbf
