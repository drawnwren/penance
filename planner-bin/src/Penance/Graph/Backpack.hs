module Penance.Graph.Backpack
  ( backpackDrvEntries
  , emitBootstrap
  )
where

import Data.List (intercalate)
import qualified Penance.Json as Json
import Penance.Json (array, object, string)
import Penance.Skeleton
  ( BackpackSkeleton (..)
  , ExpectedInstantiation (..)
  , IndefiniteUnit (..)
  , ModuleName
  , ProjectSkeleton (..)
  , renderComponentId
  , renderModuleName
  , renderPkgName
  , renderUnitKey
  )
import Penance.Plan (drvFileFor, writeJsonFile)
import Penance.Types
  ( PlanArtifactKind (..)
  , PlanStatus (..)
  , renderGranularity
  , renderPlanArtifactKind
  , renderPlanStatus
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

data BackpackEntry
  = SignatureTypecheck IndefiniteUnit FilePath
  | SignatureInterface IndefiniteUnit ModuleName FilePath
  | InstantiationPlan ExpectedInstantiation FilePath
  deriving (Eq, Show)

backpackDrvEntries :: ProjectSkeleton -> [(String, FilePath)]
backpackDrvEntries skeleton =
  map entryKeyPath (backpackEntries skeleton)
  where
    entryKeyPath entry =
      case entry of
        SignatureTypecheck unit path ->
          (renderUnitKey (indefiniteUnit unit) ++ ":typecheck", path)
        SignatureInterface unit signature path ->
          (renderUnitKey (indefiniteUnit unit) ++ ":" ++ renderModuleName signature, path)
        InstantiationPlan instantiation path ->
          (instantiationKey instantiation, path)

emitBootstrap :: ProjectSkeleton -> FilePath -> IO ()
emitBootstrap skeleton out = do
  let dir = out </> "signatures"
  createDirectoryIfMissing True dir
  createDirectoryIfMissing True (out </> "instantiations")
  writeJsonFile (dir </> "backpack-graph.json") (backpackGraphJson skeleton)
  mapM_ (writeBackpackPlan out) (backpackEntries skeleton)

backpackEntries :: ProjectSkeleton -> [BackpackEntry]
backpackEntries skeleton =
  typecheckEntries ++ signatureEntries ++ instantiationEntries
  where
    bp = backpack skeleton
    typecheckEntries =
      [ SignatureTypecheck unit ("signatures" </> drvFileFor (renderUnitKey (indefiniteUnit unit) ++ ":typecheck"))
      | unit <- indefiniteUnits bp
      ]
    signatureEntries =
      [ SignatureInterface
          unit
          signature
          ("signatures" </> drvFileFor (renderUnitKey (indefiniteUnit unit) ++ ":" ++ renderModuleName signature))
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
    [ ("kind", string (renderPlanArtifactKind BackpackGraphArtifact))
    , ("status", string (renderPlanStatus Planned))
    , ("granularity", string (renderGranularity (granularity skeleton)))
    , ("indefiniteUnits", array (map indefiniteUnitJson (indefiniteUnits (backpack skeleton))))
    , ("expectedInstantiations", array (map instantiationJson (expectedInstantiations (backpack skeleton))))
    , ("plannedDrvs", array (map backpackEntryJson (backpackEntries skeleton)))
    ]

indefiniteUnitJson :: IndefiniteUnit -> Json.Json
indefiniteUnitJson unit =
  object
    [ ("unit", string (renderUnitKey (indefiniteUnit unit)))
    , ("package", string (renderPkgName (indefinitePackage unit)))
    , ("component", string (renderComponentId (indefiniteComponent unit)))
    , ("signatures", array (map (string . renderModuleName) (indefiniteSignatures unit)))
    , ("requiredSignatures", array (map (string . renderModuleName) (indefiniteRequiredSignatures unit)))
    , ("mixins", array (map string (indefiniteMixins unit)))
    , ("reexportedModules", array (map string (indefiniteReexportedModules unit)))
    ]

instantiationJson :: ExpectedInstantiation -> Json.Json
instantiationJson instantiation =
  object
    [ ("unit", string (renderUnitKey (instantiationUnit instantiation)))
    , ("holes", object (map holeJson (instantiationHoles instantiation)))
    , ("instantiationKey", string (instantiationKey instantiation))
    ]
  where
    holeJson (hole, provider) = (renderModuleName hole, string provider)

backpackEntryJson :: BackpackEntry -> Json.Json
backpackEntryJson entry =
  case entry of
    SignatureTypecheck unit path ->
      object
        [ ("kind", string (renderPlanArtifactKind SignatureTypecheckDrvArtifact))
        , ("unit", string (renderUnitKey (indefiniteUnit unit)))
        , ("drvPlan", string path)
        ]
    SignatureInterface unit signature path ->
      object
        [ ("kind", string (renderPlanArtifactKind SignatureDrvArtifact))
        , ("unit", string (renderUnitKey (indefiniteUnit unit)))
        , ("signature", string (renderModuleName signature))
        , ("drvPlan", string path)
        ]
    InstantiationPlan instantiation path ->
      object
        [ ("kind", string (renderPlanArtifactKind InstantiationDrvArtifact))
        , ("unit", string (renderUnitKey (instantiationUnit instantiation)))
        , ("instantiationKey", string (instantiationKey instantiation))
        , ("drvPlan", string path)
        ]

writeBackpackPlan :: FilePath -> BackpackEntry -> IO ()
writeBackpackPlan out entry =
  case entry of
    SignatureTypecheck unit path ->
      writePlan path
        ( object
            [ ("kind", string (renderPlanArtifactKind SignatureTypecheckDrvArtifact))
            , ("status", string (renderPlanStatus Planned))
            , ("unit", string (renderUnitKey (indefiniteUnit unit)))
            ]
        )
    SignatureInterface unit signature path ->
      writePlan path
        ( object
            [ ("kind", string (renderPlanArtifactKind SignatureDrvArtifact))
            , ("status", string (renderPlanStatus Planned))
            , ("unit", string (renderUnitKey (indefiniteUnit unit)))
            , ("signature", string (renderModuleName signature))
            ]
        )
    InstantiationPlan instantiation path ->
      writePlan path
        ( object
            [ ("kind", string (renderPlanArtifactKind InstantiationDrvArtifact))
            , ("status", string (renderPlanStatus Planned))
            , ("unit", string (renderUnitKey (instantiationUnit instantiation)))
            , ("instantiationKey", string (instantiationKey instantiation))
            , ("holes", object (map (\(hole, provider) -> (renderModuleName hole, string provider)) (instantiationHoles instantiation)))
            ]
        )
  where
    writePlan path value = writeJsonFile (out </> path) value

instantiationKey :: ExpectedInstantiation -> String
instantiationKey instantiation =
  renderUnitKey (instantiationUnit instantiation)
    ++ "+"
    ++ intercalate "," [renderModuleName hole ++ "=" ++ provider | (hole, provider) <- instantiationHoles instantiation]
