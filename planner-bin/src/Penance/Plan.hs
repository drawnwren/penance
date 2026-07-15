module Penance.Plan
  ( drvFileFor
  , readSkeleton
  , writeJsonFile
  )
where

import Penance.Json (Json, renderJson)
import qualified Penance.Json as Json
import Penance.Error (throwJsonError)
import Penance.Skeleton (ProjectSkeleton, decodeProjectSkeleton)
import Penance.Utf8.IO (readUtf8File, writeUtf8File)

readSkeleton :: FilePath -> IO ProjectSkeleton
readSkeleton path = do
  contents <- readUtf8File path
  case Json.parseJson contents >>= decodeProjectSkeleton path of
    Left err -> throwJsonError ("failed to parse ProjectSkeleton: " ++ err)
    Right skeleton -> pure skeleton

writeJsonFile :: FilePath -> Json -> IO ()
writeJsonFile path value =
  writeUtf8File path (renderJson value ++ "\n")

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
