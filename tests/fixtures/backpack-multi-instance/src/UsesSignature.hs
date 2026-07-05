module UsesSignature
  ( usesEmptySize
  ) where

import qualified Data.MyAbstractMap as AbstractMap

usesEmptySize :: Int
usesEmptySize =
  AbstractMap.size (AbstractMap.empty :: AbstractMap.Map Int String)
