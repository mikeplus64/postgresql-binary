module PostgreSQLBinary.Rendering where

import PostgreSQLBinary.Prelude
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.ByteString.Builder.Scientific as Scientific
import qualified PostgreSQLBinary.Rendering.Builder as Builder
import qualified PostgreSQLBinary.Array as Array
import qualified PostgreSQLBinary.Time as Time


type R a = a -> ByteString

bool :: R Bool
bool =
  \case
    False -> B.singleton 0
    True  -> B.singleton 1

int :: R Int
int = 
  Builder.run . BB.int64BE . fromIntegral

int64 :: R Int64
int64 = 
  Builder.run . BB.int64BE

arrayData :: R Array.Data
arrayData = 
  Builder.run . Builder.arrayData

day :: R Day
day =
  Builder.run . BB.int32BE . fromIntegral . Time.dayToPostgresJulian

