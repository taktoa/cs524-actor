--------------------------------------------------------------------------------

{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTSyntax                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}

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
  ( -- * The @ActorT@ monad transformer
    ActorT
  , mapActorT

    -- * Actor spawning and addresses
  , Address
  , mapAddress
  , spawn
  , self

    -- * Sending and receiving
  , send
  , receive

    -- * Modifying actor state
  , get
  , put
  , state
  , modify
  , embedStateT
  , embedST
  ) where

--------------------------------------------------------------------------------

-- MTL-style typeclasses

import           Control.Monad.IO.Class         (MonadIO)
import qualified Control.Monad.IO.Class         as MonadIO

import           Control.Monad.Trans.Class      (MonadTrans)
import qualified Control.Monad.Trans.Class      as MonadTrans

import           Control.Monad.State.Class      (MonadState)
import qualified Control.Monad.State.Class      as MonadState

import           Control.Monad.Conc.Class       (MonadConc)
import qualified Control.Monad.Conc.Class       as MonadConc

import           Control.Monad.Catch            (MonadThrow)
import qualified Control.Monad.Catch            as MonadThrow

import           Control.Monad.Catch            (MonadCatch)
import qualified Control.Monad.Catch            as MonadCatch

import           Control.Monad.Catch            (MonadMask)
import qualified Control.Monad.Catch            as MonadMask

--------------------------------------------------------------------------------

-- Other typeclasses

import           Data.Typeable                  (Typeable)

--------------------------------------------------------------------------------

-- Monads and monad transformers

import           Control.Monad.ST               (ST)
import qualified Control.Monad.ST               as ST

import           Control.Monad.Trans.State      (StateT)
import qualified Control.Monad.Trans.State      as StateT

import           Control.Monad.Trans.Reader     (ReaderT)
import qualified Control.Monad.Trans.Reader     as ReaderT

--------------------------------------------------------------------------------

-- Data types

import           Data.STRef                     (STRef)
import qualified Data.STRef                     as STRef

import           Control.Concurrent.Classy.Chan (Chan)
import qualified Control.Concurrent.Classy.Chan as Chan

import           Control.Concurrent.Classy.MVar (MVar)
import qualified Control.Concurrent.Classy.MVar as MVar

--------------------------------------------------------------------------------

-- Other stuff

import qualified Control.Lens                   as Lens

import           Control.Monad                  (forever, (>=>))

import           Flow                           ((.>), (|>))

--------------------------------------------------------------------------------

-- class (Monad m, MonadState s m) => MonadActor (s :: *) (m :: * -> *) where
--   type ActorAddress m :: *
--   type ActorState   m :: *
--   type ActorMessage m :: *
--   send    :: ActorAddress m -> ActorMessage m -> m ()
--   receive :: (ActorMessage m -> m ()) -> m ()

--------------------------------------------------------------------------------

-- | A Kleisli-flavored isomorphism between two types.
--
--   A value of type @'KIso' m a b@ is equivalent in some sense to a value
--   of type @(a -> m b, b -> m a)@.
type KIso m a b = Lens.Iso a (m a) (m b) b

-- | This type is used when a function should take a 'KIso' as an argument.
type AKIso m a b = Lens.AnIso a (m a) (m b) b

-- | Create a 'KIso' from a pair of effectful conversion functions.
kiso :: (a -> m b) -> (b -> m a) -> KIso m a b
kiso = Lens.iso

-- | FIXME: doc
kisoPure :: (Applicative m) => Lens.Iso' a b -> KIso m a b
kisoPure optic = Lens.withIso optic $ \f g -> kiso (f .> pure) (g .> pure)

-- | Flip a 'KIso' around.
--
--   If you think of 'KIso's as pairs, this would be @\(x, y) -> (y, x)@.
kisoFlip :: AKIso m a b -> KIso m b a
kisoFlip = Lens.from

-- | View a value through a 'KIso' forwards (i.e.: access the @a -> m b@).
kisoProview :: AKIso m a b -> a -> m b
kisoProview optic value = Lens.withIso optic $ \f _ -> f value

-- | View a value through a 'KIso' backwards (i.e.: access the @b -> m a@).
kisoConview :: AKIso m a b -> b -> m a
kisoConview optic value = Lens.withIso optic $ \_ g -> g value

--------------------------------------------------------------------------------

-- This datatype contains any values that an actor needs access to during
-- execution.
data Context st message monad
  = Context
    { contextSend :: !(message -> monad ())
    , contextRecv :: !(monad message)
    , contextPut  :: !(st -> monad ())
    , contextGet  :: !(monad st)
    }

--------------------------------------------------------------------------------

-- | The address of an actor, used to send messages
data Address message monad
  = Address
    { addressThreadId :: !(MonadConc.ThreadId monad)
    , addressSend     :: !(message -> monad ())
    }

instance (Eq (MonadConc.ThreadId monad)) => Eq (Address message monad) where
  addr1 == addr2 = let tid1 = addressThreadId addr1
                       tid2 = addressThreadId addr2
                   in tid1 == tid2

instance (Ord (MonadConc.ThreadId monad)) => Ord (Address message monad) where
  compare addr1 addr2 = let tid1 = addressThreadId addr1
                            tid2 = addressThreadId addr2
                        in compare tid1 tid2

instance (Show (MonadConc.ThreadId monad)) => Show (Address message monad) where
  show (Address tid _) = "Address(" ++ show tid ++ ")"

-- | FIXME: doc
mapAddress
  :: (Monad monad)
  => (messageB -> monad messageA)
  -- ^ FIXME: doc
  -> Address messageA monad
  -- ^ FIXME: doc
  -> Address messageB monad
  -- ^ FIXME: doc
mapAddress f (Address tid s) = Address tid (f >=> s)

--------------------------------------------------------------------------------


-- | The actor monad transformer.
--
--   The @st@ type parameter represents the underlying state of the actor.
--
--   The @message@ type parameter represents the type of messages that can be
--   received by this actor.
--
--   The @monad@ type parameter represents the underlying monad for this
--   monad transformer. In most cases this will need to have a 'MonadConc'
--   instance at the very least. In production, this will probably be 'IO'.
newtype ActorT st message monad ret
  = ActorT (ReaderT (Context st message monad) monad ret)

deriving instance (Functor     monad) => Functor     (ActorT st message monad)
deriving instance (Applicative monad) => Applicative (ActorT st message monad)
deriving instance (Monad       monad) => Monad       (ActorT st message monad)
deriving instance (MonadIO     monad) => MonadIO     (ActorT st message monad)
deriving instance (MonadThrow  monad) => MonadThrow  (ActorT st message monad)
deriving instance (MonadCatch  monad) => MonadCatch  (ActorT st message monad)
deriving instance (MonadMask   monad) => MonadMask   (ActorT st message monad)

-- | Uses the 'MonadTrans' instance of the underlying 'ReaderT' transformer.
instance MonadTrans (ActorT st message) where
  lift action = ActorT (MonadTrans.lift action)

-- | Allows easy use of the actor state variable.
instance (MonadConc monad) => MonadState st (ActorT st message monad) where
  get = do
    m <- contextGet <$> ActorT ReaderT.ask
    MonadTrans.lift m
  put value = do
    f <- contextPut <$> ActorT ReaderT.ask
    MonadTrans.lift (f value)

-- | Given the following:
--     1. An effectful isomorphism ('KIso') between two state types
--        @stA@ and @stB@.
--     2. An effectful isomorphism between two message types
--        @messageA@ and @messageB@.
--   this will convert an @'ActorT' stA messageA monad ret@
--   to an @'ActorT' stB messageB monad ret@.
--
--   For a concrete example, suppose that
--   @new = 'mapActorT' ('kiso' stF stG) ('kiso' messageF messageG) old@.
--
--   Then the following will be true:
--     * Whenever @old@ uses 'send', @messageF@ is used in @new@ to convert
--       the old message type to the new message type.
--     * Whenever @old@ uses 'receive', @messageG@ is used in @new@ to convert
--       the new message type back to the old message type.
--     * Whenever @old@ uses 'put', @messageF@ is used in @new@ to convert
--       the old message type to the new message type.
--     * Whenever @old@ uses 'get', @messageG@ is used in @new@ to convert
--       the new message type back to the old message type.
mapActorT
  :: (Monad monad)
  => KIso monad stA stB
  -- ^ An effectful isomorphism between @stA@ and @stB@.
  -> KIso monad messageA messageB
  -- ^ An effectful isomorphism between @messageA@ and @messageB@.
  -> ActorT stA messageA monad ret
  -- ^ An 'ActorT' action with @stA@ as its state type, @messageA@ as its
  --   message type, and @ret@ as its return value.
  -> ActorT stB messageB monad ret
  -- ^ An 'ActorT' action with @stB@ as its state type, @messageB@ as its
  --   message type, and @ret@ as its return value.
mapActorT stIso messageIso (ActorT m) = ActorT $ do
  let mapContext (Context s r p g) = Context
                                     (kisoProview messageIso >=> s)
                                     (r >>= kisoConview messageIso)
                                     (kisoProview stIso >=> p)
                                     (g >>= kisoConview stIso)
  ReaderT.withReaderT mapContext m

--------------------------------------------------------------------------------

-- | Spawns a new actor with the given initial state and returns its 'Address'.
spawn
  :: (MonadConc monad)
  => st
  -- ^ The initial actor state.
  -> ActorT st message monad ()
  -- ^ The actor to run.
  -> monad (Address message monad)
  -- ^ A concurrent action that spawns the actor and returns its 'Address'.
spawn initial (ActorT act) = do
  chan     <- Chan.newChan
  stateVar <- MVar.newMVar initial
  let ctx = Context { contextSend = Chan.writeChan chan
                    , contextRecv = Chan.readChan  chan
                    , contextPut  = MVar.putMVar   stateVar
                    , contextGet  = MVar.readMVar  stateVar
                    }
  tid <- MonadConc.fork (ReaderT.runReaderT act ctx)
  pure (Address tid (contextSend ctx))

--------------------------------------------------------------------------------

-- | Used to obtain the address of an actor while inside the actor.
self
  :: (MonadConc monad)
  => ActorT st message monad (Address message monad)
  -- ^ An 'ActorT' action that returns the address of the current actor.
self = do
  s <- ActorT (ReaderT.asks contextSend)
  tid <- MonadTrans.lift MonadConc.myThreadId
  pure (Address tid s)

--------------------------------------------------------------------------------

-- | Try to handle an incoming message using a function.
--
--   This will block until a new message comes in, at which point the behavior
--   of the actor will become the result of running the given function on the
--   received message.
receive
  :: (MonadConc monad)
  => (message -> ActorT st message monad ())
  -- ^ A message handler function.
  -> ActorT st message monad ()
  -- ^ An 'ActorT' action that blocks until there is at least one message
  --   in the actor mailbox, and then handles one of the mailbox messages
  --   using the given handler function.
receive handler = do
  r <- ActorT (ReaderT.asks contextRecv)
  MonadTrans.lift r >>= handler

--------------------------------------------------------------------------------

-- | Sends the given message to the actor at the given address.
send
  :: (MonadConc monad)
  => Address message monad
  -- ^ The address of the actor to which the message will be sent.
  -> message
  -- ^ The message to send.
  -> ActorT st message monad ()
  -- ^ An 'ActorT' action that sends the given message to the actor described
  --   by the given address.
send addr msg = MonadTrans.lift $ addressSend addr msg

--------------------------------------------------------------------------------

-- | Return the state from the internals of the monad.
--
--   This function is the same as 'MonadState.get' from
--   "Control.Monad.State.Class", except it has a more specific type.
get
  :: (MonadConc monad)
  => ActorT st message monad st
  -- ^ An 'ActorT' action that returns the current actor state.
get = MonadState.get

-- | Replace the state inside the monad.
--
--   This function is the same as 'MonadState.put' from
--   "Control.Monad.State.Class", except it has a more specific type.
put
  :: (MonadConc monad)
  => st
  -- ^ The new state to which the actor state will be set.
  -> ActorT st message monad ()
  -- ^ An 'ActorT' action that sets the actor state to the new state.
put = MonadState.put

-- | Embed a simple state action into the monad.
--
--   This function is the same as 'MonadState.state' from
--   "Control.Monad.State.Class", except it has a more specific type.
state
  :: (MonadConc monad)
  => (st -> (ret, st))
  -- ^ A function that, given the current state, returns an arbitrary value
  --   along with a new state.
  -> ActorT st message monad ret
  -- ^ An 'ActorT' action that runs the function on the current state,
  --   sets the actor state to the new state, and returns the arbitrary
  --   value.
state = MonadState.state

-- | Maps an old state to a new state inside a state monad.
--   The old state is thrown away.
--
--   This function is the same as 'MonadState.modify' from
--   "Control.Monad.State.Class", except it has a more specific type.
modify
  :: (MonadConc monad)
  => (st -> st)
  -- ^ A function from the state type to itself.
  -> ActorT st message monad ()
  -- ^ An 'ActorT' action that replaces the state with the result of
  --   running the given function on the old state.
modify = MonadState.modify

-- | Convert a 'StateT' state transformer value to an 'ActorT' action that
--   modifies the actor state using the state transformer.
embedStateT
  :: (MonadConc monad)
  => StateT st monad ret
  -- ^ A monadic state transformer.
  -> ActorT st message monad ret
  -- ^ An 'ActorT' action that modifies the actor state using the
  --   given state transformer.
embedStateT action = do
  s <- MonadState.get
  (ret, s') <- MonadTrans.lift (StateT.runStateT action s)
  MonadState.put s'
  pure ret

-- | Given a function @f@ from an @'STRef' s st@ to an @'ST' s ret@ action,
--   produce an @'ActorT' st message m ret@ action that does the following:
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
  :: (MonadConc monad)
  => (forall s. STRef s st -> ST s ret)
  -- ^ An 'ST' action that can mutate the given 'STRef' and return an
  --   arbitrary value.
  -> ActorT st message monad ret
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
