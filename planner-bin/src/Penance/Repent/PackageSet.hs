module Penance.Repent.PackageSet
  ( PackageSet
  , decodePackageSet
  , packageSetCompiler
  , packageSetConstraints
  , extendPackageSetWithPlan
  , packageSetFromPlan
  , packageSetHash
  , packageSetIndexState
  , packageSetNix
  , packageSetStackage
  , validatePackageSetPlan
  )
where

import Control.Monad (unless)
import Data.List (sortOn)
import qualified Data.Set as Set
import Distribution.Pretty (prettyShow)
import Penance.Blake3 (hashHex)
import Penance.CabalPlan
  ( ExternalSource (..)
  , ExternalUnit (..)
  , ResolvedPlan (..)
  , renderFlagAssignment
  )
import qualified Penance.CabalPlan as CabalPlan
import Penance.Json (Json (..))
import qualified Penance.Json as Json
import Penance.Json.Decode
  ( asObject
  , field
  , optionalBoolMap
  , optionalString
  , rejectUnknown
  , requiredString
  )
import Penance.Sha256 (sha256Hex)
import Penance.Types
  ( CompilerId (..)
  , IndexState (..)
  , renderCompilerId
  , renderIndexState
  )

data PackageSet = PackageSet
  { packageSetCompiler :: CompilerId
  , packageSetIndexState :: IndexState
  , packageSetStackage :: Maybe String
  , packageSetPackages :: [PackageRecipe]
  }
  deriving (Eq, Show)

data PackageRecipe = PackageRecipe
  { recipeName :: String
  , recipeVersion :: String
  , recipeFlags :: [(String, Bool)]
  , recipeFlagHash :: String
  , recipeNixExpression :: FilePath
  , recipeSdistUrl :: String
  , recipeSdistSha256 :: String
  }
  deriving (Eq, Ord, Show)

packageSetFromPlan :: CompilerId -> IndexState -> Maybe String -> ResolvedPlan -> Either String PackageSet
packageSetFromPlan compiler indexState stackage plan = do
  recipes <- traverse recipeFromUnit hackageUnits
  validateRecipes recipes
  pure
    PackageSet
      { packageSetCompiler = compiler
      , packageSetIndexState = indexState
      , packageSetStackage = stackage
      , packageSetPackages = sortOn recipeKey recipes
      }
  where
    hackageUnits =
      [ unit
      | unit <- resolvedExternalUnits plan
      , HackageSdist {} <- [externalUnitSource unit]
      ]

extendPackageSetWithPlan :: PackageSet -> ResolvedPlan -> Either String PackageSet
extendPackageSetWithPlan packageSet plan = do
  additions <- traverse recipeFromUnit hackageUnits
  let recipes = unique (packageSetPackages packageSet ++ additions)
  validateRecipes recipes
  pure packageSet {packageSetPackages = sortOn recipeKey recipes}
  where
    hackageUnits =
      [ unit
      | unit <- resolvedExternalUnits plan
      , HackageSdist {} <- [externalUnitSource unit]
      ]

decodePackageSet :: String -> Either String PackageSet
decodePackageSet contents = do
  root <- Json.parseJson contents >>= asObject "package set"
  rejectUnknown "package set" ["schema", "compiler", "indexState", "stackage", "packages"] root
  schema <- requiredString "schema" root
  unlessEither (schema == "penance/package-set/2") "package set schema must be `penance/package-set/2`"
  compiler <- CompilerId <$> requiredString "compiler" root
  indexState <- IndexState <$> requiredString "indexState" root
  stackage <- optionalString "stackage" root
  packages <- field "packages" root >>= asObject "packages"
  recipes <- concat <$> traverse decodePackage packages
  validateRecipes recipes
  pure
    PackageSet
      { packageSetCompiler = compiler
      , packageSetIndexState = indexState
      , packageSetStackage = stackage
      , packageSetPackages = sortOn recipeKey recipes
      }

packageSetValue :: PackageSet -> Json
packageSetValue packageSet =
  Json.object
    [ ("compiler", Json.string (renderCompilerId (packageSetCompiler packageSet)))
    , ("indexState", Json.string (renderIndexState (packageSetIndexState packageSet)))
    , ("packages", Json.object (map packageJson groupedRecipes))
    , ("schema", Json.string "penance/package-set/2")
    , ("stackage", maybe Json.JsonNull Json.string (packageSetStackage packageSet))
    ]
  where
    groupedRecipes =
      [ (name, [recipe | recipe <- packageSetPackages packageSet, recipeName recipe == name])
      | name <- unique (map recipeName (packageSetPackages packageSet))
      ]

packageSetNix :: PackageSet -> String
packageSetNix packageSet = renderNix 0 (packageSetValue packageSet) ++ "\n"

packageSetHash :: PackageSet -> String
packageSetHash packageSet = "sha256:" ++ sha256Hex (Json.renderJson (packageSetValue packageSet))

packageSetConstraints :: PackageSet -> [String]
packageSetConstraints packageSet =
  [ name ++ "==" ++ version
  | (name, version) <- unique (map (\recipe -> (recipeName recipe, recipeVersion recipe)) recipes)
  ]
  where
    recipes = packageSetPackages packageSet

validatePackageSetPlan :: PackageSet -> ResolvedPlan -> Either String ()
validatePackageSetPlan packageSet plan =
  traverse_ validateUnit hackageUnits
  where
    recipes = packageSetPackages packageSet
    hackageUnits =
      [ unit
      | unit <- resolvedExternalUnits plan
      , HackageSdist {} <- [externalUnitSource unit]
      ]
    validateUnit unit = do
      recipe <- recipeFromUnit unit
      unlessEither
        (recipe `elem` recipes)
        ( "package set does not permit solved Hackage unit `"
            ++ recipeName recipe
            ++ "-"
            ++ recipeVersion recipe
            ++ "` with flag hash `"
            ++ recipeFlagHash recipe
            ++ "`"
        )

decodePackage :: (String, Json) -> Either String [PackageRecipe]
decodePackage (name, value) = do
  fields <- asObject ("package-set package `" ++ name ++ "`") value
  rejectUnknown ("package-set package `" ++ name ++ "`") ["version", "recipes"] fields
  version <- requiredString "version" fields
  recipes <- field "recipes" fields >>= asObject ("package-set package `" ++ name ++ "` recipes")
  traverse (decodeRecipe name version) recipes

decodeRecipe :: String -> String -> (String, Json) -> Either String PackageRecipe
decodeRecipe name version (recipeKeyValue, value) = do
  fields <- asObject "package-set package" value
  rejectUnknown
    "package-set package"
    ["flags", "flagHash", "nixExpression", "sdist"]
    fields
  flags <- sortOn fst <$> optionalBoolMap "flags" fields
  flagHash <- requiredString "flagHash" fields
  nixExpression <- requiredString "nixExpression" fields
  sdist <- field "sdist" fields >>= asObject "sdist"
  rejectUnknown "package-set package sdist" ["url", "sha256"] sdist
  url <- requiredString "url" sdist
  sha256 <- requiredString "sha256" sdist
  let recipe =
        PackageRecipe
          { recipeName = name
          , recipeVersion = version
          , recipeFlags = flags
          , recipeFlagHash = flagHash
          , recipeNixExpression = nixExpression
          , recipeSdistUrl = url
          , recipeSdistSha256 = sha256
          }
  unlessEither
    (recipeKeyValue == flagHash)
    ("package-set package `" ++ name ++ "` recipe key does not match its flagHash")
  validateRecipe recipe
  pure recipe

recipeFromUnit :: ExternalUnit -> Either String PackageRecipe
recipeFromUnit unit =
  case externalUnitSource unit of
    GhcBoot -> Left "internal error: GHC boot unit cannot become a package-set recipe"
    HackageSdist url sha256 ->
      let name = prettyShow (externalUnitName unit)
          version = prettyShow (externalUnitVersion unit)
          flags = renderFlagAssignment (externalUnitFlags unit)
          flagHash = flagHashFor flags
       in Right
            PackageRecipe
              { recipeName = name
              , recipeVersion = version
              , recipeFlags = flags
              , recipeFlagHash = flagHash
              , recipeNixExpression = name ++ "-" ++ version ++ "-" ++ flagHash ++ ".nix"
              , recipeSdistUrl = CabalPlan.renderHackageUrl url
              , recipeSdistSha256 = CabalPlan.renderSdistHash sha256
              }

validateRecipes :: [PackageRecipe] -> Either String ()
validateRecipes recipes = do
  traverse_ validateRecipe recipes
  unlessEither
    (length recipes == length (unique recipes))
    "package set contains duplicate package recipes"
  let versionsByName = [(recipeName recipe, recipeVersion recipe) | recipe <- recipes]
      conflictingNames =
        [ name
        | name <- unique (map fst versionsByName)
        , length (unique [version | (candidate, version) <- versionsByName, candidate == name]) > 1
        ]
  case conflictingNames of
    name : _ -> Left ("package set contains multiple versions of `" ++ name ++ "`")
    [] -> Right ()

validateRecipe :: PackageRecipe -> Either String ()
validateRecipe recipe = do
  let expectedFlagHash = flagHashFor (recipeFlags recipe)
      expectedExpression =
        recipeName recipe ++ "-" ++ recipeVersion recipe ++ "-" ++ expectedFlagHash ++ ".nix"
  unlessEither (not (null (recipeName recipe))) "package-set package name must not be empty"
  unlessEither (not (null (recipeVersion recipe))) "package-set package version must not be empty"
  unlessEither
    (recipeFlagHash recipe == expectedFlagHash)
    ("package-set package `" ++ recipeName recipe ++ "` has an invalid flagHash")
  unlessEither
    (recipeNixExpression recipe == expectedExpression)
    ("package-set package `" ++ recipeName recipe ++ "` has an invalid nixExpression")
  unlessEither (not (null (recipeSdistUrl recipe))) "package-set sdist URL must not be empty"
  unlessEither (not (null (recipeSdistSha256 recipe))) "package-set sdist hash must not be empty"

packageJson :: (String, [PackageRecipe]) -> (String, Json)
packageJson (name, recipes) =
  ( name
  , Json.object
      [ ("recipes", Json.object [(recipeFlagHash recipe, recipeJson recipe) | recipe <- recipes])
      , ("version", Json.string (recipeVersion (head recipes)))
      ]
  )

recipeJson :: PackageRecipe -> Json
recipeJson recipe =
  Json.object
    [ ("flagHash", Json.string (recipeFlagHash recipe))
    , ("flags", flagAssignmentJson (recipeFlags recipe))
    , ("nixExpression", Json.string (recipeNixExpression recipe))
    , ( "sdist"
      , Json.object
          [ ("sha256", Json.string (recipeSdistSha256 recipe))
          , ("url", Json.string (recipeSdistUrl recipe))
          ]
      )
    ]

renderNix :: Int -> Json -> String
renderNix indent value =
  case value of
    JsonObject [] -> "{ }"
    JsonObject fields ->
      "{\n"
        ++ joinLines
          [ spaces (indent + 2)
              ++ renderNixString name
              ++ " = "
              ++ renderNix (indent + 2) fieldValue
              ++ ";"
          | (name, fieldValue) <- fields
          ]
        ++ "\n"
        ++ spaces indent
        ++ "}"
    JsonArray [] -> "[ ]"
    JsonArray values ->
      "[\n"
        ++ joinLines [spaces (indent + 2) ++ renderNix (indent + 2) item | item <- values]
        ++ "\n"
        ++ spaces indent
        ++ "]"
    JsonString text -> renderNixString text
    JsonBool True -> "true"
    JsonBool False -> "false"
    JsonNull -> "null"
    JsonNumber number -> number

renderNixString :: String -> String
renderNixString value = '"' : escape value ++ "\""
  where
    escape input =
      case input of
        [] -> []
        '$' : '{' : rest -> "\\${" ++ escape rest
        '"' : rest -> "\\\"" ++ escape rest
        '\\' : rest -> "\\\\" ++ escape rest
        '\n' : rest -> "\\n" ++ escape rest
        '\r' : rest -> "\\r" ++ escape rest
        '\t' : rest -> "\\t" ++ escape rest
        char : rest -> char : escape rest

joinLines :: [String] -> String
joinLines = foldr (\line rest -> if null rest then line else line ++ "\n" ++ rest) ""

spaces :: Int -> String
spaces count = replicate count ' '

recipeKey :: PackageRecipe -> (String, String, String)
recipeKey recipe = (recipeName recipe, recipeVersion recipe, recipeFlagHash recipe)

flagHashFor :: [(String, Bool)] -> String
flagHashFor = take 12 . hashHex . Json.renderJson . flagAssignmentJson

flagAssignmentJson :: [(String, Bool)] -> Json
flagAssignmentJson assignment = Json.object [(name, Json.bool enabled) | (name, enabled) <- sortOn fst assignment]

unlessEither :: Bool -> String -> Either String ()
unlessEither condition message = unless condition (Left message)

traverse_ :: (a -> Either String ()) -> [a] -> Either String ()
traverse_ action = foldr (\value rest -> action value >> rest) (Right ())

unique :: Ord a => [a] -> [a]
unique = Set.toAscList . Set.fromList
