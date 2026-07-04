module UsesSignature
  ( usesEmpty
  ) where

import Data.MyAbstractMap qualified as AbstractMap

usesEmpty :: AbstractMap.Map Int String
usesEmpty = AbstractMap.empty
