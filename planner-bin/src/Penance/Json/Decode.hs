module Penance.Json.Decode
  ( Fields
  , asArray
  , asBool
  , asObject
  , asString
  , field
  , optionalArray
  , optionalBoolMap
  , optionalString
  , rejectUnknown
  , requiredArray
  , requiredBool
  , requiredString
  , stringArray
  )
where

import Penance.Json (Json (..))

type Fields = [(String, Json)]

asObject :: String -> Json -> Either String Fields
asObject _ (JsonObject fields) = Right fields
asObject context other = Left (context ++ " must be an object, got " ++ show other)

asArray :: String -> Json -> Either String [Json]
asArray _ (JsonArray values) = Right values
asArray context other = Left (context ++ " must be an array, got " ++ show other)

asBool :: String -> Json -> Either String Bool
asBool _ (JsonBool value) = Right value
asBool context other = Left (context ++ " must be a boolean, got " ++ show other)

asString :: String -> Json -> Either String String
asString _ (JsonString value) = Right value
asString context other = Left (context ++ " must be a string, got " ++ show other)

field :: String -> Fields -> Either String Json
field name fields =
  maybe (Left ("missing required JSON field `" ++ name ++ "`")) Right (lookup name fields)

stringArray :: String -> Json -> Either String [String]
stringArray context value = asArray context value >>= traverse (asString context)

requiredString :: String -> Fields -> Either String String
requiredString name fields = field name fields >>= asString name

requiredBool :: String -> Fields -> Either String Bool
requiredBool name fields = field name fields >>= asBool name

optionalString :: String -> Fields -> Either String (Maybe String)
optionalString name fields =
  case lookup name fields of
    Nothing -> Right Nothing
    Just JsonNull -> Right Nothing
    Just value -> Just <$> asString name value

requiredArray :: String -> (Json -> Either String a) -> Fields -> Either String [a]
requiredArray name parser fields = field name fields >>= asArray name >>= traverse parser

optionalArray :: String -> (Json -> Either String a) -> Fields -> Either String [a]
optionalArray name parser fields =
  case lookup name fields of
    Nothing -> Right []
    Just value -> asArray name value >>= traverse parser

optionalBoolMap :: String -> Fields -> Either String [(String, Bool)]
optionalBoolMap name fields =
  case lookup name fields of
    Nothing -> Right []
    Just (JsonObject values) -> traverse parseBool values
    Just other -> Left (name ++ " must be an object, got " ++ show other)
  where
    parseBool (key, JsonBool value) = Right (key, value)
    parseBool (key, other) = Left (name ++ "." ++ key ++ " must be a boolean, got " ++ show other)

rejectUnknown :: String -> [String] -> Fields -> Either String ()
rejectUnknown context allowed fields =
  case [name | (name, _) <- fields, name `notElem` allowed] of
    name : _ -> Left (context ++ " contains unknown field `" ++ name ++ "`")
    [] -> Right ()
