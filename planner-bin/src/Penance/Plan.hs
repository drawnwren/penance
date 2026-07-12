module Penance.Plan
  ( drvFileFor
  , readSkeleton
  , writeJsonFile
  )
where

import Penance.Json (Json, renderJson)
import qualified Penance.Json as Json
import Penance.Skeleton (ProjectSkeleton, decodeProjectSkeleton)
import System.Exit (die)

readSkeleton :: FilePath -> IO ProjectSkeleton
readSkeleton path = do
  contents <- readFile path
  case Json.parseJson contents >>= decodeProjectSkeleton path of
    Left err -> die ("failed to parse ProjectSkeleton: " ++ err)
    Right skeleton -> pure skeleton

writeJsonFile :: FilePath -> Json -> IO ()
writeJsonFile path value =
  writeFile path (renderJson value ++ "\n")

drvFileFor :: String -> String
drvFileFor name = safeFileName name ++ ".drv.plan.json"

safeFileName :: String -> String
safeFileName =
  map
    ( \ch ->
        if ch == '/' || ch == '\\' || ch == ' ' || ch == '(' || ch == ')' || ch == ','
          then '_'
          else ch
    )
