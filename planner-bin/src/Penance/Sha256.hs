module Penance.Sha256
  ( NixBase32Sha256
  , nixBase32Sha256
  , renderNixBase32Sha256
  , sha256Hex
  )
where

import Data.Bits (complement, rotateR, shiftL, shiftR, xor, (.&.), (.|.))
import Data.Word (Word32, Word64, Word8)
import Penance.List (chunksOf)
import Penance.Utf8 (encodeUtf8)
import Numeric (showHex)

data HashState = HashState
  !Word32 !Word32 !Word32 !Word32
  !Word32 !Word32 !Word32 !Word32

data ScheduleWindow = ScheduleWindow
  !Word32 !Word32 !Word32 !Word32
  !Word32 !Word32 !Word32 !Word32
  !Word32 !Word32 !Word32 !Word32
  !Word32 !Word32 !Word32 !Word32

newtype NixBase32Sha256 = NixBase32Sha256 String
  deriving (Eq, Ord, Show)

nixBase32Sha256 :: String -> NixBase32Sha256
nixBase32Sha256 = NixBase32Sha256 . encodeNixBase32 . sha256 . encodeUtf8

renderNixBase32Sha256 :: NixBase32Sha256 -> String
renderNixBase32Sha256 (NixBase32Sha256 digest) = digest

sha256Hex :: String -> String
sha256Hex = concatMap hexByte . sha256 . encodeUtf8
  where
    hexByte byte =
      case showHex byte "" of
        [digit] -> ['0', digit]
        digits -> digits

sha256 :: [Word8] -> [Word8]
sha256 input = concatMap wordBytes (stateWords (foldl' compress initialHash (chunksOf 64 (pad input))))

pad :: [Word8] -> [Word8]
pad bytes = bytes ++ [0x80] ++ replicate paddingLength 0 ++ word64Bytes (fromIntegral (length bytes) * 8)
  where
    paddingLength = (56 - ((length bytes + 1) `mod` 64)) `mod` 64

compress :: HashState -> [Word8] -> HashState
compress hashState chunk = addState hashState finalState
  where
    schedule = extendSchedule (map bigWord (chunksOf 4 chunk))
    finalState = foldl' roundStep hashState (zip roundConstants schedule)

roundStep :: HashState -> (Word32, Word32) -> HashState
roundStep (HashState a b c d e f g h) (constant, message) =
  HashState (temp1 + temp2) a b c (d + temp1) e f g
  where
    choice = (e .&. f) `xor` (complement e .&. g)
    majority = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
    upperSigma0 = rotateR a 2 `xor` rotateR a 13 `xor` rotateR a 22
    upperSigma1 = rotateR e 6 `xor` rotateR e 11 `xor` rotateR e 25
    temp1 = h + upperSigma1 + choice + constant + message
    temp2 = upperSigma0 + majority

addState :: HashState -> HashState -> HashState
addState
  (HashState a b c d e f g h)
  (HashState a' b' c' d' e' f' g' h') =
    HashState (a + a') (b + b') (c + c') (d + d') (e + e') (f + f') (g + g') (h + h')

stateWords :: HashState -> [Word32]
stateWords (HashState a b c d e f g h) = [a, b, c, d, e, f, g, h]

extendSchedule :: [Word32] -> [Word32]
extendSchedule initial = initialWords ++ reverse (go (scheduleWindow initialWords) 16 [])
  where
    initialWords = take 16 (initial ++ repeat 0)
    go :: ScheduleWindow -> Int -> [Word32] -> [Word32]
    go _ index acc
      | index == 64 = acc
    go (ScheduleWindow w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15) index acc =
      let sigma0 = rotateR w1 7 `xor` rotateR w1 18 `xor` shiftR w1 3
          sigma1 = rotateR w14 17 `xor` rotateR w14 19 `xor` shiftR w14 10
          next = sigma1 + w9 + sigma0 + w0
       in go
            (ScheduleWindow w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 next)
            (index + 1)
            (next : acc)

scheduleWindow :: [Word32] -> ScheduleWindow
scheduleWindow values =
  case take 16 (values ++ repeat 0) of
    [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p] ->
      ScheduleWindow a b c d e f g h i j k l m n o p
    _ -> ScheduleWindow 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

encodeNixBase32 :: [Word8] -> String
encodeNixBase32 digest = map encodeGroup [groupCount - 1, groupCount - 2 .. 0]
  where
    groupCount = (length digest * 8 + 4) `div` 5
    encodeGroup group = alphabet !! (combined .&. 0x1f)
      where
        bit = group * 5
        byteIndex = bit `div` 8
        offset = bit `mod` 8
        current = fromIntegral (digest !! byteIndex) `shiftR` offset
        following =
          if byteIndex + 1 < length digest
            then fromIntegral (digest !! (byteIndex + 1)) `shiftL` (8 - offset)
            else 0
        combined = current .|. following

bigWord :: [Word8] -> Word32
bigWord = foldl' (\word byte -> shiftL word 8 .|. fromIntegral byte) 0

wordBytes :: Word32 -> [Word8]
wordBytes word = [fromIntegral (shiftR word shift) | shift <- [24, 16, 8, 0]]

word64Bytes :: Word64 -> [Word8]
word64Bytes word = [fromIntegral (shiftR word shift) | shift <- [56, 48, 40, 32, 24, 16, 8, 0]]

alphabet :: String
alphabet = "0123456789abcdfghijklmnpqrsvwxyz"

initialHash :: HashState
initialHash =
  HashState
    0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a
    0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19

roundConstants :: [Word32]
roundConstants =
  [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
  , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
  , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
  , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
  , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
  , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
  , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
  , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]
