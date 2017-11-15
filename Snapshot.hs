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

import           Data.Typeable                  (Typeable)

import           Data.Kind                      (Type)

import           Flow                           ((.>), (|>))

--------------------------------------------------------------------------------

type TID m = MonadConc.ThreadId (MonadActor.C m)

--------------------------------------------------------------------------------

newtype SMailbox m msg
  = SMailbox (VCActorT.VCMailbox m (SMessage m msg))

deriving instance (MonadConc m) => Eq   (SMailbox m msg)
deriving instance (MonadConc m) => Ord  (SMailbox m msg)
deriving instance (MonadConc m) => Show (SMailbox m msg)

--------------------------------------------------------------------------------

data GenSMailbox m where
  GenSMailbox :: (Typeable msg) => SMailbox m msg -> GenSMailbox m

--------------------------------------------------------------------------------

data ActorSnapshot m
  = ActorSnapshot
    { _ActorSnapshot_done     :: !Bool
    , _ActorSnapshot_state    :: !Dynamic
    , _ActorSnapshot_messages :: !(Vector (TID m, Dynamic))
    }

data SystemSnapshot m
  = SystemSnapshot
    { _SystemSnapshot_states :: !(Map (TID m) (ActorSnapshot m))
    , _SystemSnapshot_done   :: !(Map (TID m) Bool)
    }

data SnapshotID m
  = SnapshotID
    { _SnapshotID_origin :: !(TID m)
    , _SnapshotID_start  :: !MonadVC.Clock
    }

data SToken m msg
  = SToken
    { _SToken_send :: !(SMessage m msg -> m ())
    , _SToken_id   :: !(SnapshotID m)
    }

data SMessage m msg
  = SMessageNormal
    { _SMessageNormal_tokens  :: !(Set (SToken m msg))
    , _SMessageNormal_from    :: !(GenSMailbox m)
    , _SMessageNormal_message :: !msg
    }
  | SMessageReceived
    { _SMessageReceived_sender   :: !(GenSMailbox m)
    , _SMessageReceived_recip    :: !(GenSMailbox m)
    , _SMessageReceived_contents :: !(Set (SnapshotID m), Dynamic)
    }
  | SMessageState
    { _SMessageState_from  :: !(GenSMailbox m)
    , _SMessageState_state :: !(GenSState m)
    }
  | SMessageDone
    { _SMessageDone_id :: !(SnapshotID m)
    }

--------------------------------------------------------------------------------

data SState m st
  = SState
    { _SState_snapshotsInProgress :: !(Map (SnapshotID m) (SystemSnapshot m))
    , _SState_state               :: !st
    }

--------------------------------------------------------------------------------

data GenSState m where
  GenSState :: (Typeable msg) => SState m msg -> GenSState m

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

instance (MonadConc m) => MonadState st (SActorT st msg m) where
  get = _SState_state <$> SActorT MonadState.get
  put value = SActorT $ do
    SState snapshots state <- MonadState.get
    MonadState.put (SState snapshots value)

instance ( MonadConc m, Typeable st
         ) => MonadActor st msg (SActorT st msg m) where
  type Addr (SActorT st msg m) = SMailbox m msg
  type C    (SActorT st msg m) = m

  spawn initial (SActorT act) = _

  self = SMailbox <$> SActorT MonadActor.self

  send = _

  recv = _

snapshot :: (MonadConc m)
         => SActorT st msg m (SystemSnapshot m)
snapshot = do
  snapshotID <- do
    origin <- MonadTrans.lift MonadConc.myThreadId
    start <- VCActorT.lookupVC origin <$> SActorT MonadVC.getClock
    pure (SnapshotID origin start)
  _

--------------------------------------------------------------------------------
