module Penance.Utf8 (decodeUtf8, decodeUtf8Indexed, encodeUtf8) where

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
      | code >= 0xd800 && code <= 0xdfff = replacementCharacter
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
    replacementCharacter = [0xef, 0xbf, 0xbd]
    continuation code = fromIntegral (0x80 .|. (code .&. 0x3f))

decodeUtf8 :: [Word8] -> Either String String
decodeUtf8 = fmap reverse . go []
  where
    go acc [] = Right acc
    go acc (a : rest)
      | a < 0x80 = go (chr (fromIntegral a) : acc) rest
      | a >= 0xc2 && a <= 0xdf = do
          (b, suffix) <- one rest
          prepend acc ((fromIntegral (a .&. 0x1f) `shiftL` 6) .|. fromIntegral (b .&. 0x3f)) suffix
      | a >= 0xe0 && a <= 0xef = do
          (b, c, suffix) <- two rest
          let code =
                (fromIntegral (a .&. 0x0f) `shiftL` 12)
                  .|. (fromIntegral (b .&. 0x3f) `shiftL` 6)
                  .|. fromIntegral (c .&. 0x3f)
          if code < 0x800 || (code >= 0xd800 && code <= 0xdfff)
            then Left "invalid UTF-8 sequence"
            else prepend acc code suffix
      | a >= 0xf0 && a <= 0xf4 = do
          (b, c, d, suffix) <- three rest
          let code =
                (fromIntegral (a .&. 0x07) `shiftL` 18)
                  .|. (fromIntegral (b .&. 0x3f) `shiftL` 12)
                  .|. (fromIntegral (c .&. 0x3f) `shiftL` 6)
                  .|. fromIntegral (d .&. 0x3f)
          if code < 0x10000 || code > 0x10ffff
            then Left "invalid UTF-8 sequence"
            else prepend acc code suffix
      | otherwise = Left "invalid UTF-8 leading byte"
    prepend acc code suffix = go (chr code : acc) suffix
    one (b : suffix) | continuationByte b = Right (b, suffix)
    one _ = Left "truncated or invalid UTF-8 sequence"
    two (b : c : suffix) | continuationByte b && continuationByte c = Right (b, c, suffix)
    two _ = Left "truncated or invalid UTF-8 sequence"
    three (b : c : d : suffix)
      | all continuationByte [b, c, d] = Right (b, c, d, suffix)
    three _ = Left "truncated or invalid UTF-8 sequence"
    continuationByte byte = byte >= 0x80 && byte <= 0xbf

decodeUtf8Indexed :: Int -> (Int -> Word8) -> Either String String
decodeUtf8Indexed size byteAt = fmap reverse (go 0 [])
  where
    go index acc
      | index == size = Right acc
      | otherwise =
          let a = byteAt index
           in if a < 0x80
                then go (index + 1) (chr (fromIntegral a) : acc)
                else
                  if a >= 0xc2 && a <= 0xdf
                    then decode2 index acc a
                    else
                      if a >= 0xe0 && a <= 0xef
                        then decode3 index acc a
                        else
                          if a >= 0xf0 && a <= 0xf4
                            then decode4 index acc a
                            else Left "invalid UTF-8 leading byte"

    decode2 index acc a = do
      b <- continuationAt (index + 1)
      go (index + 2) (chr (((fromIntegral (a .&. 0x1f)) `shiftL` 6) .|. fromIntegral (b .&. 0x3f)) : acc)

    decode3 index acc a = do
      b <- continuationAt (index + 1)
      c <- continuationAt (index + 2)
      let code =
            (fromIntegral (a .&. 0x0f) `shiftL` 12)
              .|. (fromIntegral (b .&. 0x3f) `shiftL` 6)
              .|. fromIntegral (c .&. 0x3f)
      if code < 0x800 || (code >= 0xd800 && code <= 0xdfff)
        then Left "invalid UTF-8 sequence"
        else go (index + 3) (chr code : acc)

    decode4 index acc a = do
      b <- continuationAt (index + 1)
      c <- continuationAt (index + 2)
      d <- continuationAt (index + 3)
      let code =
            (fromIntegral (a .&. 0x07) `shiftL` 18)
              .|. (fromIntegral (b .&. 0x3f) `shiftL` 12)
              .|. (fromIntegral (c .&. 0x3f) `shiftL` 6)
              .|. fromIntegral (d .&. 0x3f)
      if code < 0x10000 || code > 0x10ffff
        then Left "invalid UTF-8 sequence"
        else go (index + 4) (chr code : acc)

    continuationAt index
      | index >= size = Left "truncated or invalid UTF-8 sequence"
      | continuationByte (byteAt index) = Right (byteAt index)
      | otherwise = Left "truncated or invalid UTF-8 sequence"
    continuationByte byte = byte >= 0x80 && byte <= 0xbf
