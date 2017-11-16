--------------------------------------------------------------------------------

{-# LANGUAGE ExistentialQuantification, TypeInType  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTSyntax                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeFamilyDependencies     #-}

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

import Data.Kind (Type)

import           Data.Proxy                       (Proxy (Proxy))

import qualified Control.Lens                     as Lens

import           Control.Monad                    (forever, (>=>))

import           Flow                             ((.>), (|>))

--------------------------------------------------------------------------------

type TID m = MonadConc.ThreadId m

-- | FIXME: doc
class ( Monad m, MonadState st m, MonadConc (Underlying m)
      , Eq (Addr m), Ord (Addr m), Show (Addr m)
      ) => MonadActor st msg m | m -> st, m -> msg where

  -- | FIXME: doc
  type family Addr m :: Type

  -- | FIXME: doc
  type family Underlying m :: Type -> Type

  -- | FIXME: doc
  addrToTID :: proxy m -> Addr m -> TID (Underlying m)

  -- | FIXME: doc
  spawn :: st -> m () -> Underlying m (Addr m)

  -- | FIXME: doc
  self :: m (Addr m)

  -- | FIXME: doc
  send :: Addr m -> msg -> m ()

  -- | FIXME: doc
  recv :: (msg -> m a) -> m ()

-- | FIXME: doc
selfTID :: forall m st msg. (MonadActor st msg m) => m (TID (Underlying m))
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

data Mailbox m msg
  = Mailbox
    { mailboxThreadId :: !(MonadConc.ThreadId m)
    , mailboxSend     :: !(msg -> m ())
    }

-- | The 'ActorT' monad is, of course, an instance of 'MonadActor'.
instance (MonadConc m) => MonadActor st msg (ActorT st msg m) where
  type Addr (ActorT st msg m) = Mailbox m msg

  type Underlying (ActorT st msg m) = m

  addrToTID _ = mailboxThreadId

  spawn initial (ActorT act) = do
    chan     <- Chan.newChan
    stateVar <- MVar.newMVar initial
    let ctx = Context { contextChan  = chan
                      , contextState = stateVar
                      }
    tid <- MonadConc.fork (ReaderT.runReaderT act ctx)
    pure (Mailbox tid (Chan.writeChan chan))

  self = do
    chan <- ActorT (ReaderT.asks contextChan)
    tid <- MonadTrans.lift MonadConc.myThreadId
    pure (Mailbox tid (Chan.writeChan chan))

  send addr msg = do
    MonadTrans.lift $ mailboxSend addr msg

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

-- instance ( Eq (MonadConc.ThreadId m)
--          ) => Eq (Addr (ActorT st msg m)) where
instance (MonadConc m) => Eq (Mailbox m msg) where
  addr1 == addr2 = let tid1 = mailboxThreadId addr1
                       tid2 = mailboxThreadId addr2
                   in tid1 == tid2

-- instance ( Ord (MonadConc.ThreadId m)
--          ) => Ord (Addr (ActorT st msg m)) where
instance (MonadConc m) => Ord (Mailbox m msg) where
  compare addr1 addr2 = let tid1 = mailboxThreadId addr1
                            tid2 = mailboxThreadId addr2
                        in compare tid1 tid2

-- instance ( Show (MonadConc.ThreadId m)
--          ) => Show (Addr (ActorT st msg m)) where
instance (MonadConc m) => Show (Mailbox m msg) where
  show (Mailbox tid _) = "Mailbox(" ++ show tid ++ ")"

--------------------------------------------------------------------------------

-- | Return the state from the internals of the monad.
--
--   This function is the same as 'MonadState.get' from
--   "Control.Monad.State.Class", except it has a more specific type.
get
  :: (MonadActor st msg m)
  => m st
  -- ^ An actor action that returns the current actor state.
get = MonadState.get

-- | Replace the state inside the monad.
--
--   This function is the same as 'MonadState.put' from
--   "Control.Monad.State.Class", except it has a more specific type.
put
  :: (MonadActor st msg m)
  => st
  -- ^ The new state to which the actor state will be set.
  -> m ()
  -- ^ An actor action that sets the actor state to the new state.
put = MonadState.put

-- | Embed a simple state action into the monad.
--
--   This function is the same as 'MonadState.state' from
--   "Control.Monad.State.Class", except it has a more specific type.
state
  :: (MonadActor st msg m)
  => (st -> (ret, st))
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
  :: (MonadActor st msg m)
  => (st -> st)
  -- ^ A function from the state type to itself.
  -> m ()
  -- ^ An 'ActorT' action that replaces the state with the result of
  --   running the given function on the old state.
modify = MonadState.modify

-- | Convert a 'StateT' state transformer value to an 'ActorT' action that
--   modifies the actor state using the state transformer.
embedStateT
  :: (Monad m, MonadActor st msg m)
  => StateT st m ret
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
  :: (MonadActor st msg m)
  => (forall s. STRef s st -> ST s ret)
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
