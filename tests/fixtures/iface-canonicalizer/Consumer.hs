module Consumer where

import IfaceSubject (foo, foo', unsigned)

combined :: Int
combined = foo + foo' + fromIntegral unsigned
