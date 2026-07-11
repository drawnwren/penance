module Penance.Blake3 (hashHex) where

import Data.Bits (rotateR, shiftL, shiftR, xor, (.|.))
import Data.List (foldl')
import Data.Word (Word32, Word64, Word8)
import Numeric (showHex)
import Penance.Utf8 (encodeUtf8)

data Output = Output
  { outputCv :: [Word32]
  , outputBlock :: [Word32]
  , outputCounter :: Word64
  , outputBlockLength :: Word32
  , outputFlags :: Word32
  }

hashHex :: String -> String
hashHex = concatMap hexByte . rootBytes . hashOutput . encodeUtf8

hashOutput :: [Word8] -> Output
hashOutput bytes = reduce (zipWith chunkOutput [0 ..] chunks)
  where
    chunks = if null bytes then [[]] else chunksOf 1024 bytes
    reduce [value] = value
    reduce values = reduce (pair values)
    reduce [] = error "BLAKE3 internal error: empty tree"
    pair (left : right : rest) = parentOutput left right : pair rest
    pair [value] = [value]
    pair [] = []

chunkOutput :: Word64 -> [Word8] -> Output
chunkOutput counter bytes = go iv 0 blocks
  where
    blocks = if null bytes then [[]] else chunksOf 64 bytes
    lastIndex = length blocks - 1
    go _ _ [] = error "BLAKE3 internal error: empty chunk"
    go cv index [block] =
      Output
        { outputCv = cv
        , outputBlock = blockWords block
        , outputCounter = counter
        , outputBlockLength = fromIntegral (length block)
        , outputFlags = chunkStart index .|. chunkEnd
        }
    go cv index (block : rest) =
      let flags = chunkStart index
          next = take 8 (compress cv (blockWords block) counter 64 flags)
       in go next (index + 1) rest
    chunkStart index = if index == 0 then flagChunkStart else 0
    chunkEnd = if lastIndex >= 0 then flagChunkEnd else 0

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
  zipWith xor (take 8 state) (drop 8 state)
    ++ zipWith xor (drop 8 state) cv
  where
    initial =
      cv
        ++ take 4 iv
        ++ [ fromIntegral counter
           , fromIntegral (counter `shiftR` 32)
           , blockLength
           , flags
           ]
    state = fst (iterateRound 7 (initial, take 16 (block ++ repeat 0)))

iterateRound :: Int -> ([Word32], [Word32]) -> ([Word32], [Word32])
iterateRound rounds pair0 = foldl' step pair0 [1 .. rounds]
  where
    step (state, message) _ = (roundFunction state message, permute message)

roundFunction :: [Word32] -> [Word32] -> [Word32]
roundFunction state message =
  g 3 4 9 14 (message !! 14) (message !! 15)
    . g 2 7 8 13 (message !! 12) (message !! 13)
    . g 1 6 11 12 (message !! 10) (message !! 11)
    . g 0 5 10 15 (message !! 8) (message !! 9)
    . g 3 7 11 15 (message !! 6) (message !! 7)
    . g 2 6 10 14 (message !! 4) (message !! 5)
    . g 1 5 9 13 (message !! 2) (message !! 3)
    . g 0 4 8 12 (message !! 0) (message !! 1)
    $ state

g :: Int -> Int -> Int -> Int -> Word32 -> Word32 -> [Word32] -> [Word32]
g a b c d mx my state0 = state8
  where
    va1 = at a state0 + at b state0 + mx
    state1 = put a va1 state0
    vd1 = rotateR (at d state1 `xor` at a state1) 16
    state2 = put d vd1 state1
    vc1 = at c state2 + at d state2
    state3 = put c vc1 state2
    vb1 = rotateR (at b state3 `xor` at c state3) 12
    state4 = put b vb1 state3
    va2 = at a state4 + at b state4 + my
    state5 = put a va2 state4
    vd2 = rotateR (at d state5 `xor` at a state5) 8
    state6 = put d vd2 state5
    vc2 = at c state6 + at d state6
    state7 = put c vc2 state6
    vb2 = rotateR (at b state7 `xor` at c state7) 7
    state8 = put b vb2 state7

at :: Int -> [a] -> a
at index values = values !! index

put :: Int -> a -> [a] -> [a]
put index value values = take index values ++ [value] ++ drop (index + 1) values

permute :: [a] -> [a]
permute message = map (message !!) messagePermutation

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

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf size values =
  let (prefix, suffix) = splitAt size values
   in prefix : chunksOf size suffix

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

messagePermutation :: [Int]
messagePermutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

flagChunkStart, flagChunkEnd, flagParent, flagRoot :: Word32
flagChunkStart = 1
flagChunkEnd = 2
flagParent = 4
flagRoot = 8
