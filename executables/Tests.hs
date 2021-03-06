{-# OPTIONS_GHC -F -pgmF htfpp #-}
module Main where

import BasePrelude hiding (assert)
import Test.Framework
import Test.QuickCheck.Instances
import Data.Time
import qualified Data.Vector as V
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Scientific as Scientific
import qualified Data.UUID as UUID
import qualified Database.PostgreSQL.LibPQ as PQ
import qualified PostgreSQLBinary.PTI as PTI
import qualified PostgreSQLBinary.Encoder as Encoder
import qualified PostgreSQLBinary.Decoder as Decoder
import qualified PostgreSQLBinary.Array as Array
import qualified PostgreSQLBinary.Composite as Composite


type Text = T.Text
type LazyText = TL.Text
type ByteString = B.ByteString
type LazyByteString = BL.ByteString
type Scientific = Scientific.Scientific

main = 
  htfMain $ htf_thisModulesTests

floatEqProp :: RealFrac a => Show a => a -> a -> Property
floatEqProp a b =
  counterexample (show a ++ " /~ " ++ show b) $
    a + error >= b && a - error <= b
  where
    error = max (abs a) 1 / 10^3

mappingP :: 
  (Show a, Eq a) => 
  Word32 -> (a -> Maybe ByteString) -> (Maybe ByteString -> Either Text a) -> a -> Property
mappingP oid encode decode v =
  Right v === do
    unsafePerformIO $ do
      c <- connect
      initConnection c
      result <-
        let param = (,,) <$> pure (PQ.Oid $ fromIntegral oid) <*> encode v <*> pure PQ.Binary
            in PQ.execParams c "SELECT $1" [param] PQ.Binary
      case result of
        Just result -> do
          binaryResult <- PQ.getvalue result 0 0
          PQ.finish c
          return $ decode binaryResult
        Nothing -> do
          m <- PQ.errorMessage c
          fail $ maybe "Fatal PQ error" (\m -> "Fatal PQ error: " <> show m) m

mappingTextP ::
  (Show a, Eq a) => 
  Word32 -> (a -> Maybe ByteString) -> (a -> Maybe ByteString) -> a -> Property
mappingTextP oid encode render value =
  render value === do unsafePerformIO $ checkText oid (encode value)

checkText :: Word32 -> Maybe ByteString -> IO (Maybe ByteString)
checkText oid v =
  do
    c <- connect
    initConnection c
    Just result <-
      let param = (,,) <$> pure (PQ.Oid $ fromIntegral oid) <*> v <*> pure PQ.Binary
          in PQ.execParams c "SELECT $1" [param] PQ.Text
    encodedResult <- PQ.getvalue result 0 0
    PQ.finish c
    return $ encodedResult

query :: ByteString -> [Maybe (PQ.Oid, ByteString, PQ.Format)] -> PQ.Format -> IO (Maybe ByteString)
query statement params outFormat =
  do
    connection <- connect
    initConnection connection
    Just result <- PQ.execParams connection statement params outFormat
    encodedResult <- PQ.getvalue result 0 0
    PQ.finish connection
    return $ encodedResult

connect :: IO PQ.Connection
connect =
  PQ.connectdb bs
  where
    bs = 
      B.intercalate " " components
      where
        components = 
          [
            "host=" <> host,
            "port=" <> (fromString . show) port,
            "user=" <> user,
            "password=" <> password,
            "dbname=" <> db
          ]
          where
            host = "localhost"
            port = 5432
            user = "postgres"
            password = ""
            db = "postgres"

initConnection :: PQ.Connection -> IO ()
initConnection c =
  void $ PQ.exec c $ mconcat $ map (<> ";") $ 
    [ 
      "SET client_min_messages TO WARNING",
      "SET client_encoding = 'UTF8'",
      "SET intervalstyle = 'postgres'"
    ]

getIntegerDatetimes :: PQ.Connection -> IO Bool
getIntegerDatetimes c =
  fmap parseResult $ PQ.parameterStatus c "integer_datetimes"
  where
    parseResult = 
      \case
        Just "on" -> True
        _ -> False

nonNullParser p =
  fromMaybe (Left "Unexpected NULL") . fmap p

nonNullRenderer r =
  return . r

-- * Generators
-------------------------

scientificGen :: Gen Scientific
scientificGen =
  Scientific.scientific <$> arbitrary <*> arbitrary

microsTimeOfDayGen :: Gen TimeOfDay
microsTimeOfDayGen =
  fmap timeToTimeOfDay $ fmap picosecondsToDiffTime $ fmap (* (10^6)) $ 
    choose (0, (10^6)*24*60*60)

microsLocalTimeGen :: Gen LocalTime
microsLocalTimeGen = 
  LocalTime <$> arbitrary <*> microsTimeOfDayGen

microsUTCTimeGen :: Gen UTCTime
microsUTCTimeGen =
  localTimeToUTC <$> timeZoneGen <*> microsLocalTimeGen

intervalDiffTimeGen :: Gen DiffTime
intervalDiffTimeGen = do
  unsafeCoerce ((* (10^6)) <$> choose (uMin, uMax) :: Gen Integer)
  where
    uMin = unsafeCoerce minInterval `div` 10^6
    uMax = unsafeCoerce maxInterval `div` 10^6

timeZoneGen :: Gen TimeZone
timeZoneGen =
  minutesToTimeZone <$> choose (- 60 * 12 + 1, 60 * 12)

uuidGen :: Gen UUID.UUID
uuidGen =
  UUID.fromWords <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

arrayGen :: Gen (Word32, Array.Data)
arrayGen =
  do
    ndims <- choose (1, 4)
    dims <- replicateM ndims dimGen
    (valueGen', oid, arrayOID) <- valueGen
    values <- replicateM (dimsToNValues dims) valueGen'
    let nulls = elem Nothing values
    return (arrayOID, (dims, values, nulls, oid))
  where
    dimGen =
      (,) <$> choose (1, 7) <*> pure 1


    dimsToNValues =
      product . map dimensionWidth
      where
        dimensionWidth (x, _) = fromIntegral x

valueGen :: Gen (Gen (Maybe BC.ByteString), Word32, Word32)
valueGen =
  do
    (pti, gen) <- elements [(PTI.int8, mkGen (Encoder.int8 . Left)),
                            (PTI.bool, mkGen Encoder.bool),
                            (PTI.date, mkGen Encoder.date),
                            (PTI.text, mkGen Encoder.text),
                            (PTI.bytea, mkGen Encoder.bytea)]
    return (gen, PTI.oidOf pti, fromJust $ PTI.arrayOIDOf pti)
  where
    mkGen renderer =
      fmap (fmap renderer) arbitrary

compositesGen :: Gen (V.Vector Composite.Field)
compositesGen = do
  -- hacky way of reducing the size of these vectors :)
  lenW <- arbitrary :: Gen Word8
  V.replicateM (fromIntegral lenW) $ do
    (getVal, oid, _) <- valueGen
    val              <- getVal
    return (Composite.createField oid val)

-- * Constants
-------------------------

maxInterval :: DiffTime = 
  unsafeCoerce $ 
    (truncate (1780000 * 365.2425 * 24 * 60 * 60 * 10 ^ 12 :: Rational) :: Integer)

minInterval :: DiffTime = 
  negate maxInterval

integerDatetimes :: Bool
integerDatetimes =
  unsafePerformIO $ do
    connection <- connect
    initConnection connection
    integerDatetimes <- getIntegerDatetimes connection
    PQ.finish connection
    return integerDatetimes

-- * Misc
-------------------------

timestamptzApxRep (UTCTime d d') =
  (d, picoApxRep (unsafeCoerce d'))

timestampApxRep (LocalTime d t) =
  (d, timeApxRep t)

timetzApxRep (t, tz) = 
  (timeApxRep t, tz)

timeApxRep (TimeOfDay h m s) =
  (h, m, picoApxRep s)

picoApxRep :: Pico -> Integer
picoApxRep s =
  let p = unsafeCoerce s :: Integer
      in round (p % 10^6)


-- * Tests
-------------------------

-- | This is a dummy, the sole point of which is to output the value of 'integer_datetimes'
test_integerDatetimes =
  do
    connection <- connect
    initConnection connection
    x <- getIntegerDatetimes connection
    putStrLn $ "'integer_datetimes' is " <> show x
    PQ.finish connection

prop_uuid =
  forAll uuidGen $ 
    mappingP (PTI.oidOf PTI.uuid) 
             (nonNullRenderer Encoder.uuid)
             (nonNullParser Decoder.uuid)

test_uuidParsing =
  assertEqual (Right (read "550e8400-e29b-41d4-a716-446655440000" :: UUID.UUID)) =<< do
    fmap (Decoder.uuid . fromJust) $ 
      query "SELECT '550e8400-e29b-41d4-a716-446655440000' :: uuid" [] PQ.Binary

test_intervalParsing =
  let p = 10^6 * (332211 + 10^6 * (6 + 60 * (5 + 60 * (4 + 24 * (3 + 31 * (2 + 12))))))
      in 
      assertEqual (Just (Right (picosecondsToDiffTime p))) =<< do
        (fmap . fmap) (Decoder.interval integerDatetimes) $ 
          query "SELECT '1 year 2 months 3 days 4 hours 5 minutes 6 seconds 332211 microseconds' :: interval" [] PQ.Binary

prop_interval =
  forAll intervalDiffTimeGen $ 
    mappingP (PTI.oidOf PTI.interval) 
             (nonNullRenderer (Encoder.interval integerDatetimes))
             (nonNullParser (Decoder.interval integerDatetimes))

test_maxInterval =
  let x = maxInterval
    in 
      assertEqual (Just (Right x)) =<< do
        let 
          p = 
            (,,)
              (PQ.Oid (fromIntegral (PTI.oidOf PTI.interval)))
              ((Encoder.interval integerDatetimes) x)
              (PQ.Binary)
        (fmap . fmap) (Decoder.interval integerDatetimes) $ 
          query "SELECT $1" [Just p] PQ.Binary

test_minInterval =
  let x = minInterval
    in 
      assertEqual (Just (Right x)) =<< do
        let 
          p = 
            (,,)
              (PQ.Oid (fromIntegral (PTI.oidOf PTI.interval)))
              ((Encoder.interval integerDatetimes) x)
              (PQ.Binary)
        (fmap . fmap) (Decoder.interval integerDatetimes) $ 
          query "SELECT $1" [Just p] PQ.Binary

prop_timestamp =
  forAll microsLocalTimeGen $ \x ->
    Just (Right (timestampApxRep x)) === do
      unsafePerformIO $ do
        let p = (,,) (PQ.Oid $ fromIntegral $ PTI.oidOf PTI.timestamp)
                     (Encoder.timestamp integerDatetimes x)
                     (PQ.Binary)
            in (fmap . fmap) (fmap timestampApxRep . Decoder.timestamp integerDatetimes)
                             (query "SELECT $1" [Just p] PQ.Binary)

test_timestampParsing1 =
  assertEqual (Right (read "2000-01-19 10:41:06" :: LocalTime)) =<< do
    fmap (Decoder.timestamp integerDatetimes . fromJust) $ 
      query "SELECT '2000-01-19 10:41:06' :: timestamp" [] PQ.Binary

test_timestamptzOffset =
  do
    c <- connect
    initConnection c
    PQ.exec c "DROP TABLE IF EXISTS a"
    PQ.exec c "CREATE TABLE a (b TIMESTAMPTZ)"
    PQ.exec c "set timezone to 'America/Los_Angeles'"
    let p = (,,) (PQ.Oid $ fromIntegral o) 
                 (Encoder.timestamptz integerDatetimes x) 
                 (PQ.Binary)
        o = PTI.oidOf PTI.timestamptz
        x = read "2011-09-28 00:17:25"
    PQ.execParams c "insert into a (b) values ($1)" [Just p] PQ.Text
    PQ.exec c "set timezone to 'Europe/Stockholm'"
    assertEqual (Just "2011-09-28 02:17:25+02") 
      =<< singleResult 
      =<< PQ.execParams c "SELECT * FROM a" [] PQ.Text
    assertEqual (Just (Right x)) 
      =<< return . fmap (Decoder.timestamptz integerDatetimes)
      =<< singleResult 
      =<< PQ.execParams c "SELECT * FROM a" [] PQ.Binary
  where
    singleResult r = PQ.getvalue (fromJust r) 0 0

prop_timestamptz =
  forAll microsUTCTimeGen $ \x ->
    Just (Right (timestamptzApxRep x)) === do
      unsafePerformIO $ do
        let p = (,,) (PQ.Oid $ fromIntegral $ PTI.oidOf PTI.timestamptz)
                     (Encoder.timestamptz integerDatetimes x)
                     (PQ.Binary)
            in (fmap . fmap) (fmap timestamptzApxRep . Decoder.timestamptz integerDatetimes)
                             (query "SELECT $1" [Just p] PQ.Binary)

prop_timetz =
  forAll ((,) <$> microsTimeOfDayGen <*> timeZoneGen) $ \x ->
    Just (Right (timetzApxRep x)) === do
      unsafePerformIO $ do
        let p = (,,) (PQ.Oid $ fromIntegral $ PTI.oidOf PTI.timetz)
                     (Encoder.timetz integerDatetimes x)
                     (PQ.Binary)
            in (fmap . fmap) (fmap timetzApxRep . Decoder.timetz integerDatetimes)
                             (query "SELECT $1" [Just p] PQ.Binary)

test_timetzParsing =
  assertEqual (Right $ timetzApxRep (read "(10:41:06.002897, +0500)" :: (TimeOfDay, TimeZone))) =<< do
    connection <- connect
    initConnection connection
    integerDatetimes <- getIntegerDatetimes connection
    Just result <- PQ.execParams connection "SELECT '10:41:06.002897+05' :: timetz" [] PQ.Binary
    encodedResult <- PQ.getvalue result 0 0
    PQ.finish connection
    return $ fmap timetzApxRep $ 
      Decoder.timetz integerDatetimes (fromJust encodedResult)

prop_timeFromIntegerIsomorphism =
  forAll microsTimeOfDayGen $ \x ->
    Right x === Decoder.time True (Encoder.time True x)

prop_timeFromDoubleIsomorphism =
  forAll microsTimeOfDayGen $ \x ->
    let Right x' = Decoder.time False (Encoder.time False x)
        in floatEqProp (toFloat x) (toFloat x')
  where
    toFloat (TimeOfDay h m s) =
      s + fromIntegral (60 * (m + 60 * h))

prop_time =
  forAll microsTimeOfDayGen $ \x ->
    Right (timeApxRep x) === do
      unsafePerformIO $ do
        connection <- connect
        initConnection connection
        integerDatetimes <- getIntegerDatetimes connection
        Just result <- 
          let params = [Just (PQ.Oid $ fromIntegral $ PTI.oidOf PTI.time, Encoder.time integerDatetimes x, PQ.Binary)]
              in PQ.execParams connection "SELECT $1" params PQ.Binary
        encodedResult <- PQ.getvalue result 0 0
        PQ.finish connection
        return $ fmap timeApxRep $
          Decoder.time integerDatetimes (fromJust encodedResult)

prop_timeParsing =
  forAll microsTimeOfDayGen $ \x ->
    Right (timeApxRep x) === do
      unsafePerformIO $ do
        connection <- connect
        initConnection connection
        integerDatetimes <- getIntegerDatetimes connection
        Just result <- 
          let params = [Just (PQ.Oid $ fromIntegral $ PTI.oidOf PTI.time, (fromString . show) x, PQ.Text)]
              in PQ.execParams connection "SELECT $1" params PQ.Binary
        encodedResult <- PQ.getvalue result 0 0
        PQ.finish connection
        return $ fmap timeApxRep $
          Decoder.time integerDatetimes (fromJust encodedResult)

prop_scientific (c, e) =
  let x = Scientific.scientific c e
    in
      mappingP (PTI.oidOf PTI.numeric) 
               (nonNullRenderer Encoder.numeric)
               (nonNullParser Decoder.numeric)
               (x)

test_scientificParsing1 =
  assertEqual (Right (read "-1234560.789" :: Scientific)) =<< do
    fmap (Decoder.numeric . fromJust) $ 
      query "SELECT -1234560.789 :: numeric" [] PQ.Binary

test_scientificParsing2 =
  assertEqual (Right (read "-0.0789" :: Scientific)) =<< do
    fmap (Decoder.numeric . fromJust) $ 
      query "SELECT -0.0789 :: numeric" [] PQ.Binary

test_scientificParsing3 =
  assertEqual (Right (read "10000" :: Scientific)) =<< do
    fmap (Decoder.numeric . fromJust) $ 
      query "SELECT 10000 :: numeric" [] PQ.Binary

prop_scientificParsing (c, e) =
  let x = Scientific.scientific c e
    in
      Right x === do
        unsafePerformIO $ 
          fmap (Decoder.numeric . fromJust) $ 
            query "SELECT $1 :: numeric" 
                  [Just (PQ.Oid $ fromIntegral $ PTI.oidOf PTI.numeric, (fromString . show) x, PQ.Text)] 
                  PQ.Binary

prop_float =
  mappingP (PTI.oidOf PTI.float4) 
           (nonNullRenderer Encoder.float4)
           (nonNullParser Decoder.float4)

prop_floatText =
  \x -> 
    floatEqProp x $ do
      fromJust $ unsafePerformIO $ (fmap . fmap) reader $ checkText (PTI.oidOf pti) (encoder x)
  where
    pti = PTI.float4
    reader = read . BC.unpack
    encoder = nonNullRenderer Encoder.float4

prop_double =
  mappingP (PTI.oidOf PTI.float8) 
           (nonNullRenderer Encoder.float8)
           (nonNullParser Decoder.float8)

prop_doubleText =
  \x -> 
    floatEqProp x $ do
      fromJust $ unsafePerformIO $ (fmap . fmap) reader $ checkText (PTI.oidOf pti) (encoder x)
  where
    pti = PTI.float8
    reader = read . BC.unpack
    encoder = nonNullRenderer Encoder.float8

prop_char x =
  (x /= '\NUL') ==>
  mappingP (PTI.oidOf PTI.text) 
           (nonNullRenderer Encoder.char)
           (nonNullParser Decoder.char)
           (x)

prop_charText x =
  (x /= '\NUL') ==>
  mappingTextP (PTI.oidOf PTI.text) 
               (nonNullRenderer Encoder.char) 
               (Just . TE.encodeUtf8 . T.singleton)
               (x)

test_emptyArrayElements =
  assertEqual [] (Array.elements ([], [], False, 0))

test_arrayElements =
  assertEqual result (Array.elements arrayData)
  where
    arrayData = ([(3, 1)], [Just "1", Just "2", Just "3"], False, 0)
    result = [([], [Just "1"], False, 0), ([], [Just "2"], False, 0), ([], [Just "3"], False, 0)]

prop_arrayDataFromAndToListIsomporphism =
  forAll arrayGen $ \(oid, x) ->
    x === (Array.fromListUnsafe . Array.elements) x

prop_byteString =
  mappingP (PTI.oidOf PTI.bytea)
           (nonNullRenderer (Encoder.bytea . Left))
           (nonNullParser Decoder.bytea)

prop_lazyByteString =
  mappingP (PTI.oidOf PTI.bytea)
           (nonNullRenderer (Encoder.bytea . Right))
           (nonNullParser (fmap BL.fromStrict . Decoder.bytea))

prop_text v =
  (isNothing $ T.find (== '\NUL') v) ==>
    mappingP (PTI.oidOf PTI.text) 
             (nonNullRenderer (Encoder.text . Left))
             (nonNullParser Decoder.text)
             (v)

prop_lazyText v =
  (isNothing $ TL.find (== '\NUL') v) ==>
    mappingP (PTI.oidOf PTI.text) 
             (nonNullRenderer (Encoder.text . Right))
             (nonNullParser (fmap TL.fromStrict . Decoder.text))
             (v)

prop_bool =
  mappingP (PTI.oidOf PTI.bool) 
           (nonNullRenderer Encoder.bool)
           (nonNullParser Decoder.bool)

prop_int =
  mappingP (PTI.oidOf PTI.int8) 
           (nonNullRenderer (Encoder.int8 . Left) . (fromIntegral :: Int -> Int64))
           (nonNullParser Decoder.int)

prop_int8 =
  mappingP (PTI.oidOf PTI.int2) 
           (nonNullRenderer (Encoder.int2 . Left) . (fromIntegral :: Int8 -> Int16))
           (nonNullParser Decoder.int)

prop_int16 =
  mappingP (PTI.oidOf PTI.int2) 
           (nonNullRenderer (Encoder.int2 . Left))
           (nonNullParser Decoder.int)

prop_int32 =
  mappingP (PTI.oidOf PTI.int4) 
           (nonNullRenderer (Encoder.int4 . Left))
           (nonNullParser Decoder.int)

prop_int64 =
  mappingP (PTI.oidOf PTI.int8) 
           (nonNullRenderer (Encoder.int8 . Left))
           (nonNullParser Decoder.int)

prop_int64Text =
  mappingTextP (PTI.oidOf PTI.int8) 
               (nonNullRenderer (Encoder.int8 . Left)) 
               (Just . fromString . show)

prop_word =
  mappingP (PTI.oidOf PTI.int8) 
           (nonNullRenderer (Encoder.int8 . Right) . (fromIntegral :: Word -> Word64))
           (nonNullParser Decoder.int)

prop_word8 =
  mappingP (PTI.oidOf PTI.int2) 
           (nonNullRenderer (Encoder.int2 . Right) . (fromIntegral :: Word8 -> Word16))
           (nonNullParser Decoder.int)

prop_word16 =
  mappingP (PTI.oidOf PTI.int2) 
           (nonNullRenderer (Encoder.int2 . Right))
           (nonNullParser Decoder.int)

prop_word32 =
  mappingP (PTI.oidOf PTI.int4) 
           (nonNullRenderer (Encoder.int4 . Right))
           (nonNullParser Decoder.int)

prop_word64 =
  mappingP (PTI.oidOf PTI.int8) 
           (nonNullRenderer (Encoder.int8 . Right))
           (nonNullParser Decoder.int)

prop_word64Text =
  mappingTextP (PTI.oidOf PTI.int8) 
               (nonNullRenderer (Encoder.int8 . Right)) 
               (Just . fromString . show)

prop_day =
  mappingP (PTI.oidOf PTI.date) 
           (nonNullRenderer Encoder.date)
           (nonNullParser Decoder.date)

prop_dayText =
  mappingTextP (PTI.oidOf PTI.date) 
               (nonNullRenderer Encoder.date) 
               (Just . fromString . show)

prop_arrayData =
  forAll arrayGen $ uncurry $ \oid ->
    mappingP (oid)
             (nonNullRenderer Encoder.array)
             (nonNullParser Decoder.array)

prop_compositeId =
  forAll compositesGen $ \fields ->
    Right fields === Decoder.composite (Encoder.composite fields)
