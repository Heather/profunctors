{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiParamTypeClasses #-}

#if __GLASGOW_HASKELL__ >= 704 && __GLASGOW_HASKELL__ < 708
{-# LANGUAGE Trustworthy #-}
#endif

-----------------------------------------------------------------------------
-- |
-- Copyright   :  (C) 2014-2015 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
----------------------------------------------------------------------------
module Data.Profunctor.Closed
  ( Closed(..)
  , Closure(..)
  , close
  , unclose
  , Environment(..)
  , curry'
  ) where

import Control.Applicative
import Control.Arrow
import Control.Category
import Control.Comonad
import Data.Bifunctor.Product (Product(..))
import Data.Bifunctor.Tannen (Tannen(..))
import Data.Distributive
import Data.Monoid hiding (Product)
import Data.Profunctor.Adjunction
import Data.Profunctor.Monad
import Data.Profunctor.Strong
import Data.Profunctor.Types
import Data.Profunctor.Unsafe
import Data.Tagged
import Data.Tuple
import Prelude hiding ((.),id)

--------------------------------------------------------------------------------
-- * Closed
--------------------------------------------------------------------------------

-- | A strong profunctor allows the monoidal structure to pass through.
--
-- A closed profunctor allows the closed structure to pass through.
class Profunctor p => Closed p where
  closed :: p a b -> p (x -> a) (x -> b)

instance Closed Tagged where
  closed (Tagged b) = Tagged (const b)

instance Closed (->) where
  closed = (.)

instance Functor f => Closed (Costar f) where
  closed (Costar fab) = Costar $ \fxa x -> fab (fmap ($x) fxa)

instance Functor f => Closed (Cokleisli f) where
  closed (Cokleisli fab) = Cokleisli $ \fxa x -> fab (fmap ($x) fxa)

instance Distributive f => Closed (Star f) where
  closed (Star afb) = Star $ \xa -> distribute $ \x -> afb (xa x)

instance (Distributive f, Monad f) => Closed (Kleisli f) where
  closed (Kleisli afb) = Kleisli $ \xa -> distribute $ \x -> afb (xa x)

instance (Closed p, Closed q) => Closed (Product p q) where
  closed (Pair p q) = Pair (closed p) (closed q)

instance (Functor f, Closed p) => Closed (Tannen f p) where
  closed (Tannen fp) = Tannen (fmap closed fp)

-- instance Monoid r => Closed (Forget r) where
--  closed _ = Forget $ \_ -> mempty

curry' :: Closed p => p (a, b) c -> p a (b -> c)
curry' = lmap (,) . closed

--------------------------------------------------------------------------------
-- * Closure
--------------------------------------------------------------------------------

-- | 'Closure' adjoins a 'Closed' structure to any 'Profunctor'.
--
-- Analogous to 'Data.Profunctor.Tambara.Tambara' for 'Strong'.

newtype Closure p a b = Closure { runClosure :: forall x. p (x -> a) (x -> b) }

instance Profunctor p => Profunctor (Closure p) where
  dimap f g (Closure p) = Closure $ dimap (fmap f) (fmap g) p
  lmap f (Closure p) = Closure $ lmap (fmap f) p
  rmap f (Closure p) = Closure $ rmap (fmap f) p
  w #. Closure p = Closure $ fmap w #. p
  Closure p .# w = Closure $ p .# fmap w

instance ProfunctorFunctor Closure where
  promap f (Closure p) = Closure (f p)

instance ProfunctorComonad Closure where
  proextract = dimap const ($ ()) . runClosure
  produplicate (Closure p) = Closure $ Closure $ dimap uncurry curry p

instance Profunctor p => Closed (Closure p) where
  closed = runClosure . produplicate

instance Strong p => Strong (Closure p) where
  first' (Closure p) = Closure $ dimap hither yon $ first' p

instance Category p => Category (Closure p) where
  id = Closure id
  Closure p . Closure q = Closure (p . q)

hither :: (s -> (a,b)) -> (s -> a, s -> b)
hither h = (fst . h, snd . h)

yon :: (s -> a, s -> b) -> s -> (a,b)
yon h s = (fst h s, snd h s)

instance Arrow p => Arrow (Closure p) where
  arr f = Closure (arr (f .))
  first (Closure f) = Closure $ arr yon . first f . arr hither

instance ArrowLoop p => ArrowLoop (Closure p) where
  loop (Closure f) = Closure $ loop (arr hither . f . arr yon)

instance ArrowZero p => ArrowZero (Closure p) where
  zeroArrow = Closure zeroArrow

instance ArrowPlus p => ArrowPlus (Closure p) where
  Closure f <+> Closure g = Closure (f <+> g)

instance Profunctor p => Functor (Closure p a) where
  fmap = rmap

instance (Profunctor p, Arrow p) => Applicative (Closure p a) where
  pure x = arr (const x)
  f <*> g = arr (uncurry id) . (f &&& g)

instance (Profunctor p, ArrowPlus p) => Alternative (Closure p a) where
  empty = zeroArrow
  f <|> g = f <+> g

instance (Profunctor p, Arrow p, Monoid b) => Monoid (Closure p a b) where
  mempty = pure mempty
  mappend = liftA2 mappend

-- |
-- @
-- 'close' '.' 'unclose' ≡ 'id'
-- 'unclose' '.' 'close' ≡ 'id'
-- @
close :: Closed p => (p :-> q) -> p :-> Closure q
close f p = Closure $ f $ closed p

-- |
-- @
-- 'close' '.' 'unclose' ≡ 'id'
-- 'unclose' '.' 'close' ≡ 'id'
-- @
unclose :: Profunctor q => (p :-> Closure q) -> p :-> q
unclose f p = dimap const ($ ()) $ runClosure $ f p

--------------------------------------------------------------------------------
-- * Environment
--------------------------------------------------------------------------------

data Environment p a b where
  Environment :: ((z -> y) -> b) -> p x y -> (a -> z -> x) -> Environment p a b

instance Profunctor (Environment p) where
  dimap f g (Environment l m r) = Environment (g . l) m (r . f)
  lmap f (Environment l m r) = Environment l m (r . f)
  rmap g (Environment l m r) = Environment (g . l) m r
  w #. Environment l m r = Environment (w #. l) m r
  Environment l m r .# w = Environment l m (r .# w)

instance ProfunctorFunctor Environment where
  promap f (Environment l m r) = Environment l (f m) r

instance ProfunctorMonad Environment where
  proreturn p = Environment ($ ()) p const
  projoin (Environment l (Environment m n o) p) = Environment (lm . curry) n op where
    op a (b, c) = o (p a b) c
    lm zr = l (m.zr)

instance ProfunctorAdjunction Environment Closure where
  counit (Environment g (Closure p) f) = dimap f g p
  unit p = Closure (Environment id p id)

instance Closed (Environment p) where
  closed (Environment l m r) = Environment l' m r' where
    r' wa (z,w) = r (wa w) z
    l' zx2y x = l (\z -> zx2y (z,x))
