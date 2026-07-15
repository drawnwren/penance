module Penance.Blake3
  ( Blake3Digest
  , hash
  , hashHex
  , parseBlake3Digest
  , renderBlake3Digest
  )
where

import Data.Bits (rotateR, shiftL, shiftR, xor, (.|.))
import Data.Char (isHexDigit)
import Data.Word (Word32, Word64, Word8)
import Numeric (showHex)
import Penance.List (chunksOf)
import Penance.Utf8 (encodeUtf8)

data Output = Output
  { outputCv :: [Word32]
  , outputBlock :: [Word32]
  , outputCounter :: Word64
  , outputBlockLength :: Word32
  , outputFlags :: Word32
  }

data State16 = State16
  !Word32 !Word32 !Word32 !Word32
  !Word32 !Word32 !Word32 !Word32
  !Word32 !Word32 !Word32 !Word32
  !Word32 !Word32 !Word32 !Word32

newtype Blake3Digest = Blake3Digest String
  deriving (Eq, Ord, Show)

hash :: String -> Blake3Digest
hash = Blake3Digest . concatMap hexByte . rootBytes . hashOutput . encodeUtf8

hashHex :: String -> String
hashHex = renderBlake3Digest . hash

renderBlake3Digest :: Blake3Digest -> String
renderBlake3Digest (Blake3Digest digest) = digest

parseBlake3Digest :: String -> Either String Blake3Digest
parseBlake3Digest digest
  | length digest == 64 && all isHexDigit digest = Right (Blake3Digest digest)
  | otherwise = Left "BLAKE3 digest must contain exactly 64 hexadecimal digits"

hashOutput :: [Word8] -> Output
hashOutput bytes = reduce (zipWith chunkOutput [0 ..] chunks)
  where
    chunks = if null bytes then [[]] else chunksOf 1024 bytes
    reduce [value] = value
    reduce values = reduce (pair values)
    pair (left : right : rest) = parentOutput left right : pair rest
    pair [value] = [value]
    pair [] = []

chunkOutput :: Word64 -> [Word8] -> Output
chunkOutput counter bytes =
  case if null bytes then [[]] else chunksOf 64 bytes of
    block : rest -> go iv 0 block rest
    [] -> finalOutput iv 0 []
  where
    go :: [Word32] -> Int -> [Word8] -> [[Word8]] -> Output
    go cv index block [] = finalOutput cv index block
    go cv index block (next : rest) =
      let flags = chunkStart index
          nextCv = take 8 (compress cv (blockWords block) counter 64 flags)
       in go nextCv (index + 1) next rest
    finalOutput :: [Word32] -> Int -> [Word8] -> Output
    finalOutput cv index block =
      Output
        { outputCv = cv
        , outputBlock = blockWords block
        , outputCounter = counter
        , outputBlockLength = fromIntegral (length block)
        , outputFlags = chunkStart index .|. flagChunkEnd
        }
    chunkStart index = if index == 0 then flagChunkStart else 0

parentOutput :: Output -> Output -> Output
parentOutput left right =
  Output
    { outputCv = iv
    , outputBlock = chainingValue left ++ chainingValue right
    , outputCounter = 0
    , outputBlockLength = 64
    , outputFlags = flagParent
    }

chainingValue :: Output -> [Word32]
chainingValue output =
  take 8
    ( compress
        (outputCv output)
        (outputBlock output)
        (outputCounter output)
        (outputBlockLength output)
        (outputFlags output)
    )

rootBytes :: Output -> [Word8]
rootBytes output =
  take 32
    ( concatMap wordBytes
        ( compress
            (outputCv output)
            (outputBlock output)
            0
            (outputBlockLength output)
            (outputFlags output .|. flagRoot)
        )
    )

compress :: [Word32] -> [Word32] -> Word64 -> Word32 -> Word32 -> [Word32]
compress cv block counter blockLength flags =
  zipWith xor (take 8 words_) (drop 8 words_)
    ++ zipWith xor (drop 8 words_) cv
  where
    initial = state16 (cv ++ take 4 iv ++ [fromIntegral counter, fromIntegral (counter `shiftR` 32), blockLength, flags])
    message = state16 (take 16 (block ++ repeat 0))
    words_ = stateWords (iterateRounds 7 initial message)

iterateRounds :: Int -> State16 -> State16 -> State16
iterateRounds 0 state _ = state
iterateRounds count state message =
  iterateRounds (count - 1) (roundFunction state message) (permute message)

roundFunction :: State16 -> State16 -> State16
roundFunction
  (State16 v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15)
  (State16 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15) =
    State16 w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15
    where
      (c0, c4, c8, c12) = gMix v0 v4 v8 v12 m0 m1
      (c1, c5, c9, c13) = gMix v1 v5 v9 v13 m2 m3
      (c2, c6, c10, c14) = gMix v2 v6 v10 v14 m4 m5
      (c3, c7, c11, c15) = gMix v3 v7 v11 v15 m6 m7
      (w0, w5, w10, w15) = gMix c0 c5 c10 c15 m8 m9
      (w1, w6, w11, w12) = gMix c1 c6 c11 c12 m10 m11
      (w2, w7, w8, w13) = gMix c2 c7 c8 c13 m12 m13
      (w3, w4, w9, w14) = gMix c3 c4 c9 c14 m14 m15

gMix :: Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> (Word32, Word32, Word32, Word32)
gMix a0 b0 c0 d0 mx my = (a2, b2, c2, d2)
  where
    a1 = a0 + b0 + mx
    d1 = rotateR (d0 `xor` a1) 16
    c1 = c0 + d1
    b1 = rotateR (b0 `xor` c1) 12
    a2 = a1 + b1 + my
    d2 = rotateR (d1 `xor` a2) 8
    c2 = c1 + d2
    b2 = rotateR (b1 `xor` c2) 7

permute :: State16 -> State16
permute (State16 m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m15) =
  State16 m2 m6 m3 m10 m7 m0 m4 m13 m1 m11 m12 m5 m9 m14 m15 m8

state16 :: [Word32] -> State16
state16 values =
  case take 16 (values ++ repeat 0) of
    [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p] ->
      State16 a b c d e f g h i j k l m n o p
    _ -> State16 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

stateWords :: State16 -> [Word32]
stateWords (State16 a b c d e f g h i j k l m n o p) =
  [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p]

blockWords :: [Word8] -> [Word32]
blockWords bytes = map littleWord (chunksOf 4 (take 64 (bytes ++ repeat 0)))

littleWord :: [Word8] -> Word32
littleWord bytes =
  foldl'
    (\word (offset, byte) -> word .|. (fromIntegral byte `shiftL` (8 * offset)))
    0
    (zip [0 ..] bytes)

wordBytes :: Word32 -> [Word8]
wordBytes word = [fromIntegral (word `shiftR` shift) | shift <- [0, 8, 16, 24]]

hexByte :: Word8 -> String
hexByte byte =
  case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

iv :: [Word32]
iv =
  [ 0x6A09E667
  , 0xBB67AE85
  , 0x3C6EF372
  , 0xA54FF53A
  , 0x510E527F
  , 0x9B05688C
  , 0x1F83D9AB
  , 0x5BE0CD19
  ]

flagChunkStart, flagChunkEnd, flagParent, flagRoot :: Word32
flagChunkStart = 1
flagChunkEnd = 2
flagParent = 4
flagRoot = 8
