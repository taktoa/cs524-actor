--------------------------------------------------------------------------------

{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}

--------------------------------------------------------------------------------

module VectorClock
  ( module VectorClock
  ) where

--------------------------------------------------------------------------------

import           Actor                          (ActorT, MonadActor, TID)
import qualified Actor                          as ActorT
import qualified Actor                          as MonadActor

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

import           Control.Concurrent.Classy.MVar (MVar)
import qualified Control.Concurrent.Classy.MVar as MVar

import           Control.Monad                  (forever, void)

import           Data.Map                       (Map)
import qualified Data.Map                       as Map

import qualified Control.Lens                   as Lens

import           Data.Proxy                     (Proxy (Proxy))

import           Data.Maybe
import           Data.Monoid

import           Flow                           ((.>), (|>))

--------------------------------------------------------------------------------

class (MonadActor m) => MonadVC m where
  getClock :: m (VC (MonadActor.TID (MonadActor.U m)))

--------------------------------------------------------------------------------

type Clock = Int

--------------------------------------------------------------------------------

-- | FIXME: doc
newtype VC (tid :: *)
  = VC (Map tid Clock)

-- | FIXME: doc
emptyVC
  :: VC tid
  -- ^ FIXME: doc
emptyVC = VC Map.empty

-- | FIXME: doc
lookupVC
  :: (Ord tid)
  => tid
  -- ^ FIXME: doc
  -> VC tid
  -- ^ FIXME: doc
  -> Clock
  -- ^ FIXME: doc
lookupVC tid (VC m) = fromMaybe 0 (Map.lookup tid m)

-- | FIXME: doc
incrVC
  :: (Ord tid)
  => tid
  -- ^ FIXME: doc
  -> VC tid
  -- ^ FIXME: doc
  -> VC tid
  -- ^ FIXME: doc
incrVC tid (VC m) = let old = fromMaybe 0 (Map.lookup tid m)
                    in VC (Map.insert tid (old + 1) m)

-- | FIXME: doc
updateVC
  :: (Ord tid)
  => (tid, Clock)
  -- ^ FIXME: doc
  -> VC tid
  -- ^ FIXME: doc
  -> VC tid
  -- ^ FIXME: doc
updateVC (tid, clock) (VC m) = VC (Map.insertWith max tid clock m)

-- | FIXME: doc
fromVC
  :: VC tid
  -- ^ FIXME: doc
  -> Map tid Clock
  -- ^ FIXME: doc
fromVC (VC m) = m

--------------------------------------------------------------------------------

type MCVC (u :: * -> *) = ((VC (TID u)) :: *)

data VCState (u :: * -> *) (st :: *)
  = VCState
    { _VCState_clock :: !(MCVC u)
    , _VCState_state :: !st
    }

data VCMessageSyncType
  = VCMessageSyncSYN
  | VCMessageSyncACK

data VCMessage (u :: * -> *) (msg :: *)
  = VCMessageNormal
    { _VCMessageNormal_clock   :: !(MCVC u)
    , _VCMessageNormal_message :: !msg
    }
  | VCMessageSync
    { _VCMessageSync_clock  :: !(MCVC u)
    , _VCMessageSync_sender :: !(VCMailbox u msg)
    , _VCMessageSync_type   :: !VCMessageSyncType
    }

--------------------------------------------------------------------------------

newtype VCActorT (st :: *) (msg :: *) (u :: * -> *) (ret :: *)
  = VCActorT (ActorT (VCState u st) (VCMessage u msg) u ret)

deriving instance (Functor     u) => Functor     (VCActorT st msg u)
deriving instance (Applicative u) => Applicative (VCActorT st msg u)
deriving instance (Monad       u) => Monad       (VCActorT st msg u)
deriving instance (MonadThrow  u) => MonadThrow  (VCActorT st msg u)
deriving instance (MonadCatch  u) => MonadCatch  (VCActorT st msg u)
deriving instance (MonadMask   u) => MonadMask   (VCActorT st msg u)

instance MonadTrans (VCActorT st msg) where
  lift = MonadTrans.lift .> VCActorT

instance (MonadConc u) => MonadState st (VCActorT st msg u) where
  get = _VCState_state <$> VCActorT MonadState.get
  put value = VCActorT $ do
    clock <- _VCState_clock <$> MonadState.get
    MonadState.put (VCState clock value)

instance (MonadConc u) => MonadActor (VCActorT st msg u) where
  type A (VCActorT st msg u) = VCMailbox u
  type S (VCActorT st msg u) = st
  type M (VCActorT st msg u) = msg
  type U (VCActorT st msg u) = u

  -- addrToTID :: proxy m -> A m a -> TID (U m)
  addrToTID :: proxy (VCActorT st msg u) -> VCMailbox u a -> TID u
  addrToTID _ (VCMailbox mb)
    = MonadActor.addrToTID
      (Proxy @(ActorT (VCState u st) (VCMessage u msg) u)) mb

  -- spawn :: S m -> m () -> U m (A m msg)
  spawn :: st -> VCActorT st msg u () -> u (VCMailbox u msg)
  spawn initial (VCActorT act) = do
    addr <- MonadActor.spawn (VCState emptyVC initial) act
    pure (VCMailbox addr)

  -- self :: m (A m (M m))
  self :: VCActorT st msg u (VCMailbox u msg)
  self = VCMailbox <$> VCActorT MonadActor.self

  -- send :: forall message. A m message -> message -> m ()
  send :: forall message. VCMailbox u message -> message -> VCActorT st msg u ()
  send mb msg = internalSend mb (\clock -> VCMessageNormal clock msg)

  -- recv :: (M m -> m a) -> m ()
  recv :: (msg -> VCActorT st msg u a) -> VCActorT st msg u ()
  recv cb = internalRecv cb handler
    where
      handler :: VCMessage u msg -> (MCVC u, VCActorT st msg u (Maybe msg))
      handler (VCMessageNormal {..}) = ( _VCMessageNormal_clock
                                       , ( _VCMessageNormal_message
                                         ) |> normalHandler
                                       )
      handler (VCMessageSync   {..}) = ( _VCMessageSync_clock
                                       , ( _VCMessageSync_sender
                                         , _VCMessageSync_type
                                         ) |> syncHandler
                                       )

      normalHandler
        :: msg
        -> VCActorT st msg u (Maybe msg)
      normalHandler msg = pure (Just msg)

      syncHandler
        :: (VCMailbox u msg, VCMessageSyncType)
        -> VCActorT st msg u (Maybe msg)
      syncHandler (sender, ty) = do
        case ty of
          VCMessageSyncACK -> pure ()
          VCMessageSyncSYN -> do me <- MonadActor.self
                                 clock <- getClock
                                 let VCMailbox mb = sender
                                 VCMessageSync clock me VCMessageSyncACK
                                   |> MonadActor.send mb
                                   |> VCActorT
        pure Nothing

instance (MonadConc u) => MonadVC (VCActorT st msg u) where
  getClock = _VCState_clock <$> VCActorT MonadState.get

internalFromVCActorT :: VCActorT st msg u ret
                     -> ActorT (VCState u st) (VCMessage u msg) u ret
internalFromVCActorT (VCActorT m) = m

internalSend :: (MonadConc u)
             => VCMailbox u message
             -> (MCVC u -> VCMessage u message)
             -> VCActorT st msg u ()
internalSend (VCMailbox addr) msgF = VCActorT $ do
  (VCState clock state) <- MonadState.get
  me <- MonadTrans.lift MonadConc.myThreadId
  let clock' = incrVC me clock
  MonadState.put (VCState clock' state)
  MonadActor.send addr (msgF clock')

internalRecv :: (MonadConc u)
             => (msg -> VCActorT st msg u a)
             -> (VCMessage u msg -> (MCVC u, VCActorT st msg u (Maybe msg)))
             -> VCActorT st msg u ()
internalRecv cb msgF = VCActorT $ MonadActor.recv $ \msg -> do
  internalIncrClock
  let (clock, msgAction) = msgF msg
  internalUpdateClock clock
  internalFromVCActorT (msgAction >>= maybe (pure ()) (cb .> void))

internalIncrClock :: (MonadConc u)
                  => ActorT (VCState u st) (VCMessage u msg) u ()
internalIncrClock = do
  me <- MonadTrans.lift MonadConc.myThreadId
  internalModifyClock (incrVC me)

internalUpdateClock :: (MonadConc u)
                    => VC (MonadActor.TID u)
                    -> ActorT (VCState u st) (VCMessage u msg) u ()
internalUpdateClock added = do
  let compose :: [a -> a] -> (a -> a)
      compose = map Endo .> mconcat .> appEndo
  internalModifyClock (compose (updateVC <$> Map.toList (fromVC added)))

internalModifyClock :: (MonadConc u)
                    => (MCVC u -> MCVC u)
                    -> ActorT (VCState u st) (VCMessage u msg) u ()
internalModifyClock f = do
  (VCState clock state) <- MonadState.get
  MonadState.put (VCState (f clock) state)

--------------------------------------------------------------------------------

newtype VCMailbox (u :: * -> *) (msg :: *)
  = VCMailbox (ActorT.Mailbox u (VCMessage u msg))

--------------------------------------------------------------------------------
