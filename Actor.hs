--------------------------------------------------------------------------------

{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTSyntax                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeFamilyDependencies     #-}
{-# LANGUAGE TypeInType                 #-}

--------------------------------------------------------------------------------

-- |
--   Module      :  Control.Concurrent.Actor
--   Copyright   :  © 2017 Remy Goldschmidt
--   License     :  Apache-2.0
--   Maintainer  :  taktoa@gmail.com
--   Stability   :  alpha
--
--   This module implements actor model concurrency on top of the 'MonadConc'
--   class from <https://hackage.haskell.org/package/concurrency concurrency>.
--
--   The API described below was inspired by the
--   <https://hackage.haskell.org/package/thespian thespian> package,
--   but it improves on that API in the following ways:
--     * It has stronger type safety for the messages sent between actors.
--     * It has a built-in notion of actor state, which is useful for
--       implementing
--
--   FIXME: add an example
module Actor
  where
--   ( -- * The @ActorT@ monad transformer
--     ActorT
--
--     -- * Actor spawning and addresses
--   , Address
--   , spawn
--   , self
--
--     -- * Sending and receiving
--   , send
--   , receive
--
--     -- * Modifying actor state
--   , get
--   , put
--   , state
--   , modify
--   , embedStateT
--   , embedST
--   ) where

--------------------------------------------------------------------------------

-- MTL-style typeclasses

import           Control.Monad.IO.Class           (MonadIO)
import qualified Control.Monad.IO.Class           as MonadIO

import           Control.Monad.Trans.Class        (MonadTrans)
import qualified Control.Monad.Trans.Class        as MonadTrans

import           Control.Monad.State.Class        (MonadState)
import qualified Control.Monad.State.Class        as MonadState

import           Control.Monad.Conc.Class         (MonadConc)
import qualified Control.Monad.Conc.Class         as MonadConc

import           Control.Monad.Catch              (MonadThrow)
import qualified Control.Monad.Catch              as MonadThrow

import           Control.Monad.Catch              (MonadCatch)
import qualified Control.Monad.Catch              as MonadCatch

import           Control.Monad.Catch              (MonadMask)
import qualified Control.Monad.Catch              as MonadMask

--------------------------------------------------------------------------------

-- Other typeclasses

import           Data.Typeable                    (Typeable)

--------------------------------------------------------------------------------

-- Monads and monad transformers

import           Control.Monad.ST                 (ST)
import qualified Control.Monad.ST                 as ST

import           Control.Monad.Trans.State.Strict (StateT)
import qualified Control.Monad.Trans.State.Strict as StateT

import           Control.Monad.Trans.Reader       (ReaderT)
import qualified Control.Monad.Trans.Reader       as ReaderT

--------------------------------------------------------------------------------

-- Data types

import           Data.STRef                       (STRef)
import qualified Data.STRef                       as STRef

import           Control.Concurrent.Classy.Chan   (Chan)
import qualified Control.Concurrent.Classy.Chan   as Chan

import           Control.Concurrent.Classy.MVar   (MVar)
import qualified Control.Concurrent.Classy.MVar   as MVar

--------------------------------------------------------------------------------

-- Other stuff

import           Data.Kind                        (Type)

import           Data.Proxy                       (Proxy (Proxy))

import           Data.Functor.Contravariant       (Contravariant (contramap))

import qualified Control.Lens                     as Lens

import           Control.Monad                    (forever, (>=>))

import           Flow                             ((.>), (|>))

--------------------------------------------------------------------------------

type TID u = MonadConc.ThreadId u

-- | FIXME: doc
class ( Monad m, MonadState (S m) m, MonadConc (U m)
      ) => MonadActor m where

  -- | FIXME: doc
  type family A m :: Type -> Type

  -- | FIXME: doc
  type family S m :: Type

  -- | FIXME: doc
  type family M m :: Type

  -- | FIXME: doc
  type family U m :: Type -> Type

  -- | FIXME: doc
  addrToTID :: proxy m -> A m a -> TID (U m)

  -- | FIXME: doc
  spawn :: S m -> m () -> U m (A m (M m))

  -- | FIXME: doc
  self :: m (A m (M m))

  -- | FIXME: doc
  send :: forall msg. A m msg -> msg -> m ()

  -- | FIXME: doc
  recv :: (M m -> m a) -> m ()

-- | FIXME: doc
selfTID :: forall m. (MonadActor m) => m (TID (U m))
selfTID = addrToTID (Proxy @m) <$> self

--------------------------------------------------------------------------------

-- | The actor monad transformer.
--
--   The @st@ type parameter represents the underlying state of the actor.
--
--   The @msg@ type parameter represents the type of messages that can be
--   received by this actor.
--
--   The @m@ type parameter represents the underlying monad for this
--   monad transformer. In most cases this will need to have a 'MonadConc'
--   instance at the very least. In production, this will probably be 'IO'.
--
--   The @ret@ type parameter represents the value returned by this actor
--   monadic action value.
newtype ActorT st msg m ret
  = ActorT (ReaderT (Context st msg m) m ret)

deriving instance (Functor     m) => Functor     (ActorT st msg m)
deriving instance (Applicative m) => Applicative (ActorT st msg m)
deriving instance (Monad       m) => Monad       (ActorT st msg m)
deriving instance (MonadIO     m) => MonadIO     (ActorT st msg m)
deriving instance (MonadThrow  m) => MonadThrow  (ActorT st msg m)
deriving instance (MonadCatch  m) => MonadCatch  (ActorT st msg m)
deriving instance (MonadMask   m) => MonadMask   (ActorT st msg m)

-- | Uses the 'MonadTrans' instance of the underlying 'ReaderT' transformer.
instance MonadTrans (ActorT st msg) where
  lift action = ActorT (MonadTrans.lift action)

-- | Allows easy use of the actor state variable.
instance (MonadConc m) => MonadState st (ActorT st msg m) where
  get = do
    var <- contextState <$> ActorT ReaderT.ask
    MonadTrans.lift (MVar.readMVar var)

  put value = do
    var <- contextState <$> ActorT ReaderT.ask
    MonadTrans.lift (MVar.putMVar var value)

-- | FIXME: doc
data Mailbox u msg
  = Mailbox
    { _mailboxThreadId :: !(TID u)
    , _mailboxSend     :: !(msg -> u ())
    }

-- | Given a function from @b -> a@, we can always construct a function from
--   @'Mailbox' a -> 'Mailbox' b@, since a @'Mailbox' u msg@ is just a pair of
--   a sender function @msg -> u ()@ and a @'TID' u@.
instance Contravariant (Mailbox u) where
  contramap f (Mailbox tid s) = Mailbox tid (f .> s)

-- | The 'ActorT' monad is, of course, an instance of 'MonadActor'.
instance forall st msg u. (MonadConc u) => MonadActor (ActorT st msg u) where
  type A (ActorT st msg u) = Mailbox u
  type S (ActorT st msg u) = st
  type M (ActorT st msg u) = msg
  type U (ActorT st msg u) = u

  -- addrToTID :: proxy m -> A m a -> TID (U m)
  addrToTID :: proxy m -> Mailbox u a -> TID u
  addrToTID _ = _mailboxThreadId

  -- spawn :: S m -> m () -> U m (A m msg)
  spawn :: st -> ActorT st msg u () -> u (Mailbox u msg)
  spawn initial (ActorT act) = do
    chan     <- Chan.newChan
    stateVar <- MVar.newMVar initial
    let ctx = Context { contextChan  = chan
                      , contextState = stateVar
                      }
    tid <- MonadConc.fork (ReaderT.runReaderT act ctx)
    pure (Mailbox tid (Chan.writeChan chan))

  -- self :: m (A m (M m))
  self :: ActorT st msg u (Mailbox u msg)
  self = do
    chan <- ActorT (ReaderT.asks contextChan)
    tid <- MonadTrans.lift MonadConc.myThreadId
    pure (Mailbox tid (Chan.writeChan chan))

  -- send :: forall message. A m message -> message -> m ()
  send :: forall message. Mailbox u message -> message -> ActorT st msg u ()
  send addr msg = do
    MonadTrans.lift $ _mailboxSend addr msg

  -- recv :: (M m -> m a) -> m ()
  recv :: (msg -> ActorT st msg u a) -> ActorT st msg u ()
  recv handler = do
    chan <- ActorT (ReaderT.asks contextChan)
    MonadTrans.lift (Chan.readChan chan) >>= handler
    pure ()

--------------------------------------------------------------------------------

-- This datatype contains any values that an actor needs access to during
-- execution.
data Context st msg m
  = Context
    { contextChan  :: !(Chan m msg)
    , contextState :: !(MVar m st)
    }

--------------------------------------------------------------------------------

-- | Return the state from the internals of the monad.
--
--   This function is the same as 'MonadState.get' from
--   "Control.Monad.State.Class", except it has a more specific type.
get
  :: (MonadActor m)
  => m (S m)
  -- ^ An actor action that returns the current actor state.
get = MonadState.get

-- | Replace the state inside the monad.
--
--   This function is the same as 'MonadState.put' from
--   "Control.Monad.State.Class", except it has a more specific type.
put
  :: (MonadActor m)
  => S m
  -- ^ The new state to which the actor state will be set.
  -> m ()
  -- ^ An actor action that sets the actor state to the new state.
put = MonadState.put

-- | Embed a simple state action into the monad.
--
--   This function is the same as 'MonadState.state' from
--   "Control.Monad.State.Class", except it has a more specific type.
state
  :: (MonadActor m)
  => (S m -> (ret, S m))
  -- ^ A function that, given the current state, returns an arbitrary value
  --   along with a new state.
  -> m ret
  -- ^ An actor action that runs the function on the current state,
  --   sets the actor state to the new state, and returns the arbitrary
  --   value.
state = MonadState.state

-- | Maps an old state to a new state inside a state monad.
--   The old state is thrown away.
--
--   This function is the same as 'MonadState.modify' from
--   "Control.Monad.State.Class", except it has a more specific type.
modify
  :: (MonadActor m)
  => (S m -> S m)
  -- ^ A function from the state type to itself.
  -> m ()
  -- ^ An 'ActorT' action that replaces the state with the result of
  --   running the given function on the old state.
modify = MonadState.modify

-- | Convert a 'StateT' state transformer value to an 'ActorT' action that
--   modifies the actor state using the state transformer.
embedStateT
  :: (Monad m, MonadActor m)
  => StateT (S m) m ret
  -- ^ A monadic state transformer.
  -> m ret
  -- ^ An actor action that modifies the actor state using the
  --   given state transformer.
embedStateT action = do
  s <- MonadState.get
  (ret, s') <- StateT.runStateT action s
  MonadState.put s'
  pure ret

-- | Given a function @f@ from an @'STRef' s st@ to an @'ST' s ret@ action,
--   produce an @'ActorT' st msg m ret@ action that does the following:
--
--     1. It gets the current actor state, and saves it to @s@.
--     2. It runs an 'ST' action that does the following:
--         1. It creates an 'STRef' called @var@ that is initialized to @s@.
--         2. It runs @f var@, saving the result to @ret@.
--         3. It reads @var@, saving the result to @s'@.
--         4. It returns @(ret, s')@
--     3. The result of step 2 is saved to @(ret, s')@.
--     4. The actor state is set to @s'@.
--     5. Finally, @ret@ is returned.
embedST
  :: (MonadActor m)
  => (forall s. STRef s (S m) -> ST s ret)
  -- ^ An 'ST' action that can mutate the given 'STRef' and return an
  --   arbitrary value.
  -> m ret
  -- ^ An 'ActorT' action that uses the 'ST' action to mutate the actor
  --   state, and then returns the arbitrary value produced by the 'ST'
  --   action.
embedST f = do
  s <- MonadState.get
  (ret, s') <- pure $ ST.runST $ do
    var <- STRef.newSTRef s
    ret <- f var
    s' <- STRef.readSTRef var
    pure (ret, s')
  MonadState.put s'
  pure ret

--------------------------------------------------------------------------------
