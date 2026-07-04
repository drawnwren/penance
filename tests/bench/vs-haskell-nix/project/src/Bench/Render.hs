module Bench.Render
  ( renderLines
  , renderTable
  )
where

renderLines :: [String] -> String
renderLines = unlines

renderTable :: [(String, String)] -> String
renderTable rows =
  unlines [key ++ ": " ++ value | (key, value) <- rows]
