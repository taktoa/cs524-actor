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

import           Actor                          (ActorT, MonadActor)
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

import           Data.Maybe
import           Data.Monoid

import           Flow                           ((.>), (|>))

--------------------------------------------------------------------------------

class ( MonadActor st msg m
      ) => MonadVC st msg m | m -> st, m -> msg where
  getClock :: m (VC (MonadConc.ThreadId (MonadActor.C m)))

--------------------------------------------------------------------------------

type Clock = Int

--------------------------------------------------------------------------------

-- | FIXME: doc
newtype VC tid
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

type TID m = MonadConc.ThreadId m

type MCVC m = VC (MonadConc.ThreadId m)

data VCState m st
  = VCState
    { _VCState_clock :: !(MCVC m)
    , _VCState_state :: !st
    }

data VCMessageSyncType
  = VCMessageSyncSYN
  | VCMessageSyncACK

data VCMessage m msg
  = VCMessageNormal
    { _VCMessageNormal_clock   :: !(MCVC m)
    , _VCMessageNormal_message :: !msg
    }
  | VCMessageSync
    { _VCMessageSync_clock  :: !(MCVC m)
    , _VCMessageSync_sender :: !(VCMailbox m msg)
    , _VCMessageSync_type   :: !VCMessageSyncType
    }

--------------------------------------------------------------------------------

newtype VCActorT st msg m ret
  = VCActorT (ActorT (VCState m st) (VCMessage m msg) m ret)

deriving instance (Functor     m) => Functor     (VCActorT st msg m)
deriving instance (Applicative m) => Applicative (VCActorT st msg m)
deriving instance (Monad       m) => Monad       (VCActorT st msg m)
deriving instance (MonadThrow  m) => MonadThrow  (VCActorT st msg m)
deriving instance (MonadCatch  m) => MonadCatch  (VCActorT st msg m)
deriving instance (MonadMask   m) => MonadMask   (VCActorT st msg m)

instance MonadTrans (VCActorT st msg) where
  lift = MonadTrans.lift .> VCActorT

instance (MonadConc m) => MonadState st (VCActorT st msg m) where
  get = _VCState_state <$> VCActorT MonadState.get
  put value = VCActorT $ do
    clock <- _VCState_clock <$> MonadState.get
    MonadState.put (VCState clock value)

instance (MonadConc m) => MonadActor st msg (VCActorT st msg m) where
  type Addr (VCActorT st msg m) = VCMailbox m msg
  type C    (VCActorT st msg m) = m

  spawn initial (VCActorT act) = do
    addr <- MonadActor.spawn (VCState emptyVC initial) act
    pure (VCMailbox addr)

  self = VCMailbox <$> VCActorT MonadActor.self

  send mb msg = internalSend mb (\clock -> VCMessageNormal clock msg)

  recv :: (msg -> VCActorT st msg m a) -> VCActorT st msg m ()
  recv cb = internalRecv cb handler
    where
      handler :: VCMessage m msg -> (MCVC m, VCActorT st msg m (Maybe msg))
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
        -> VCActorT st msg m (Maybe msg)
      normalHandler msg = pure (Just msg)

      syncHandler
        :: (VCMailbox m msg, VCMessageSyncType)
        -> VCActorT st msg m (Maybe msg)
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

instance (MonadConc m) => MonadVC st msg (VCActorT st msg m) where
  getClock = _VCState_clock <$> VCActorT MonadState.get

internalFromVCActorT :: VCActorT st msg m ret
                     -> ActorT (VCState m st) (VCMessage m msg) m ret
internalFromVCActorT (VCActorT m) = m

internalSend :: (MonadConc m)
             => VCMailbox m msg
             -> (MCVC m -> VCMessage m msg)
             -> VCActorT st msg m ()
internalSend (VCMailbox addr) msgF = VCActorT $ do
  (VCState clock state) <- MonadState.get
  me <- MonadTrans.lift MonadConc.myThreadId
  let clock' = incrVC me clock
  MonadState.put (VCState clock' state)
  MonadActor.send addr (msgF clock')

internalRecv :: (MonadConc m)
             => (msg -> VCActorT st msg m a)
             -> (VCMessage m msg -> (MCVC m, VCActorT st msg m (Maybe msg)))
             -> VCActorT st msg m ()
internalRecv cb msgF = VCActorT $ MonadActor.recv $ \msg -> do
  internalIncrClock
  let (clock, msgAction) = msgF msg
  internalUpdateClock clock
  internalFromVCActorT (msgAction >>= maybe (pure ()) (cb .> void))

internalIncrClock :: (MonadConc m)
                  => ActorT (VCState m st) (VCMessage m msg) m ()
internalIncrClock = do
  me <- MonadTrans.lift MonadConc.myThreadId
  internalModifyClock (incrVC me)

internalUpdateClock :: (MonadConc m)
                    => VC (MonadConc.ThreadId m)
                    -> ActorT (VCState m st) (VCMessage m msg) m ()
internalUpdateClock added = do
  let compose :: [a -> a] -> (a -> a)
      compose = map Endo .> mconcat .> appEndo
  internalModifyClock (compose (updateVC <$> Map.toList (fromVC added)))

internalModifyClock :: (MonadConc m)
                    => (VC (MonadConc.ThreadId m) -> VC (MonadConc.ThreadId m))
                    -> ActorT (VCState m st) (VCMessage m msg) m ()
internalModifyClock f = do
  (VCState clock state) <- MonadState.get
  MonadState.put (VCState (f clock) state)

--------------------------------------------------------------------------------

newtype VCMailbox m msg
  = VCMailbox (ActorT.Mailbox (VCMessage m msg) m)

deriving instance (MonadConc m) => Eq   (VCMailbox m msg)
deriving instance (MonadConc m) => Ord  (VCMailbox m msg)
deriving instance (MonadConc m) => Show (VCMailbox m msg)

--------------------------------------------------------------------------------
