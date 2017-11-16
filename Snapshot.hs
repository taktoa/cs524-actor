--------------------------------------------------------------------------------

{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeInType                 #-}

--------------------------------------------------------------------------------

module Snapshot
  ( module Snapshot
  ) where


--------------------------------------------------------------------------------

import           Actor                          (TID)

import           Actor                          (ActorT)
import qualified Actor                          as ActorT

import           Actor                          (MonadActor)
import qualified Actor                          as MonadActor

import           VectorClock                    (MonadVC)
import qualified VectorClock                    as MonadVC

import           VectorClock                    (VCActorT)
import qualified VectorClock                    as VCActorT

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

import           Control.Monad                  (forever)
import           Control.Monad.Extra            (whileM)

import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map

import           Data.Set                       (Set)
import qualified Data.Set                       as Set

import qualified Control.Lens                   as Lens

import           Data.Maybe
import           Data.Monoid

import           Data.Dynamic                   (Dynamic)
import qualified Data.Dynamic                   as Dynamic

import           Data.Vector                    (Vector)
import qualified Data.Vector                    as Vector

import           Data.Proxy                     (Proxy (Proxy))

import           Data.Typeable                  (Typeable)

import           Data.Kind                      (Type)

import           Data.Functor.Identity          (runIdentity)

import           Flow                           ((.>), (|>))

--------------------------------------------------------------------------------

newtype SMailbox u msg
  = SMailbox (VCActorT.VCMailbox u (SMessage u msg))

deriving instance (MonadConc u) => Eq   (SMailbox u msg)
deriving instance (MonadConc u) => Ord  (SMailbox u msg)
deriving instance (MonadConc u) => Show (SMailbox u msg)

--------------------------------------------------------------------------------

data GenSMailbox u where
  GenSMailbox :: (Typeable msg) => SMailbox u msg -> GenSMailbox u

--------------------------------------------------------------------------------

data ActorSnapshot u
  = ActorSnapshot
    { _ActorSnapshot_state    :: !(GenSState u)
    , _ActorSnapshot_messages :: !(Vector (MonadConc.ThreadId u, Dynamic))
    }

--------------------------------------------------------------------------------

data SystemSnapshot u
  = SystemSnapshot
    { _SystemSnapshot_states :: !(Map (MonadConc.ThreadId u) (ActorSnapshot u))
    , _SystemSnapshot_done   :: !(Map (MonadConc.ThreadId u) Bool)
    }

emptySystemSnapshot :: SystemSnapshot u
emptySystemSnapshot = SystemSnapshot Map.empty Map.empty

--------------------------------------------------------------------------------

data SnapshotID u
  = SnapshotID
    { _SnapshotID_origin :: !(MonadConc.ThreadId u)
    , _SnapshotID_start  :: !MonadVC.Clock
    }

deriving instance (MonadConc u) => Eq  (SnapshotID u)
deriving instance (MonadConc u) => Ord (SnapshotID u)

--------------------------------------------------------------------------------

data SToken u msg
  = SToken
    { _SToken_send :: !(SMessage u msg -> u ())
    , _SToken_id   :: !(SnapshotID u)
    }

--------------------------------------------------------------------------------

data SMessage u msg
  = SMessageNormal
    { _SMessageNormal_tokens  :: !(Set (SToken u msg))
    , _SMessageNormal_from    :: !(GenSMailbox u)
    , _SMessageNormal_message :: !msg
    }
  | SMessageReceived
    { _SMessageReceived_sender   :: !(GenSMailbox u)
    , _SMessageReceived_recip    :: !(GenSMailbox u)
    , _SMessageReceived_contents :: !(Set (SnapshotID u), Dynamic)
    }
  | SMessageState
    { _SMessageState_from  :: !(GenSMailbox u)
    , _SMessageState_state :: !(GenSState u)
    }
  | SMessageDone
    { _SMessageDone_id :: !(SnapshotID u)
    }

--------------------------------------------------------------------------------

data SState u st
  = SState
    { _SState_snapshots :: !(Map (SnapshotID u) (SystemSnapshot u))
    , _SState_state     :: !st
    }

--------------------------------------------------------------------------------

data GenSState u where
  GenSState :: (Typeable st) => SState u st -> GenSState u

--------------------------------------------------------------------------------

newtype SActorT st msg m ret
  = SActorT (VCActorT (SState m st) (SMessage m msg) m ret)

deriving instance (Functor     m) => Functor     (SActorT st msg m)
deriving instance (Applicative m) => Applicative (SActorT st msg m)
deriving instance (Monad       m) => Monad       (SActorT st msg m)
deriving instance (MonadThrow  m) => MonadThrow  (SActorT st msg m)
deriving instance (MonadCatch  m) => MonadCatch  (SActorT st msg m)
deriving instance (MonadMask   m) => MonadMask   (SActorT st msg m)

instance MonadTrans (SActorT st msg) where
  lift = MonadTrans.lift .> SActorT

instance (MonadConc m, Typeable st) => MonadVC st msg (SActorT st msg m) where
  getClock = SActorT MonadVC.getClock

instance (MonadConc m) => MonadState st (SActorT st msg m) where
  get = _SState_state <$> SActorT MonadState.get
  put value = SActorT $ do
    SState snapshots state <- MonadState.get
    MonadState.put (SState snapshots value)

instance ( MonadConc u, Typeable st
         ) => MonadActor st msg (SActorT st msg u) where
  type Addr       (SActorT st msg u) = SMailbox u msg
  type Underlying (SActorT st msg u) = u

  addrToTID proxy = (\(SMailbox mb) -> mb)
                    .> MonadActor.addrToTID (Proxy @(VCActorT _ _ _))

  spawn initial (SActorT act) = _

  self = SMailbox <$> SActorT MonadActor.self

  send = _

  recv = _

addMapDefault :: (Ord k) => (k, v) -> Map k v -> Map k v
addMapDefault (k, v) = Map.alter (fromMaybe v .> Just) k

upsertSnapshot :: forall u st msg.
                  (MonadConc u, Typeable st, Typeable msg)
               => SnapshotID u
               -> (SystemSnapshot u -> SystemSnapshot u)
               -> SActorT st msg u ()
upsertSnapshot sid f = SActorT $ MonadState.modify $ \old -> runIdentity $ do
  let (SState snapshots state) = old
  let snapshots' = snapshots
                   |> addMapDefault (sid, emptySystemSnapshot)
                   |> Map.adjust f sid
  pure (SState snapshots' state)

snapshotSetState :: forall u st msg.
                    (MonadConc u, Typeable st, Typeable msg)
                 => SnapshotID u
                 -> MonadConc.ThreadId u
                 -> GenSState u
                 -> SActorT st msg u ()
snapshotSetState sid tid state = do
  upsertSnapshot sid $ \(SystemSnapshot states done) -> runIdentity $ do
    let combine :: ActorSnapshot u -> ActorSnapshot u -> ActorSnapshot u
        combine (ActorSnapshot sA mA) (ActorSnapshot sB mB)
          = ActorSnapshot sA (mB <> mA)
    let asnap   = ActorSnapshot state Vector.empty
    let states' = Map.insertWith combine tid asnap states
    pure (SystemSnapshot states' done)

snapshotAddMessage :: forall u st msg.
                      (MonadConc u, Typeable st, Typeable msg)
                   => SnapshotID u
                   -> (MonadConc.ThreadId u, MonadConc.ThreadId u)
                   -> msg
                   -> SActorT st msg u ()
snapshotAddMessage sid (fromTID, toTID) msg = do
  upsertSnapshot sid $ \(SystemSnapshot states done) -> runIdentity $ do
    let f :: ActorSnapshot u -> ActorSnapshot u
        f (ActorSnapshot s ms)
          = ActorSnapshot s (Vector.snoc ms (fromTID, Dynamic.toDyn msg))
    let states' = Map.adjust f toTID states
    pure (SystemSnapshot states' done)

snapshot :: forall u st msg.
            (MonadConc u, Typeable st, Typeable msg)
         => SActorT st msg u (SystemSnapshot u)
snapshot = do
  snapshotID :: SnapshotID u <- do
    origin <- MonadActor.selfTID
    start <- VCActorT.lookupVC origin <$> MonadVC.getClock
    pure (SnapshotID origin start)
  () <- do
    me <- MonadActor.selfTID
    saved <- GenSState <$> SActorT MonadState.get
    snapshotSetState snapshotID me saved
  -- upsertSnapshot snapshotID $ \snapshot -> runIdentity $ _
  _

--------------------------------------------------------------------------------
