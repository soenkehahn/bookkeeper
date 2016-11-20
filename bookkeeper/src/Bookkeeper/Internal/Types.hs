{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeFamilyDependencies #-}

module Bookkeeper.Internal.Types where

import Control.Monad.Identity
import Data.Bifunctor (first)
import Data.Default.Class (Default(..))
import Data.Kind (Type)
import Data.Monoid ((<>))
import Data.List (intercalate)
import Data.Proxy
import Data.Type.Equality (type (==))
import GHC.Generics
import GHC.OverloadedLabels
import GHC.TypeLits (Symbol, TypeError, ErrorMessage(Text), CmpSymbol, KnownSymbol, symbolVal)

------------------------------------------------------------------------------
-- :=>
------------------------------------------------------------------------------

data (a :: Symbol) :=> (b :: k)

------------------------------------------------------------------------------
-- Key
------------------------------------------------------------------------------

-- | 'Key' is simply a proxy. You will usually not need to create one
-- directly, as it is generated by the OverlodadedLabels magic.
data Key (a :: Symbol) = Key
  deriving (Eq, Read, Generic)

instance KnownSymbol key => Show (Key key) where
  show _ = '#':(symbolVal (Proxy :: Proxy key))

instance (s ~ s') => IsLabel s (Key s') where
  fromLabel _ = Key
  {-# INLINE fromLabel #-}

------------------------------------------------------------------------------
-- Book
------------------------------------------------------------------------------

data Book' :: (k -> Type) -> [Type] -> Type where
  BNil :: Book' f '[]
  BCons :: !(f a) -> !(Book' f as) -> Book' f (k :=> a ': as)

-- * Instances

-- ** Eq

instance Eq (Book' f '[]) where
  _ == _ = True

instance (Eq (f val), Eq (Book' f xs)) => Eq (Book' f ((field :=> val) ': xs)) where
  BCons value1 rest1 == BCons value2 rest2
    = value1 == value2 && rest1 == rest2

-- ** Monoid

instance Monoid (Book' Identity '[]) where
  mempty = emptyBook
  _ `mappend` _ = emptyBook

-- ** Default

instance Default (Book' Identity '[]) where
  def = emptyBook

instance ( Default (Book' f xs)
         , Default (f v)
         ) => Default (Book' f ((k :=> v) ': xs)) where
  def = BCons def def

-- | A book with no records. You'll usually want to use this to construct
-- books.
emptyBook :: Book' Identity '[]
emptyBook = BNil

-- ** Show

instance ShowHelper (Book' Identity a) => Show (Book' Identity a) where
  show x = "Book {" <> intercalate ", " (go <$> showHelper x) <> "}"
    where
      go (k, v) = k <> " = " <> v

class ShowHelper a where
  showHelper :: a -> [(String, String)]

instance ShowHelper (Book' Identity '[]) where
  showHelper _ = []

instance ( ShowHelper (Book' Identity xs)
         , Show v
         , KnownSymbol k
         ) => ShowHelper (Book' Identity ((k :=> v) ': xs)) where
  showHelper (BCons v rest) = (show k, show v):showHelper rest
    where
      k :: Key k
      k = Key

-- ** MFunctor

{-
instance MFunctor Book' where
  hoist f book = case book of
    BNil -> BNil
    BCons key value rest -> BCons key (f value) (hoist f rest)
-}
-- ** Generics

class FromGeneric a book | a -> book where
  fromGeneric :: a x -> Book' Identity book

instance FromGeneric cs book => FromGeneric (D1 m cs) book where
  fromGeneric (M1 xs) = fromGeneric xs

instance FromGeneric cs book => FromGeneric (C1 m cs) book where
  fromGeneric (M1 xs) = fromGeneric xs

instance (v ~ '[name :=> t])
  => FromGeneric (S1 ('MetaSel ('Just name) p s l) (Rec0 t)) v where
  fromGeneric (M1 (K1 t)) = BCons (Identity t) emptyBook

instance
  ( FromGeneric l leftBook
  , FromGeneric r rightBook
  , unionBook ~ (Union leftBook rightBook)
  , Unionable leftBook rightBook
  ) => FromGeneric (l :*: r) unionBook where
  fromGeneric (l :*: r)
    = union (fromGeneric l) (fromGeneric r)

type family Expected a where
  Expected (l :+: r) = TypeError ('Text "Cannot convert sum types into Books")
  Expected U1        = TypeError ('Text "Cannot convert non-record types into Books")

instance (book ~ Expected (l :+: r)) => FromGeneric (l :+: r) book where
  fromGeneric = error "impossible"

instance (book ~ Expected U1) => FromGeneric U1 book where
  fromGeneric = error "impossible"

------------------------------------------------------------------------------
-- Ledger
------------------------------------------------------------------------------


data Ledger' :: (k -> Type) -> [Type] -> Type where
  Here :: !(f value) -> Ledger' f ( field :=> value ': restOfLedger)
  There :: Ledger' f restOfLedger -> Ledger' f ( field :=> value ': restOfLedger)

instance Eq (Ledger' f '[]) where
  _ == _ = True

instance (Eq (f val), Eq (Ledger' f xs)) => Eq (Ledger' f ((field :=> val) ': xs)) where
  a == b = case (a, b) of
    (Here value1, Here value2) -> value1 == value2
    (There rest1, There rest2) -> rest1 == rest2
    (_          , _          ) -> False

instance
  (KnownSymbol key, Show (f value))
  => Show (Ledger' f '[key :=> value]) where
  show (Here x) = "option' " ++ show key ++ " (" ++ show x ++ ")"
    where
      key :: Key key
      key = Key
  -- This isn't really impossible, since sum-errors catches errors down to
  -- this.
  show (There _) = error "impossible"

instance
  (KnownSymbol key, Show (f value), Show (Ledger' f (next ': restOfMap)))
  => Show (Ledger' f (key :=> value ': next ': restOfMap)) where
  show (Here x) = "option' " ++ show key ++ " (" ++ show x ++ ")"
    where
      key :: Key key
      key = Key
  show (There x) = show x

instance Ord (f value) => Ord (Ledger' f '[ key :=> value]) where
  Here x <= Here y = x <= y
  _ <= _ = error "impossible"

instance (Ord (f value), Ord (Ledger' f rest))
  => Ord (Ledger' f (key :=> value ': rest)) where
  Here x <= Here y = x <= y
  Here _ <= There _ = True
  There _ <= Here _ = False
  There x <= There y = x <= y

------------------------------------------------------------------------------
-- Internal stuff
------------------------------------------------------------------------------

-- Insertion sort for simplicity.
type family Sort unsorted sorted where
   Sort '[] sorted = sorted
   Sort (key :=> value ': xs) sorted = Sort xs (Insert key value sorted)

type family Insert key value oldMap where
  Insert key value '[] = '[ key :=> value ]
  Insert key value (key :=> someValue ': restOfMap) = (key :=> value ': restOfMap)
  Insert key value (focusKey :=> someValue ': restOfMap)
    = Ifte (CmpSymbol key focusKey == 'LT)
         (key :=> value ': focusKey :=> someValue ': restOfMap)
         (focusKey :=> someValue ': Insert key value restOfMap)

type family Ifte cond iftrue iffalse where
  Ifte 'True iftrue iffalse = iftrue
  Ifte 'False iftrue iffalse = iffalse

------------------------------------------------------------------------------
-- Subset
------------------------------------------------------------------------------

class Subset set subset where
  getSubset :: Book' f set -> Book' f subset

instance Subset '[] '[] where
  getSubset = id
  {-# INLINE getSubset #-}
instance {-# OVERLAPPING #-} (Subset tail1 tail2, value ~ value')
  => Subset (key :=> value ': tail1) (key :=> value' ': tail2) where
  getSubset (BCons value oldBook) = BCons value $ getSubset oldBook
  {-# INLINE getSubset #-}
instance {-# OVERLAPPABLE #-} (Subset tail subset) => Subset (head ': tail) subset where
  getSubset (BCons _value oldBook) = getSubset oldBook
  {-# INLINE getSubset #-}


------------------------------------------------------------------------------
-- Insertion
------------------------------------------------------------------------------

class Insertable key value oldMap where
  insert :: Key key -> f value -> Book' f oldMap -> Book' f (Insert key value oldMap)

instance Insertable key value '[] where
  insert _key value oldBook = BCons value oldBook
  {-# INLINE insert #-}

instance  {-# OVERLAPPING #-}
  Insertable key value (key :=> someValue ': restOfMap) where
  insert _key value (BCons _ oldBook) = BCons value oldBook
  {-# INLINE insert #-}

instance {-# OVERLAPPABLE #-}
  ( Insertable' (CmpSymbol key oldKey) key value
     (oldKey :=> oldValue ': restOfMap)
     (Insert key value (oldKey :=> oldValue ': restOfMap))
  ) => Insertable key value (oldKey :=> oldValue ': restOfMap) where
  insert key value oldBook = insert' flag key value oldBook
    where
      flag :: Proxy (CmpSymbol key oldKey)
      flag = Proxy
  {-# INLINE insert #-}

class Insertable' flag key value oldMap newMap
  | flag key value oldMap -> newMap
  where
  insert' :: Proxy flag -> Key key -> f value -> Book' f oldMap -> Book' f newMap

instance Insertable' 'LT key value
  oldMap
  (key :=> value ': oldMap) where
  insert' _ _key value oldBook = BCons value oldBook
  {-# INLINE insert' #-}
instance Insertable' 'EQ key value
  (key :=> oldValue ': restOfMap)
  (key :=> value ': restOfMap) where
  insert' _ _key value (BCons _ oldBook) = BCons value oldBook
  {-# INLINE insert' #-}
instance (newMap ~ Insert key value restOfMap, Insertable key value restOfMap) => Insertable' 'GT key value
  (oldKey :=> oldValue ': restOfMap)
  (oldKey :=> oldValue ': newMap) where
  insert' _ key value (BCons oldValue oldBook) = BCons oldValue (insert key value oldBook)
  {-# INLINE insert' #-}

------------------------------------------------------------------------------
-- Option
------------------------------------------------------------------------------

class Optionable key value newMap | key newMap -> value where
  option' :: Key key -> f value -> Ledger' f newMap

instance {-# OVERLAPPING #-} Optionable key value (key :=> value ': restOfMap) where
  option' _key value = Here value
instance {-# OVERLAPPABLE #-}
  ( Optionable key value restOfMap
  ) => Optionable key value (oldKey :=> oldValue ': restOfMap) where
  option' key value = There (option' key value)

option :: (Optionable key value newMap) => Key key -> value -> Ledger' Identity newMap
option key value = option' key (Identity value)

------------------------------------------------------------------------------
-- Split
------------------------------------------------------------------------------

class Split key map value | key map -> value where
  split' :: Key key -> Ledger' f map
      -> Either (Ledger' f (Delete key map)) (f value)

instance {-# OVERLAPPING #-} Split key (key :=> value ': restOfMap) value where
  split' _ ledger = case ledger of
    Here x -> Right x
    There y -> Left y

instance {-# OVERLAPPABLE #-}
   ( Delete key (otherKey :=> otherValue ': restOfMap)
   ~ (otherKey :=> otherValue ': Delete key restOfMap)
   , Split key restOfMap value
   )
    => Split key (otherKey :=> otherValue ': restOfMap) value where
  split' key ledger = case ledger of
    Here x -> Left (Here x)
    There y -> first There (split' key y)

split :: (Split key ledger value) =>
  Key key -> Ledger' Identity ledger -> Either (Ledger' Identity  (Delete key ledger)) value
split key ledger = runIdentity <$> split' key ledger

getIf :: (Split key map value) => Key key -> Ledger' Identity map -> Maybe value
getIf key ledger = case split' key ledger of
  Right e -> Just $ runIdentity e
  Left  _ -> Nothing

------------------------------------------------------------------------------
-- Deletion
------------------------------------------------------------------------------

type family Delete keyToDelete oldBook where
  Delete keyToDelete (keyToDelete :=> someValue ': xs) = xs
  Delete keyToDelete (anotherKey :=> someValue ': xs)
    = (anotherKey :=> someValue ': Delete keyToDelete xs)

------------------------------------------------------------------------------
-- Union
------------------------------------------------------------------------------

type family Union leftBook rightBook where
  Union leftBook '[] = leftBook
  Union leftBook (key :=> value ': rest) = Union (Insert key value leftBook) rest

class Unionable leftBook rightBook where
  union :: Book' f leftBook -> Book' f rightBook -> Book' f (Union leftBook rightBook)
