module PostgreSQLBinary.Rendering where

import PostgreSQLBinary.Prelude
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.ByteString.Builder.Scientific as Scientific
import qualified PostgreSQLBinary.Rendering.Builder as Builder
import qualified PostgreSQLBinary.ArrayData as ArrayData
import qualified PostgreSQLBinary.Date as Date
import qualified PostgreSQLBinary.Numeric as Numeric


type R a = a -> ByteString


bool :: R Bool
bool =
  \case
    False -> B.singleton 0
    True  -> B.singleton 1

int16 :: R Int16
int16 = 
  Builder.run . BB.int16BE

int32 :: R Int32
int32 = 
  Builder.run . BB.int32BE

int64 :: R Int64
int64 = 
  Builder.run . BB.int64BE

word16 :: R Word16
word16 = 
  Builder.run . BB.word16BE

word32 :: R Word32
word32 = 
  Builder.run . BB.word32BE

word64 :: R Word64
word64 = 
  Builder.run . BB.word64BE

float :: R Float
float =
  word32 . unsafeCoerce

double :: R Double
double =
  word64 . unsafeCoerce

arrayData :: R ArrayData.Data
arrayData = 
  Builder.run . Builder.arrayData

day :: R Day
day =
  Builder.run . BB.int32BE . fromIntegral . Date.dayToPostgresJulian

text :: R Text
text =
  TE.encodeUtf8 . T.filter (/= '\0')

lazyText :: R TL.Text
lazyText =
  BL.toStrict . TLE.encodeUtf8 . TL.filter (/= '\0')

byteString :: R ByteString
byteString =
  id

lazyByteString :: R BL.ByteString
lazyByteString =
  BL.toStrict

utf8Char :: R Char
utf8Char = 
  text . T.singleton

numeric :: R Numeric.Numeric
numeric x =
  Builder.run $
    BB.word16BE (Numeric.componentsAmount x) <>
    BB.int16BE (Numeric.pointIndex x) <>
    BB.word16BE (Numeric.signCode x) <>
    BB.word16BE (Numeric.amountOfDigitsAfterPoint x) <>
    foldMap BB.word16BE (Numeric.components x)

scientific :: R Scientific
scientific =
  numeric . Numeric.fromScientific
