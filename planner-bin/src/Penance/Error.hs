module Penance.Error
  ( PenanceError (..)
  , renderPenanceError
  , throwArgumentError
  , throwCabalParseError
  , throwGraphError
  , throwJsonError
  , throwNixError
  , throwPlanError
  )
where

import Control.Exception (Exception, throwIO)

data PenanceError
  = ArgumentError String
  | CabalParseError String
  | GraphError String
  | JsonError String
  | NixError String
  | PlanError String
  deriving (Eq, Show)

instance Exception PenanceError

renderPenanceError :: PenanceError -> String
renderPenanceError penanceError =
  case penanceError of
    ArgumentError message -> message
    CabalParseError message -> message
    GraphError message -> message
    JsonError message -> message
    NixError message -> message
    PlanError message -> message

throwArgumentError :: String -> IO a
throwArgumentError = throwIO . ArgumentError

throwCabalParseError :: String -> IO a
throwCabalParseError = throwIO . CabalParseError

throwGraphError :: String -> IO a
throwGraphError = throwIO . GraphError

throwJsonError :: String -> IO a
throwJsonError = throwIO . JsonError

throwNixError :: String -> IO a
throwNixError = throwIO . NixError

throwPlanError :: String -> IO a
throwPlanError = throwIO . PlanError
