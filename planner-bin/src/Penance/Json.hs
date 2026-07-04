module Penance.Json
  ( Json (..)
  , array
  , bool
  , object
  , parseJson
  , renderJson
  , string
  )
where

import Data.Char (chr, digitToInt, intToDigit, isHexDigit, isSpace, ord)

data Json
  = JsonObject [(String, Json)]
  | JsonArray [Json]
  | JsonString String
  | JsonBool Bool
  | JsonNull
  | JsonNumber String
  deriving (Eq, Show)

object :: [(String, Json)] -> Json
object = JsonObject

array :: [Json] -> Json
array = JsonArray

string :: String -> Json
string = JsonString

bool :: Bool -> Json
bool = JsonBool

parseJson :: String -> Either String Json
parseJson input = do
  (value, rest) <- parseValue (dropWhile isSpace input)
  case dropWhile isSpace rest of
    "" -> Right value
    trailing -> Left ("unexpected trailing JSON input: " ++ take 32 trailing)

renderJson :: Json -> String
renderJson value =
  case value of
    JsonObject fields ->
      "{" ++ joinWith "," (map renderField fields) ++ "}"
    JsonArray values ->
      "[" ++ joinWith "," (map renderJson values) ++ "]"
    JsonString s ->
      renderString s
    JsonBool True ->
      "true"
    JsonBool False ->
      "false"
    JsonNull ->
      "null"
    JsonNumber n ->
      n
  where
    renderField (name, fieldValue) = renderString name ++ ":" ++ renderJson fieldValue

parseValue :: String -> Either String (Json, String)
parseValue input =
  case dropWhile isSpace input of
    '"' : rest -> do
      (value, remaining) <- parseStringChars rest
      Right (JsonString value, remaining)
    '{' : rest ->
      parseObject [] (dropWhile isSpace rest)
    '[' : rest ->
      parseArray [] (dropWhile isSpace rest)
    't' : 'r' : 'u' : 'e' : rest ->
      Right (JsonBool True, rest)
    'f' : 'a' : 'l' : 's' : 'e' : rest ->
      Right (JsonBool False, rest)
    'n' : 'u' : 'l' : 'l' : rest ->
      Right (JsonNull, rest)
    other@(c : _)
      | c == '-' || isDigitLike c ->
          parseNumber other
    "" ->
      Left "unexpected end of JSON input"
    other ->
      Left ("unexpected JSON token: " ++ take 32 other)

parseObject :: [(String, Json)] -> String -> Either String (Json, String)
parseObject fields input =
  case dropWhile isSpace input of
    '}' : rest ->
      Right (JsonObject (reverse fields), rest)
    '"' : rest -> do
      (name, afterName) <- parseStringChars rest
      afterColon <- requireChar ':' afterName
      (value, afterValue) <- parseValue afterColon
      case dropWhile isSpace afterValue of
        ',' : afterComma -> parseObject ((name, value) : fields) afterComma
        '}' : afterClose -> Right (JsonObject (reverse ((name, value) : fields)), afterClose)
        other -> Left ("expected ',' or '}' in object, got: " ++ take 32 other)
    other ->
      Left ("expected object field, got: " ++ take 32 other)

parseArray :: [Json] -> String -> Either String (Json, String)
parseArray values input =
  case dropWhile isSpace input of
    ']' : rest ->
      Right (JsonArray (reverse values), rest)
    other -> do
      (value, afterValue) <- parseValue other
      case dropWhile isSpace afterValue of
        ',' : afterComma -> parseArray (value : values) afterComma
        ']' : afterClose -> Right (JsonArray (reverse (value : values)), afterClose)
        unexpected -> Left ("expected ',' or ']' in array, got: " ++ take 32 unexpected)

parseStringChars :: String -> Either String (String, String)
parseStringChars = go []
  where
    go acc input =
      case input of
        '"' : rest ->
          Right (reverse acc, rest)
        '\\' : '"' : rest ->
          go ('"' : acc) rest
        '\\' : '\\' : rest ->
          go ('\\' : acc) rest
        '\\' : '/' : rest ->
          go ('/' : acc) rest
        '\\' : 'b' : rest ->
          go ('\b' : acc) rest
        '\\' : 'f' : rest ->
          go ('\f' : acc) rest
        '\\' : 'n' : rest ->
          go ('\n' : acc) rest
        '\\' : 'r' : rest ->
          go ('\r' : acc) rest
        '\\' : 't' : rest ->
          go ('\t' : acc) rest
        '\\' : 'u' : a : b : c : d : rest
          | all isHexDigit [a, b, c, d] ->
              go (decodeHex4 a b c d : acc) rest
        '\\' : escaped : _ ->
          Left ("unsupported JSON string escape: \\" ++ [escaped])
        ch : rest ->
          go (ch : acc) rest
        "" ->
          Left "unterminated JSON string"

parseNumber :: String -> Either String (Json, String)
parseNumber input =
  let (digits, rest) = span isNumberChar input
   in if null digits
        then Left ("expected JSON number, got: " ++ take 32 input)
        else Right (JsonNumber digits, rest)

requireChar :: Char -> String -> Either String String
requireChar expected input =
  case dropWhile isSpace input of
    actual : rest
      | actual == expected -> Right rest
    other -> Left ("expected '" ++ [expected] ++ "', got: " ++ take 32 other)

renderString :: String -> String
renderString value = '"' : concatMap renderChar value ++ "\""

renderChar :: Char -> String
renderChar ch =
  case ch of
    '"' -> "\\\""
    '\\' -> "\\\\"
    '\b' -> "\\b"
    '\f' -> "\\f"
    '\n' -> "\\n"
    '\r' -> "\\r"
    '\t' -> "\\t"
    _
      | ord ch < 0x20 -> "\\u" ++ pad4 (showHex4 (ord ch))
      | otherwise -> [ch]

decodeHex4 :: Char -> Char -> Char -> Char -> Char
decodeHex4 a b c d =
  chr
    ( digitToInt a * 4096
        + digitToInt b * 256
        + digitToInt c * 16
        + digitToInt d
    )

showHex4 :: Int -> String
showHex4 n
  | n < 16 = [intToDigit n]
  | otherwise =
      let (q, r) = n `divMod` 16
       in showHex4 q ++ [intToDigit r]

pad4 :: String -> String
pad4 text = replicate (4 - length text) '0' ++ text

joinWith :: String -> [String] -> String
joinWith _ [] = ""
joinWith _ [x] = x
joinWith separator (x : xs) = x ++ separator ++ joinWith separator xs

isDigitLike :: Char -> Bool
isDigitLike ch = ch >= '0' && ch <= '9'

isNumberChar :: Char -> Bool
isNumberChar ch =
  isDigitLike ch || ch `elem` ("-+.eE" :: String)
