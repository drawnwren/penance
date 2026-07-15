module Penance.Json
  ( Json (..)
  , array
  , bool
  , object
  , parseJson
  , renderPrettyJson
  , renderJson
  , string
  , stringArray
  )
where

import Data.Char (chr, digitToInt, intToDigit, isHexDigit, isSpace, ord)
import Data.List (sortOn)

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

stringArray :: [String] -> Json
stringArray = array . map string

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

renderPrettyJson :: Json -> String
renderPrettyJson = renderAt 0
  where
    renderAt indent value =
      case value of
        JsonObject [] -> "{}"
        JsonObject fields ->
          "{\n"
            ++ joinWith ",\n" (map (renderField indent) (sortOn fst fields))
            ++ "\n"
            ++ spaces indent
            ++ "}"
        JsonArray [] -> "[]"
        JsonArray values ->
          "[\n"
            ++ joinWith ",\n" (map (\item -> spaces (indent + 2) ++ renderAt (indent + 2) item) values)
            ++ "\n"
            ++ spaces indent
            ++ "]"
        scalar -> renderJson scalar
    renderField indent (name, value) =
      spaces (indent + 2) ++ renderString name ++ ": " ++ renderAt (indent + 2) value
    spaces count = replicate count ' '

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
    other@('t' : _) -> parseKeyword "true" (JsonBool True) other
    other@('f' : _) -> parseKeyword "false" (JsonBool False) other
    other@('n' : _) -> parseKeyword "null" JsonNull other
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
              let code = decodeHex4Int a b c d
               in if isHighSurrogate code
                    then
                      case rest of
                        '\\' : 'u' : e : f : g : h : suffix
                          | all isHexDigit [e, f, g, h]
                          , let low = decodeHex4Int e f g h
                          , isLowSurrogate low ->
                              go (chr (combineSurrogates code low) : acc) suffix
                        _ -> Left "JSON high surrogate is not followed by a low surrogate"
                    else
                      if isLowSurrogate code
                        then Left "JSON contains an unpaired low surrogate"
                        else go (chr code : acc) rest
        '\\' : escaped : _ ->
          Left ("unsupported JSON string escape: \\" ++ [escaped])
        ch : _
          | ord ch < 0x20 -> Left "JSON string contains an unescaped control character"
        ch : rest ->
          go (ch : acc) rest
        "" ->
          Left "unterminated JSON string"

parseNumber :: String -> Either String (Json, String)
parseNumber input = do
  let (sign, unsigned) =
        case input of
          '-' : rest -> ("-", rest)
          _ -> ("", input)
  (integer, afterInteger) <- parseInteger unsigned
  (fraction, afterFraction) <- parseFraction afterInteger
  (exponentText, rest) <- parseExponent afterFraction
  pure (JsonNumber (sign ++ integer ++ fraction ++ exponentText), rest)

parseInteger :: String -> Either String (String, String)
parseInteger input =
  case input of
    '0' : rest
      | startsDigit rest -> Left "JSON number has a leading zero"
      | otherwise -> Right ("0", rest)
    digit : rest
      | digit >= '1' && digit <= '9' ->
          let (digits, suffix) = span isDigitLike rest
           in Right (digit : digits, suffix)
    _ -> Left ("expected JSON integer, got: " ++ take 32 input)

parseFraction :: String -> Either String (String, String)
parseFraction input =
  case input of
    '.' : rest ->
      let (digits, suffix) = span isDigitLike rest
       in if null digits
            then Left "JSON fraction requires at least one digit"
            else Right ('.' : digits, suffix)
    _ -> Right ("", input)

parseExponent :: String -> Either String (String, String)
parseExponent input =
  case input of
    marker : rest
      | marker == 'e' || marker == 'E' ->
          let (sign, unsigned) =
                case rest of
                  prefix : unsignedRest | prefix == '+' || prefix == '-' -> ([prefix], unsignedRest)
                  _ -> ("", rest)
              (digits, suffix) = span isDigitLike unsigned
           in if null digits
                then Left "JSON exponent requires at least one digit"
                else Right (marker : sign ++ digits, suffix)
    _ -> Right ("", input)

parseKeyword :: String -> Json -> String -> Either String (Json, String)
parseKeyword keyword value input =
  case splitAt (length keyword) input of
    (actual, rest)
      | actual == keyword && not (startsIdentifier rest) -> Right (value, rest)
      | otherwise -> Left ("invalid JSON keyword: " ++ take 32 input)

startsDigit :: String -> Bool
startsDigit (ch : _) = isDigitLike ch
startsDigit [] = False

startsIdentifier :: String -> Bool
startsIdentifier (ch : _) =
  isDigitLike ch
    || (ch >= 'a' && ch <= 'z')
    || (ch >= 'A' && ch <= 'Z')
    || ch == '_'
startsIdentifier [] = False

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

decodeHex4Int :: Char -> Char -> Char -> Char -> Int
decodeHex4Int a b c d =
  digitToInt a * 4096
    + digitToInt b * 256
    + digitToInt c * 16
    + digitToInt d

isHighSurrogate :: Int -> Bool
isHighSurrogate code = code >= 0xd800 && code <= 0xdbff

isLowSurrogate :: Int -> Bool
isLowSurrogate code = code >= 0xdc00 && code <= 0xdfff

combineSurrogates :: Int -> Int -> Int
combineSurrogates high low =
  0x10000 + (high - 0xd800) * 0x400 + (low - 0xdc00)

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
