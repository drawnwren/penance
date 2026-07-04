module Penance.Graph.Backpack
  ( backpackDrvEntries
  , emitBootstrap
  )
where

import Data.List (intercalate)
import qualified Penance.Json as Json
import Penance.Json (array, object, string)
import Penance.Plan
  ( BackpackSkeleton (..)
  , ExpectedInstantiation (..)
  , IndefiniteUnit (..)
  , ProjectSkeleton (..)
  , backpack
  , drvFileFor
  , skeletonPath
  , writeJsonFile
  )
import System.Directory (copyFile, createDirectoryIfMissing)
import System.FilePath ((</>))

data BackpackEntry
  = SignatureTypecheck IndefiniteUnit FilePath
  | SignatureInterface IndefiniteUnit String FilePath
  | InstantiationPlan ExpectedInstantiation FilePath
  deriving (Eq, Show)

backpackDrvEntries :: ProjectSkeleton -> [(String, FilePath)]
backpackDrvEntries skeleton =
  map entryKeyPath (backpackEntries skeleton)
  where
    entryKeyPath entry =
      case entry of
        SignatureTypecheck unit path ->
          (indefiniteUnit unit ++ ":typecheck", path)
        SignatureInterface unit signature path ->
          (indefiniteUnit unit ++ ":" ++ signature, path)
        InstantiationPlan instantiation path ->
          (instantiationKey instantiation, path)

emitBootstrap :: ProjectSkeleton -> FilePath -> IO ()
emitBootstrap skeleton out = do
  let dir = out </> "signatures"
  createDirectoryIfMissing True dir
  createDirectoryIfMissing True (out </> "instantiations")
  copyFile (skeletonPath skeleton) (dir </> "backpack-graph.bootstrap.json")
  writeJsonFile (dir </> "backpack-graph.json") (backpackGraphJson skeleton)
  mapM_ (writeBackpackPlan out) (backpackEntries skeleton)

backpackEntries :: ProjectSkeleton -> [BackpackEntry]
backpackEntries skeleton =
  typecheckEntries ++ signatureEntries ++ instantiationEntries
  where
    bp = backpack skeleton
    typecheckEntries =
      [ SignatureTypecheck unit ("signatures" </> drvFileFor (indefiniteUnit unit ++ ":typecheck"))
      | unit <- indefiniteUnits bp
      ]
    signatureEntries =
      [ SignatureInterface
          unit
          signature
          ("signatures" </> drvFileFor (indefiniteUnit unit ++ ":" ++ signature))
      | unit <- indefiniteUnits bp
      , signature <- indefiniteSignatures unit
      ]
    instantiationEntries =
      [ InstantiationPlan
          instantiation
          ("instantiations" </> drvFileFor (instantiationKey instantiation))
      | instantiation <- expectedInstantiations bp
      ]

backpackGraphJson :: ProjectSkeleton -> Json.Json
backpackGraphJson skeleton =
  object
    [ ("kind", string "backpackGraph")
    , ("status", string "planned")
    , ("projectKey", string (projectKey skeleton))
    , ("planCacheKey", string (planCacheKey skeleton))
    , ("granularity", string (granularity skeleton))
    , ("indefiniteUnits", array (map indefiniteUnitJson (indefiniteUnits (backpack skeleton))))
    , ("expectedInstantiations", array (map instantiationJson (expectedInstantiations (backpack skeleton))))
    , ("plannedDrvs", array (map backpackEntryJson (backpackEntries skeleton)))
    ]

indefiniteUnitJson :: IndefiniteUnit -> Json.Json
indefiniteUnitJson unit =
  object
    [ ("unit", string (indefiniteUnit unit))
    , ("package", string (indefinitePackage unit))
    , ("component", string (indefiniteComponent unit))
    , ("signatures", array (map string (indefiniteSignatures unit)))
    , ("requiredSignatures", array (map string (indefiniteRequiredSignatures unit)))
    , ("mixins", array (map string (indefiniteMixins unit)))
    , ("reexportedModules", array (map string (indefiniteReexportedModules unit)))
    ]

instantiationJson :: ExpectedInstantiation -> Json.Json
instantiationJson instantiation =
  object
    [ ("unit", string (instantiationUnit instantiation))
    , ("holes", object (map holeJson (instantiationHoles instantiation)))
    , ("instantiationKey", string (instantiationKey instantiation))
    ]
  where
    holeJson (hole, provider) = (hole, string provider)

backpackEntryJson :: BackpackEntry -> Json.Json
backpackEntryJson entry =
  case entry of
    SignatureTypecheck unit path ->
      object
        [ ("kind", string "signatureTypecheckDrv")
        , ("unit", string (indefiniteUnit unit))
        , ("drvPlan", string path)
        ]
    SignatureInterface unit signature path ->
      object
        [ ("kind", string "signatureDrv")
        , ("unit", string (indefiniteUnit unit))
        , ("signature", string signature)
        , ("drvPlan", string path)
        ]
    InstantiationPlan instantiation path ->
      object
        [ ("kind", string "instantiationDrv")
        , ("unit", string (instantiationUnit instantiation))
        , ("instantiationKey", string (instantiationKey instantiation))
        , ("drvPlan", string path)
        ]

writeBackpackPlan :: FilePath -> BackpackEntry -> IO ()
writeBackpackPlan out entry =
  case entry of
    SignatureTypecheck unit path ->
      writePlan path
        ( object
            [ ("kind", string "signatureTypecheckDrv")
            , ("status", string "planned")
            , ("unit", string (indefiniteUnit unit))
            ]
        )
    SignatureInterface unit signature path ->
      writePlan path
        ( object
            [ ("kind", string "signatureDrv")
            , ("status", string "planned")
            , ("unit", string (indefiniteUnit unit))
            , ("signature", string signature)
            ]
        )
    InstantiationPlan instantiation path ->
      writePlan path
        ( object
            [ ("kind", string "instantiationDrv")
            , ("status", string "planned")
            , ("unit", string (instantiationUnit instantiation))
            , ("instantiationKey", string (instantiationKey instantiation))
            , ("holes", object (map (\(hole, provider) -> (hole, string provider)) (instantiationHoles instantiation)))
            ]
        )
  where
    writePlan path value = writeJsonFile (out </> path) value

instantiationKey :: ExpectedInstantiation -> String
instantiationKey instantiation =
  instantiationUnit instantiation
    ++ "+"
    ++ intercalate "," [hole ++ "=" ++ provider | (hole, provider) <- instantiationHoles instantiation]
