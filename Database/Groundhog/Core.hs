{-# LANGUAGE GADTs, TypeFamilies, ExistentialQuantification, StandaloneDeriving, TypeSynonymInstances, MultiParamTypeClasses, FunctionalDependencies, FlexibleInstances, FlexibleContexts, OverlappingInstances, ScopedTypeVariables, GeneralizedNewtypeDeriving, UndecidableInstances, EmptyDataDecls #-}

-- | This module defines the functions and datatypes used throughout the framework.
-- Most of them are for internal use
module Database.Groundhog.Core
  ( 
  -- * Main types
    PersistEntity(..)
  , PersistValue(..)
  , PersistField(..)
  , Key(..)
  -- * Constructing expressions
  -- $exprDoc
  , Cond(..)
  , Update(..)
  , (=.), (&&.), (||.), (==.), (/=.), (<.), (<=.), (>.), (>=.)
  , wrapPrim
  , toArith
  , Expression(..)
  , Primitive(..)
  , HasOrder
  , Numeric
  , NeverNull
  , Arith(..)
  , Expr(..)
  , Order(..)
  -- * Type description
  , DbType(..)
  , NamedType
  , namedType
  , getName
  , getType
  , EntityDef(..)
  , ConstructorDef(..)
  , Constructor(..)
  , Constraint
  -- * Migration
  , SingleMigration
  , NamedMigrations
  , Migration
  -- * Database
  , PersistBackend(..)
  , RowPopper
  , DbPersist(..)
  , runDbPersist
  ) where

import Control.Applicative(Applicative)
import Control.Monad(liftM, liftM2, liftM3, liftM4, liftM5)
import Control.Monad.Trans.Class(MonadTrans(..))
import Control.Monad.IO.Class(MonadIO(..))
import Control.Monad.IO.Control (MonadControlIO)
import Control.Monad.Trans.Reader(ReaderT, runReaderT)
import Control.Monad.Trans.State(StateT)
import Data.Bits(bitSize)
import Data.ByteString.Char8 (ByteString, unpack)
import Data.Enumerator(Enumerator)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Encoding.Error as T
import Data.Int (Int8, Int16, Int32, Int64)
import Data.Word (Word8, Word16, Word32, Word64)
import Data.Map(Map)
import Data.Time(Day, TimeOfDay, UTCTime)
import Unsafe.Coerce(unsafeCoerce)

-- | Only instances of this class can be persisted in a database
class PersistField v => PersistEntity v where
  -- | This type is used for typesafe manipulation of separate fields of datatype v.
  -- Each constructor in 'Fields' corresponds to its field in a datatype v.
  -- It is parametrised by constructor phantom type and field value type.
  data Fields v :: * -> * -> *
  -- | Returns a complete description of the type
  entityDef :: v -> EntityDef
  -- | Marshalls value to a list of 'PersistValue' ready for insert to a database
  toPersistValues   :: PersistBackend m => v -> m [PersistValue]
  -- | Constructs the value from the list of 'PersistValue'
  fromPersistValues :: PersistBackend m => [PersistValue] -> m v
  -- | Returns constructor number and a list of constraint names and corresponding field names with their values
  getConstraints    :: v -> (Int, [(String, [(String, PersistValue)])])
  -- Show (Fields v c a) constraint would be nicer, but free c & a params don't allow this
  showField :: Fields v c a -> String
  eqField :: Fields v c a -> Fields v c a -> Bool

instance PersistEntity v => Show (Fields v c a) where show = showField
instance PersistEntity v => Eq (Fields v c a) where (==) = eqField

-- | A unique identifier of a value stored in a database
data PersistEntity v => Key v = Key Int64 deriving Show

data Any

type family MoreSpecific a b
type instance MoreSpecific Any a = a
type instance MoreSpecific a Any = a
type instance MoreSpecific a a = a
type instance MoreSpecific Any Any = Any

class TypesCastV x y z | x y -> z
-- instance TypesCastV x x x would not work. For example, it does not match TypesCastV (Type a1) (Type a2) z
instance (x ~ y, MoreSpecific x y ~ z) => TypesCastV x y z
instance TypesCastV Any x x
instance TypesCastV x Any x
instance TypesCastV Any Any Any

class TypesEqualC x y
instance TypesEqualC x x
instance TypesEqualC Any x
instance TypesEqualC x Any
instance TypesEqualC Any Any

class TypesCastC x y z | x y -> z
instance (TypesEqualC x y, MoreSpecific x y ~ z) => TypesCastC x y z

class (Expression a, Expression b) => TypeCast a b v c | a b -> v, a b -> c
instance (Expression a, Expression b, TypesCastV (FuncV a) (FuncV b) v, TypesCastC (FuncC a) (FuncC b) c) => TypeCast a b v c
--instance (Expression a, Expression b, FuncV a ~ Any, FuncC a ~ Any, FuncV b ~ v, FuncC b ~ c) => TypeCast a b v c
--instance (FuncV a ~ v, FuncC a ~ c) => TypeCast a Any v c
--instance TypeCast Any Any Any Any

-- $exprDoc
-- The expressions are used in conditions and right part of Update statement.
-- Despite the wordy types of the comparison functions, they are simple to use.
-- Type of the compared polymorphic values like numbers or Nothing must be supplied manually. Example:
--
-- @
-- StringField ==. \"abc\" &&. NumberField >. (0 :: Int) ||. MaybeField ==. (Nothing :: Maybe String) ||. MaybeField ==. Just \"def\"
-- @
--

-- | Represents condition for a query.
data Cond v c =
    And (Cond v c) (Cond v c)
  | Or  (Cond v c) (Cond v c)
  | Not (Cond v c)
  | forall a.(HasOrder a, PersistField a) => Lesser  (Expr v c a) (Expr v c a)
  | forall a.(HasOrder a, PersistField a) => Greater (Expr v c a) (Expr v c a)
  | forall a.(PersistField a) => Equals    (Expr v c a) (Expr v c a)
  | forall a.(PersistField a) => NotEquals (Expr v c a) (Expr v c a)
  -- | Lookup will be performed only in table for the specified constructor c. To fetch value by key without constructor limitation use 'get'
  | KeyIs (Key v)

data Update v c = forall a.Update (Fields v c a) (Expr v c a)
--deriving instance (Show (Fields c a)) => Show (Update c)

-- | Defines sort order of a result-set
data Order v c = forall a.HasOrder a => Asc  (Fields v c a)
               | forall a.HasOrder a => Desc (Fields v c a)

-- TODO: UGLY: we use unsafeCoerce to cast phantom types Any and Any to more specific type if possible. The safety is assured by TypeEqual and TypeEqualC classes. I hope it will work w/o woes of segfaults

-- | Update field
infixr 3 =.
(=.) ::
  ( Expression a
  , TypesCastV v (FuncV a) v
  , TypesCastC c (FuncC a) c)
  => Fields v c (FuncA a) -> a -> Update v c
f =. a = Update f (unsafeCoerceExpr $ wrap a)

-- | Boolean \"and\" operator.
(&&.) :: (TypesCastV v1 v2 v3, TypesCastC c1 c2 c3) =>
  Cond v1 c1 -> Cond v2 c2 -> Cond v3 c3
  
-- | Boolean \"or\" operator.  
(||.) :: (TypesCastV v1 v2 v3, TypesCastC c1 c2 c3) =>
  Cond v1 c1 -> Cond v2 c2 -> Cond v3 c3
  
infixr 3 &&.
a &&. b = And (unsafeCoerce a) (unsafeCoerce b)

infixr 2 ||.
a ||. b = Or (unsafeCoerce a) (unsafeCoerce b)

unsafeCoerceExpr :: Expr v1 c1 a -> Expr v2 c2 a
unsafeCoerceExpr = unsafeCoerce

(==.), (/=.) ::
  ( TypeCast a b v c
  , FuncA a ~ FuncA b
  , PersistField (FuncA a))
  => a -> b -> Cond v c

(<.), (<=.), (>.), (>=.) ::
  ( TypeCast a b v c
  , FuncA a ~ FuncA b
  , PersistField (FuncA a)
  , HasOrder (FuncA a))
  => a -> b -> Cond v c

infix 4 ==., <., <=., >., >=.
a ==. b = Equals (unsafeCoerceExpr $ wrap a) (unsafeCoerceExpr $ wrap b)
a /=. b = NotEquals (unsafeCoerceExpr $ wrap a) (unsafeCoerceExpr $ wrap b)
a <.  b = Lesser (unsafeCoerceExpr $ wrap a) (unsafeCoerceExpr $ wrap b)
a <=. b = Not $ a >. b
a >.  b = Greater (unsafeCoerceExpr $ wrap a) (unsafeCoerceExpr $ wrap b)
a >=. b = Not $ a <. b

newtype Monad m => DbPersist conn m a = DbPersist { unDbPersist :: ReaderT conn m a }
  deriving (Monad, MonadIO, Functor, Applicative, MonadControlIO, MonadTrans)

runDbPersist :: Monad m => DbPersist conn m a -> conn -> m a
runDbPersist = runReaderT.unDbPersist

class Monad m => PersistBackend m where
  -- | Insert a new record to a database and return its 'Key'
  insert        :: PersistEntity v => v -> m (Key v)
  -- | Try to insert a record and return Right newkey. If there is a constraint violation, Left oldkey is returned
  -- , where oldkey is an identifier of the record with the same constraint values. Note that if several constraints are violated, a key of an arbitrary matching record is returned.
  insertBy      :: PersistEntity v => v -> m (Either (Key v) (Key v))
  -- | Replace a record with the given key. Result is undefined if the record does not exist.
  replace       :: PersistEntity v => Key v -> v -> m ()
  -- | Return a list of all records
  selectEnum    :: (PersistEntity v, Constructor c)
                => Cond v c
                -> [Order v c]
                -> Int -- ^ limit
                -> Int -- ^ offset
                -> Enumerator (Key v, v) m a
  -- | Get all records. Order is undefined
  selectAllEnum :: PersistEntity v => Enumerator (Key v, v) m a
  -- | Return a list of the records satisfying the condition
  select        :: (PersistEntity v, Constructor c)
                => Cond v c
                -> [Order v c]
                -> Int -- ^ limit
                -> Int -- ^ offset
                -> m [(Key v, v)]
  -- | Return a list of all records. Order is undefined
  selectAll     :: PersistEntity v => m [(Key v, v)]
  -- | Fetch an entity from a database
  get           :: PersistEntity v => Key v -> m (Maybe v)
  -- | Update the records satisfying the condition
  update        :: (PersistEntity v, Constructor c) => [Update v c] -> Cond v c -> m ()
  -- | Remove the records satisfying the condition
  delete        :: (PersistEntity v, Constructor c) => Cond v c -> m ()
  -- | Remove the record with given key. No-op if the record does not exist
  deleteByKey   :: PersistEntity v => Key v -> m ()
  -- | Count total number of records satisfying the condition
  count         :: (PersistEntity v, Constructor c) => Cond v c -> m Int
  -- | Count total number of records with all constructors
  countAll      :: PersistEntity v => v -> m Int
  -- | Check database schema and create migrations for the entity and the entities it contains
  migrate       :: PersistEntity v => v -> Migration m
  -- | Execute raw query
  executeRaw    :: Bool           -- ^ keep in cache
                -> String         -- ^ query
                -> [PersistValue] -- ^ positional parameters
                -> m ()
  -- | Execute raw query with results
  queryRaw      :: Bool           -- ^ keep in cache
                -> String         -- ^ query
                -> [PersistValue] -- ^ positional parameters
                -> (RowPopper m -> m a) -- ^ results processing function
                -> m a
  -- TODO: we need to supply names of the tables or other info
  insertTuple   :: NamedType -> [PersistValue] -> m Int64
  getTuple      :: NamedType -> Int64 -> m [PersistValue]
  insertList    :: PersistField a => [a] -> m Int64
  getList       :: PersistField a => Int64 -> m [a]
  
type RowPopper m = m (Maybe [PersistValue])

type Migration m = StateT NamedMigrations m ()

-- | Datatype names and corresponding migrations
type NamedMigrations = Map String SingleMigration

-- | Either error messages or migration queries with safety flags
type SingleMigration = Either [String] [(Bool, String)]

-- | Describes an ADT.
data EntityDef = EntityDef {
  -- | Emtity name
    entityName   :: String
  -- | Named types of the instantiated polymorphic type parameters
  , typeParams   :: [NamedType]
  -- | List of entity constructors definitions
  , constructors :: [ConstructorDef]
} deriving (Show, Eq)

-- | Describes an entity constructor
data ConstructorDef = ConstructorDef {
  -- | Number of the constructor in the ADT
    constrNum     :: Int
  -- | Constructor name
  , constrName    :: String
  -- | Parameter names with their named type
  , constrParams  :: [(String, NamedType)]
  -- | Uniqueness constraints on the constructor fiels
  , constrConstrs :: [Constraint]
} deriving (Show, Eq)

-- | Phantom constructors are made instances of this class. This class should be used only by Template Haskell codegen
class Constructor a where
  -- returning ConstructorDef seems more logical, but it would require the value datatype
  -- it can be supplied either as a part of constructor type, eg instance Constructor (MyDataConstructor (MyData a)) which requires -XFlexibleInstances
  -- or as a separate type, eg instance Constructor MyDataConstructor (MyData a) which requires -XMultiParamTypeClasses
  -- the phantoms are primarily used to get the constructor name. So to keep user code cleaner we return only the name and number, which can be later used to get ConstructorDef from the EntityDef
  phantomConstrName :: a -> String
  phantomConstrNum :: a -> Int

-- | Constraint name and list of the field names that form a unique combination.
-- Only fields of 'Primitive' types can be used in a constraint
type Constraint = (String, [String])

-- | A DB data type. Naming attempts to reflect the underlying Haskell
-- datatypes, eg DbString instead of DbVarchar. Different databases may
-- have different translations for these types.
data DbType = DbString
            | DbInt32
            | DbInt64
            | DbReal
            | DbBool
            | DbDay
            | DbTime
            | DbDayTime
            | DbBlob    -- ByteString
-- More complex types
            | DbMaybe NamedType
            | DbList NamedType
            | DbTuple Int [NamedType]
            | DbEntity EntityDef
  deriving Show

-- TODO: this type can be changed to avoid storing the value itself. For example, ([String, DbType). Restriction: can be used to get DbType and name
-- | It is used to store type 'DbType' and persist name of a value
data NamedType = forall v.PersistField v => NamedType v

namedType :: PersistField v => v -> NamedType
namedType = NamedType

getName :: NamedType -> String
getName (NamedType v) = persistName v

getType :: NamedType -> DbType
getType (NamedType v) = dbType v

instance Show NamedType where
  show (NamedType v) = show (dbType v)

-- rely on the invariant that no two types have the same name
instance Eq NamedType where
  (NamedType v1) == (NamedType v2) = persistName v1 == persistName v2

-- | A raw value which can be stored in any backend and can be marshalled to
-- and from a 'PersistField'.
data PersistValue = PersistString String
                  | PersistByteString ByteString
                  | PersistInt64 Int64
                  | PersistDouble Double
                  | PersistBool Bool
                  | PersistDay Day
                  | PersistTimeOfDay TimeOfDay
                  | PersistUTCTime UTCTime
                  | PersistNull
  deriving (Show, Eq)

-- | Arithmetic expressions which can include fields and literals
data Arith v c a =
    Plus  (Arith v c a) (Arith v c a)
  | Minus (Arith v c a) (Arith v c a)
  | Mult  (Arith v c a) (Arith v c a)
  | Abs   (Arith v c a)
  | ArithField (Fields v c a)
  | Lit   Int64
deriving instance Eq (Fields v c a) => Eq (Arith v c a)
deriving instance Show (Fields v c a) => Show (Arith v c a)

instance (Eq (Fields v c a), Show (Fields v c a), Numeric a) => Num (Arith v c a) where
  a + b = Plus  a b
  a - b = Minus a b
  a * b = Mult  a b
  abs   = Abs
  signum = error "no signum"
  fromInteger = Lit . fromInteger
  
-- | Convert field to an arithmetic value
toArith :: Fields v c a -> Arith v c a
toArith = ArithField

-- | Constraint for use in arithmetic expressions. 'Num' is not used to explicitly include only types supported by the library .
-- TODO: consider replacement with 'Num'
class Numeric a
-- | The same goals as for 'Numeric'. Certain types like String which have order in Haskell may not have it in DB
class HasOrder a

-- | Types which when converted to 'PersistValue' are never NULL.
-- Consider the type @Maybe (Maybe a)@. Now Nothing is stored as NULL, so we cannot distinguish between Just Nothing and Nothing which is a problem.
-- The purpose of this class is to ban the inner Maybe's.
-- Maybe this class can be removed when support for inner Maybe's appears.
class NeverNull a

-- | Datatypes which can be converted directly to 'PersistValue'
class Primitive a where
  toPrim :: a -> PersistValue
  fromPrim :: PersistValue -> a

-- | Used to uniformly represent fields, literals and arithmetic expressions.
-- A value should be convertec to 'Expr' for usage in expressions
data Expr v c a where
  ExprPrim  :: Primitive a => a -> Expr v c a
  ExprField :: PersistEntity v => Fields v c a -> Expr v c a
  ExprArith :: PersistEntity v => Arith v c a -> Expr v c a
  -- we need this field for Key and Maybe mostly
  ExprPlain :: Primitive a => a -> Expr v c (FuncA a)

-- I wish wrap could return Expr with both fixed and polymorphic v&c. Any is used to emulate polymorphic types.
-- | Instances of this type can be converted to 'Expr'
class Expression a where
  type FuncV a; type FuncC a; type FuncA a
  wrap :: a -> Expr (FuncV a) (FuncC a) (FuncA a)

-- | By default during converting values of certain types to 'Expr', the types can be changed. For example, @'Key' a@ is transformed into @a@.
-- It is convenient because the fields usually contain reference to a certain datatype, not its 'Key'.
-- But sometimes when automatic transformation gets in the way function 'wrapPrim' will help. Use it when a field in a datatype has type @(Key a)@ or @Maybe (Key a)@. Example:
--
-- @
--data Example = Example {entity1 :: Maybe Smth, entity2 :: Key Smth}
--Entity1Field ==. Just k &&. Entity2Field ==. wrapPrim k
-- @
wrapPrim :: Primitive a => a -> Expr Any Any a
-- We cannot create different Expression instances for (Fields v c a) and (Fields v c (Key a))
-- so that Func (Fields v c a) = a and Func (Fields v c (Key a)) = a
-- because of the type families overlap restrictions. Neither we can create different instances for Key a
wrapPrim = ExprPrim

class PersistField a where
  -- | Return name of the type. If it is polymorhic, the names of parameter types are separated with \"$\" symbol
  persistName :: a -> String
  -- | Convert a value into something which can be stored in a database column.
  -- Note that for complex datatypes it may insert them to return identifier
  toPersistValue :: PersistBackend m => a -> m PersistValue
  -- | Constructs a value from a 'PersistValue'. For complex datatypes it may query the database
  fromPersistValue :: PersistBackend m => PersistValue -> m a
  -- | Description of value type
  dbType :: a -> DbType

---- INSTANCES

instance Numeric Int
instance Numeric Int8
instance Numeric Int16
instance Numeric Int32
instance Numeric Int64
instance Numeric Word8
instance Numeric Word16
instance Numeric Word32
instance Numeric Word64
instance Numeric Double

instance HasOrder Int
instance HasOrder Int8
instance HasOrder Int16
instance HasOrder Int32
instance HasOrder Int64
instance HasOrder Word8
instance HasOrder Word16
instance HasOrder Word32
instance HasOrder Word64
instance HasOrder Double
instance HasOrder Bool
instance HasOrder Day
instance HasOrder TimeOfDay
instance HasOrder UTCTime

instance Primitive String where
  toPrim = PersistString
  fromPrim (PersistString s) = s
  fromPrim (PersistByteString bs) = T.unpack $ T.decodeUtf8With T.lenientDecode bs
  fromPrim (PersistInt64 i) = show i
  fromPrim (PersistDouble d) = show d
  fromPrim (PersistDay d) = show d
  fromPrim (PersistTimeOfDay d) = show d
  fromPrim (PersistUTCTime d) = show d
  fromPrim (PersistBool b) = show b
  fromPrim PersistNull = error "Unexpected null"

instance Primitive T.Text where
  toPrim = PersistString . T.unpack
  fromPrim (PersistByteString bs) = T.decodeUtf8With T.lenientDecode bs
  fromPrim x = T.pack $ fromPrim x

instance Primitive ByteString where
  toPrim = PersistByteString
  fromPrim (PersistByteString a) = a
  fromPrim x = T.encodeUtf8 . T.pack $ fromPrim x

instance Primitive Int where
  toPrim = PersistInt64 . fromIntegral
  fromPrim (PersistInt64 a) = fromIntegral a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Int8 where
  toPrim = PersistInt64 . fromIntegral
  fromPrim (PersistInt64 a) = fromIntegral a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Int16 where
  toPrim = PersistInt64 . fromIntegral
  fromPrim (PersistInt64 a) = fromIntegral a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Int32 where
  toPrim = PersistInt64 . fromIntegral
  fromPrim (PersistInt64 a) = fromIntegral a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Int64 where
  toPrim = PersistInt64
  fromPrim (PersistInt64 a) = a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Word8 where
  toPrim = PersistInt64 . fromIntegral
  fromPrim (PersistInt64 a) = fromIntegral a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Word16 where
  toPrim = PersistInt64 . fromIntegral
  fromPrim (PersistInt64 a) = fromIntegral a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Word32 where
  toPrim = PersistInt64 . fromIntegral
  fromPrim (PersistInt64 a) = fromIntegral a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Word64 where
  toPrim = PersistInt64 . fromIntegral
  fromPrim (PersistInt64 a) = fromIntegral a
  fromPrim x = error $ "Expected Integer, received: " ++ show x

instance Primitive Double where
  toPrim = PersistDouble
  fromPrim (PersistDouble a) = a
  fromPrim x = error $ "Expected Double, received: " ++ show x

instance Primitive Bool where
  toPrim = PersistBool
  fromPrim (PersistBool a) = a
  fromPrim (PersistInt64 i) = i /= 0
  fromPrim x = error $ "Expected Bool, received: " ++ show x

instance Primitive Day where
  toPrim = PersistDay
  fromPrim (PersistDay a) = a
  fromPrim x = readHelper x ("Expected Day, received: " ++ show x)

instance Primitive TimeOfDay where
  toPrim = PersistTimeOfDay
  fromPrim (PersistTimeOfDay a) = a
  fromPrim x = readHelper x ("Expected TimeOfDay, received: " ++ show x)

instance Primitive UTCTime where
  toPrim = PersistUTCTime
  fromPrim (PersistUTCTime a) = a
  fromPrim x = readHelper x ("Expected UTCTime, received: " ++ show x)

instance Primitive (Key a) where
  toPrim (Key a) = PersistInt64 a
  fromPrim (PersistInt64 a) = Key a
  fromPrim x = error $ "Expected Integer(entity key), received: " ++ show x

instance (Primitive a, NeverNull a) => Primitive (Maybe a) where
  toPrim = maybe PersistNull toPrim
  fromPrim PersistNull = Nothing
  fromPrim x = Just $ fromPrim x

instance NeverNull String
instance NeverNull T.Text
instance NeverNull ByteString
instance NeverNull Int
instance NeverNull Int64
instance NeverNull Double
instance NeverNull Bool
instance NeverNull Day
instance NeverNull TimeOfDay
instance NeverNull UTCTime
instance NeverNull (Key a)
instance NeverNull [a]
instance NeverNull (a, b)
instance NeverNull (a, b, c)
instance NeverNull (a, b, c, d)
instance NeverNull (a, b, c, d, e)
instance PersistEntity a => NeverNull a

instance Expression (Expr v c a) where
  type FuncV (Expr v c a) = v
  type FuncC (Expr v c a) = c
  type FuncA (Expr v c a) = a
  wrap = id

instance PersistEntity v => Expression (Fields v c a) where
  type FuncV (Fields v c a) = v
  type FuncC (Fields v c a) = c
  type FuncA (Fields v c a) = a
  wrap = ExprField

instance PersistEntity v => Expression (Arith v c a) where
  type FuncV (Arith v c a) = v
  type FuncC (Arith v c a) = c
  type FuncA (Arith v c a) = a
  wrap = ExprArith

instance (Expression a, Primitive a, NeverNull a) => Expression (Maybe a) where
  type FuncV (Maybe a) = Any
  type FuncC (Maybe a) = Any
  type FuncA (Maybe a) = (Maybe (FuncA a))
  wrap = ExprPlain

instance Expression (Key a) where
  type FuncV (Key a) = Any; type FuncC (Key a) = Any; type FuncA (Key a) = a
  wrap = ExprPlain

instance Expression Int where
  type FuncV Int = Any; type FuncC Int = Any; type FuncA Int = Int
  wrap = ExprPrim

instance Expression Int8 where
  type FuncV Int8 = Any; type FuncC Int8 = Any; type FuncA Int8 = Int8
  wrap = ExprPrim

instance Expression Int16 where
  type FuncV Int16 = Any; type FuncC Int16 = Any; type FuncA Int16 = Int16
  wrap = ExprPrim

instance Expression Int32 where
  type FuncV Int32 = Any; type FuncC Int32 = Any; type FuncA Int32 = Int32
  wrap = ExprPrim

instance Expression Int64 where
  type FuncV Int64 = Any; type FuncC Int64 = Any; type FuncA Int64 = Int64
  wrap = ExprPrim

instance Expression Word8 where
  type FuncV Word8 = Any; type FuncC Word8 = Any; type FuncA Word8 = Word8
  wrap = ExprPrim

instance Expression Word16 where
  type FuncV Word16 = Any; type FuncC Word16 = Any; type FuncA Word16 = Word16
  wrap = ExprPrim

instance Expression Word32 where
  type FuncV Word32 = Any; type FuncC Word32 = Any; type FuncA Word32 = Word32
  wrap = ExprPrim

instance Expression Word64 where
  type FuncV Word64 = Any; type FuncC Word64 = Any; type FuncA Word64 = Word64
  wrap = ExprPrim

instance Expression String where
  type FuncV String = Any; type FuncC String = Any; type FuncA String = String
  wrap = ExprPrim

instance Expression ByteString where
  type FuncV ByteString = Any; type FuncC ByteString = Any; type FuncA ByteString = ByteString
  wrap = ExprPrim

instance Expression T.Text where
  type FuncV T.Text = Any; type FuncC T.Text = Any; type FuncA T.Text = T.Text
  wrap = ExprPrim

instance Expression Bool where
  type FuncV Bool = Any; type FuncC Bool = Any; type FuncA Bool = Bool
  wrap = ExprPrim

readHelper :: Read a => PersistValue -> String -> a
readHelper s errMessage = case s of
  PersistString str -> readHelper' str
  PersistByteString str -> readHelper' (unpack str)
  _ -> error errMessage
  where
    readHelper' str = case reads str of
      (a, _):_ -> a
      _        -> error errMessage

instance PersistField ByteString where
  persistName _ = "ByteString"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbBlob

instance PersistField String where
  persistName _ = "String"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbString

instance PersistField T.Text where
  persistName _ = "Text"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbString

instance PersistField Int where
  persistName _ = "Int"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType a = if bitSize a == 32 then DbInt32 else DbInt64

instance PersistField Int8 where
  persistName _ = "Int8"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbInt64

instance PersistField Int16 where
  persistName _ = "Int16"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbInt64

instance PersistField Int32 where
  persistName _ = "Int32"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbInt64

instance PersistField Int64 where
  persistName _ = "Int64"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbInt64

instance PersistField Word8 where
  persistName _ = "Word8"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbInt64

instance PersistField Word16 where
  persistName _ = "Word16"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbInt64

instance PersistField Word32 where
  persistName _ = "Word32"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbInt64

instance PersistField Word64 where
  persistName _ = "Word64"
  toPersistValue = return . toPrim
  fromPersistValue = return . fromPrim
  dbType _ = DbInt64

instance PersistField Double where
  persistName _ = "Double"
  toPersistValue = return . PersistDouble
  fromPersistValue = return . fromPrim
  dbType _ = DbReal

instance PersistField Bool where
  persistName _ = "Bool"
  toPersistValue = return . PersistBool
  fromPersistValue = return . fromPrim
  dbType _ = DbBool

instance PersistField Day where
  persistName _ = "Day"
  toPersistValue = return . PersistDay
  fromPersistValue = return . fromPrim
  dbType _ = DbDay

instance PersistField TimeOfDay where
  persistName _ = "TimeOfDay"
  toPersistValue = return . PersistTimeOfDay
  fromPersistValue = return . fromPrim
  dbType _ = DbTime

instance PersistField UTCTime where
  persistName _ = "UTCTime"
  toPersistValue = return . PersistUTCTime
  fromPersistValue = return . fromPrim
  dbType _ = DbDayTime

instance (PersistField a, NeverNull a) => PersistField (Maybe a) where
  persistName (_ :: Maybe a) = "Maybe$" ++ persistName (undefined :: a)
  toPersistValue = maybe (return PersistNull) toPersistValue
  fromPersistValue PersistNull = return Nothing
  fromPersistValue x = liftM Just $ fromPersistValue x
  dbType (_ :: Maybe a) = DbMaybe $ namedType (undefined :: a)
  
instance (PersistEntity a) => PersistField (Key a) where
  persistName (_ :: Key a) = "Key$" ++ persistName (undefined :: a)
  toPersistValue (Key a) = return $ PersistInt64 a
  fromPersistValue = return . fromPrim
  dbType (_ :: Key a) = DbEntity $ entityDef (undefined :: a)

instance (PersistField a) => PersistField [a] where
  persistName (_ :: [a]) = "List$$" ++ persistName (undefined :: a)
  toPersistValue l = insertList l >>= toPersistValue
  fromPersistValue k = getList (fromPrim k)
  dbType (_ :: [a]) = DbList $ namedType (undefined :: a)

instance (PersistField a, PersistField b) => PersistField (a, b) where
  persistName (_ :: (a, b)) = "Tuple2$$" ++ persistName (undefined :: a) ++ "$" ++ persistName (undefined :: b)
  toPersistValue x@(a, b) = do
    vals <- sequence [toPersistValue a, toPersistValue b]
    liftM PersistInt64 $ insertTuple (namedType x) vals 
  fromPersistValue (PersistInt64 key) = do
    [a, b] <- getTuple (namedType (undefined :: (a, b))) key
    liftM2 (,) (fromPersistValue a) (fromPersistValue b)
  fromPersistValue x = fail $ "Expected Integer(tuple key), received: " ++ show x
  dbType (_ :: (a, b)) = DbTuple 2 [namedType (undefined :: a), namedType (undefined :: b)]
  
instance (PersistField a, PersistField b, PersistField c) => PersistField (a, b, c) where
  persistName (_ :: (a, b, c)) = "Tuple3$$" ++ persistName (undefined :: a) ++ "$" ++ persistName (undefined :: b) ++ "$" ++ persistName (undefined :: c)
  toPersistValue x@(a, b, c) = do
    vals <- sequence [toPersistValue a, toPersistValue b, toPersistValue c]
    liftM PersistInt64 $ insertTuple (namedType x) vals 
  fromPersistValue (PersistInt64 key) = do
    [a, b, c] <- getTuple (namedType (undefined :: (a, b, c))) key
    liftM3 (,,) (fromPersistValue a) (fromPersistValue b) (fromPersistValue c)
  fromPersistValue x = fail $ "Expected Integer(tuple key), received: " ++ show x
  dbType (_ :: (a, b, c)) = DbTuple 3 [namedType (undefined :: a), namedType (undefined :: b), namedType (undefined :: c)]
  
instance (PersistField a, PersistField b, PersistField c, PersistField d) => PersistField (a, b, c, d) where
  persistName (_ :: (a, b, c, d)) = "Tuple4$$" ++ persistName (undefined :: a) ++ "$" ++ persistName (undefined :: b) ++ "$" ++ persistName (undefined :: c) ++ "$" ++ persistName (undefined :: d)
  toPersistValue x@(a, b, c, d) = do
    vals <- sequence [toPersistValue a, toPersistValue b, toPersistValue c, toPersistValue d]
    liftM PersistInt64 $ insertTuple (namedType x) vals 
  fromPersistValue (PersistInt64 key) = do
    [a, b, c, d] <- getTuple (namedType (undefined :: (a, b, c, d))) key
    liftM4 (,,,) (fromPersistValue a) (fromPersistValue b) (fromPersistValue c) (fromPersistValue d)
  fromPersistValue x = fail $ "Expected Integer(tuple key), received: " ++ show x
  dbType (_ :: (a, b, c, d)) = DbTuple 4 [namedType (undefined :: a), namedType (undefined :: b), namedType (undefined :: c), namedType (undefined :: d)]
  
instance (PersistField a, PersistField b, PersistField c, PersistField d, PersistField e) => PersistField (a, b, c, d, e) where
  persistName (_ :: (a, b, c, d, e)) = "Tuple5$$" ++ persistName (undefined :: a) ++ "$" ++ persistName (undefined :: b) ++ "$" ++ persistName (undefined :: c) ++ "$" ++ persistName (undefined :: d) ++ "$" ++ persistName (undefined :: e)
  toPersistValue x@(a, b, c, d, e) = do
    vals <- sequence [toPersistValue a, toPersistValue b, toPersistValue c, toPersistValue d, toPersistValue e]
    liftM PersistInt64 $ insertTuple (namedType x) vals 
  fromPersistValue (PersistInt64 key) = do
    [a, b, c, d, e] <- getTuple (namedType (undefined :: (a, b, c, d, e))) key
    liftM5 (,,,,) (fromPersistValue a) (fromPersistValue b) (fromPersistValue c) (fromPersistValue d) (fromPersistValue e)
  fromPersistValue x = fail $ "Expected Integer(tuple key), received: " ++ show x
  dbType (_ :: (a, b, c, d, e)) = DbTuple 5 [namedType (undefined :: a), namedType (undefined :: b), namedType (undefined :: c), namedType (undefined :: d), namedType (undefined :: e)]