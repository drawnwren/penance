{-# LANGUAGE ForeignFunctionInterface #-}

module ForeignAnswer
  ( foreignAnswer
  ) where

import Foreign.C.Types (CInt (..))

foreign import ccall unsafe "penance_foreign_answer"
  cForeignAnswer :: IO CInt

foreignAnswer :: IO Int
foreignAnswer = fromIntegral <$> cForeignAnswer
