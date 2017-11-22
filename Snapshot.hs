--------------------------------------------------------------------------------

{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeInType                 #-}

--------------------------------------------------------------------------------

module Snapshot
  ( module Snapshot
  ) where


--------------------------------------------------------------------------------

import           Actor                            (TID)

import           Actor                            (ActorT)
import qualified Actor                            as ActorT

import           Actor                            (MonadActor)
import qualified Actor                            as MonadActor

import           VectorClock                      (MonadVC)
import qualified VectorClock                      as MonadVC

import           VectorClock                      (VCActorT)
import qualified VectorClock                      as VCActorT

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

import           Control.Monad.Trans.State.Strict (StateT)
import qualified Control.Monad.Trans.State.Strict as StateT

import           Control.Concurrent.Classy.MVar   (MVar)
import qualified Control.Concurrent.Classy.MVar   as MVar

import           Control.Monad
import           Control.Monad.Extra              (whileM)

import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict                  as Map

import           Data.Set                         (Set)
import qualified Data.Set                         as Set

import qualified Control.Lens                     as Lens

import           Data.Maybe
import           Data.Monoid

import           Data.Dynamic                     (Dynamic)
import qualified Data.Dynamic                     as Dynamic

import           Data.Vector                      (Vector)
import qualified Data.Vector                      as Vector

import           Data.Proxy                       (Proxy (Proxy))

import           Data.Void                        (Void, absurd)

import           Data.Typeable                    (Typeable)

import           Data.Kind                        (Type)

import           Data.Functor.Identity            (runIdentity)

import           Flow                             ((.>), (|>))

--------------------------------------------------------------------------------

newtype SMailbox u msg
  = SMailbox (VCActorT.VCMailbox u (SMessage u msg))
  deriving ()

--------------------------------------------------------------------------------

data GenSMailbox u where
  GenSMailbox :: (Typeable msg) => SMailbox u msg -> GenSMailbox u

useGenSMailbox :: (forall msg. (Typeable msg) => SMailbox u msg -> a)
               -> GenSMailbox u -> a
useGenSMailbox f (GenSMailbox mb) = f mb

--------------------------------------------------------------------------------

type GenSMessage u = (STokens u, Dynamic)

--------------------------------------------------------------------------------

data ActorSnapshot u
  = ActorSnapshot
    { _ActorSnapshot_state    :: !(GenSState u)
    , _ActorSnapshot_messages :: !(Vector (MonadActor.TID u, GenSMessage u))
    }

stateInActorSnapshot :: Lens.Lens' (ActorSnapshot u) (GenSState u)
stateInActorSnapshot = Lens.lens _ActorSnapshot_state
                       $ \(ActorSnapshot {..}) x ->
                           ActorSnapshot { _ActorSnapshot_state = x, .. }

messagesInActorSnapshot :: Lens.Lens'
                           (ActorSnapshot u)
                           (Vector (MonadActor.TID u, GenSMessage u))
messagesInActorSnapshot = Lens.lens _ActorSnapshot_messages
                          $ \(ActorSnapshot {..}) x ->
                              ActorSnapshot { _ActorSnapshot_messages = x, .. }

--------------------------------------------------------------------------------

data SystemSnapshot u
  = SystemSnapshot
    { _SystemSnapshot_states :: !(Map (MonadActor.TID u) (ActorSnapshot u))
    , _SystemSnapshot_done   :: !(Map (MonadActor.TID u) Bool)
    }

emptySystemSnapshot :: SystemSnapshot u
emptySystemSnapshot = SystemSnapshot Map.empty Map.empty

statesInSystemSnapshot :: Lens.Lens'
                          (SystemSnapshot u)
                          (Map (MonadActor.TID u) (ActorSnapshot u))
statesInSystemSnapshot = Lens.lens _SystemSnapshot_states
                         $ \(SystemSnapshot {..}) x ->
                             SystemSnapshot { _SystemSnapshot_states = x, .. }

doneInSystemSnapshot :: Lens.Lens'
                        (SystemSnapshot u)
                        (Map (MonadActor.TID u) Bool)
doneInSystemSnapshot = Lens.lens _SystemSnapshot_done
                       $ \(SystemSnapshot {..}) x ->
                           SystemSnapshot { _SystemSnapshot_done = x, .. }

--------------------------------------------------------------------------------

data SnapshotID u
  = SnapshotID
    { _SnapshotID_origin :: !(MonadActor.TID u)
    , _SnapshotID_start  :: !MonadVC.Clock
    }

deriving instance (MonadConc u) => Eq  (SnapshotID u)
deriving instance (MonadConc u) => Ord (SnapshotID u)

originInSnapshotID :: Lens.Lens' (SnapshotID u) (MonadActor.TID u)
originInSnapshotID
  = Lens.lens _SnapshotID_origin
    $ \(SnapshotID {..}) x -> SnapshotID { _SnapshotID_origin = x, .. }

startInSnapshotID :: Lens.Lens' (SnapshotID u) MonadVC.Clock
startInSnapshotID
  = Lens.lens _SnapshotID_start
    $ \(SnapshotID {..}) x -> SnapshotID { _SnapshotID_start = x, .. }

--------------------------------------------------------------------------------

data STokens u
  = STokens
    { _STokens_map :: !(Map (SnapshotID u) (GenSMailbox u))
    }

_STokens :: Lens.Iso' (STokens u) (Map (SnapshotID u) (GenSMailbox u))
_STokens = Lens.iso _STokens_map STokens

--------------------------------------------------------------------------------

data SMessage u msg
  = SMessageNormal
    { _SMessageNormal_tokens  :: !(STokens u)
    , _SMessageNormal_origin  :: !(GenSMailbox u)
    , _SMessageNormal_message :: !msg
    }
  | SMessageRecv
    { _SMessageRecv_sid       :: !(SnapshotID u)
    , _SMessageRecv_sendActor :: !(GenSMailbox u)
    , _SMessageRecv_recvActor :: !(GenSMailbox u)
    , _SMessageRecv_contents  :: !(GenSMessage u)
    }
  | SMessageState
    { _SMessageState_sid   :: !(SnapshotID u)
    , _SMessageState_actor :: !(GenSMailbox u)
    , _SMessageState_state :: !(GenSState u)
    }
  | SMessageStart
    { _SMessageStart_sid      :: !(SnapshotID u)
    , _SMessageStart_observer :: !(GenSMailbox u)
    }
  | SMessageDone
    { _SMessageDone_sid   :: !(SnapshotID u)
    , _SMessageDone_actor :: !(GenSMailbox u)
    }
  deriving (Functor)

--------------------------------------------------------------------------------

gsmSend :: (MonadConc u)
        => GenSMailbox u
        -> SMessage u Void
        -> SActorT st msg u ()
gsmSend (GenSMailbox (SMailbox mb)) = \case
  (SMessageRecv   {..}) -> SActorT (MonadActor.send mb (SMessageRecv  {..}))
  (SMessageState  {..}) -> SActorT (MonadActor.send mb (SMessageState {..}))
  (SMessageStart  {..}) -> SActorT (MonadActor.send mb (SMessageStart {..}))
  (SMessageDone   {..}) -> SActorT (MonadActor.send mb (SMessageDone  {..}))
  (SMessageNormal {..}) -> absurd _SMessageNormal_message

gsmTID :: forall u. (MonadConc u) => GenSMailbox u -> MonadActor.TID u
gsmTID (GenSMailbox (SMailbox mb))
  = MonadActor.addrToTID
    (Proxy @(VCActorT (SState u _) (SMessage u _) u)) mb

--------------------------------------------------------------------------------

data SState u st
  = SState
    { _SState_snapshots :: !(Map (SnapshotID u) (SystemSnapshot u))
    , _SState_tokens    :: !(STokens u)
    , _SState_state     :: !st
    }

initialSState :: (MonadConc u) => st -> SState u st
initialSState initial = SState mempty (STokens mempty) initial

snapshotsInSState :: Lens.Lens'
                     (SState u st)
                     (Map (SnapshotID u) (SystemSnapshot u))
snapshotsInSState = Lens.lens _SState_snapshots
                    $ \(SState {..}) x -> SState { _SState_snapshots = x, .. }

tokensInSState :: Lens.Lens' (SState u st) (STokens u)
tokensInSState = Lens.lens _SState_tokens
                 $ \(SState {..}) x -> SState { _SState_tokens = x, .. }

stateInSState :: Lens.Lens' (SState u st) st
stateInSState = Lens.lens _SState_state
                $ \(SState {..}) x -> SState { _SState_state = x, .. }

--------------------------------------------------------------------------------

data GenSState u where
  GenSState :: (Typeable st) => SState u st -> GenSState u

gssGet :: (MonadConc u, Typeable st) => SActorT st msg u (GenSState u)
gssGet = GenSState <$> SActorT MonadState.get

gssPut :: (MonadConc u, Typeable st, Typeable u)
       => GenSState u
       -> SActorT st msg u Bool
gssPut (GenSState state) = do
  case Dynamic.fromDynamic (Dynamic.toDyn state) of
    Just s  -> SActorT (MonadState.put s) >> pure True
    Nothing -> pure False

--------------------------------------------------------------------------------

type Spawned u = Map (MonadActor.TID u) (GenSMailbox u)

newtype WithSpawned u a
  = WithSpawned { fromWithSpawned :: StateT (Spawned u) u a }

runWithSpawned :: (MonadConc u) => WithSpawned u a -> u a
runWithSpawned (WithSpawned m) = StateT.evalStateT m mempty

liftWS :: (Monad u) => u a -> WithSpawned u a
liftWS = MonadTrans.lift .> WithSpawned

deriving instance (Functor     u) => Functor     (WithSpawned u)
deriving instance (Monad       u) => Applicative (WithSpawned u)
deriving instance (Monad       u) => Monad       (WithSpawned u)
deriving instance (MonadThrow  u) => MonadThrow  (WithSpawned u)
deriving instance (MonadCatch  u) => MonadCatch  (WithSpawned u)
deriving instance (MonadMask   u) => MonadMask   (WithSpawned u)

instance (MonadConc u) => MonadConc (WithSpawned u) where
  type STM      (WithSpawned u) = MonadConc.STM u
  type MVar     (WithSpawned u) = MonadConc.MVar u
  type CRef     (WithSpawned u) = MonadConc.CRef u
  type Ticket   (WithSpawned u) = MonadConc.Ticket u
  type ThreadId (WithSpawned u) = MonadConc.ThreadId u

  fork (WithSpawned m) = WithSpawned (MonadConc.fork m)
  forkOn i (WithSpawned m) = WithSpawned (MonadConc.forkOn i m)

  forkWithUnmask        f = WithSpawned
                            $ MonadConc.forkWithUnmask
                            $ \g -> (fromWithSpawned
                                     (f (fromWithSpawned .> g .> WithSpawned)))
  forkWithUnmaskN   n   f = WithSpawned
                            $ MonadConc.forkWithUnmaskN n
                            $ \g -> (fromWithSpawned
                                     (f (fromWithSpawned .> g .> WithSpawned)))
  forkOnWithUnmask    i f = WithSpawned
                            $ MonadConc.forkOnWithUnmask i
                            $ \g -> (fromWithSpawned
                                     (f (fromWithSpawned .> g .> WithSpawned)))
  forkOnWithUnmaskN n i f = WithSpawned
                            $ MonadConc.forkOnWithUnmaskN n i
                            $ \g -> (fromWithSpawned
                                     (f (fromWithSpawned .> g .> WithSpawned)))

  getNumCapabilities = liftWS MonadConc.getNumCapabilities
  setNumCapabilities = liftWS . MonadConc.setNumCapabilities
  myThreadId         = liftWS MonadConc.myThreadId
  yield              = liftWS MonadConc.yield
  threadDelay        = liftWS . MonadConc.threadDelay
  throwTo t          = liftWS . MonadConc.throwTo t
  newEmptyMVar       = liftWS MonadConc.newEmptyMVar
  newEmptyMVarN      = liftWS . MonadConc.newEmptyMVarN
  readMVar           = liftWS . MonadConc.readMVar
  tryReadMVar        = liftWS . MonadConc.tryReadMVar
  putMVar v          = liftWS . MonadConc.putMVar v
  tryPutMVar v       = liftWS . MonadConc.tryPutMVar v
  takeMVar           = liftWS . MonadConc.takeMVar
  tryTakeMVar        = liftWS . MonadConc.tryTakeMVar
  newCRef            = liftWS . MonadConc.newCRef
  newCRefN n         = liftWS . MonadConc.newCRefN n
  readCRef           = liftWS . MonadConc.readCRef
  atomicModifyCRef r = liftWS . MonadConc.atomicModifyCRef r
  writeCRef r        = liftWS . MonadConc.writeCRef r
  atomicWriteCRef r  = liftWS . MonadConc.atomicWriteCRef r
  readForCAS         = liftWS . MonadConc.readForCAS
  peekTicket' _      = MonadConc.peekTicket' (Proxy :: Proxy u)
  casCRef r t        = liftWS . MonadConc.casCRef r t
  modifyCRefCAS r    = liftWS . MonadConc.modifyCRefCAS r
  modifyCRefCAS_ r   = liftWS . MonadConc.modifyCRefCAS_ r
  atomically         = liftWS . MonadConc.atomically
  readTVarConc       = liftWS . MonadConc.readTVarConc

--------------------------------------------------------------------------------

newtype SActorT st msg u ret
  = SActorT
    { runSActorT :: VCActorT (SState u st) (SMessage u msg) u ret }

deriving instance (Functor     u) => Functor     (SActorT st msg u)
deriving instance (Applicative u) => Applicative (SActorT st msg u)
deriving instance (Monad       u) => Monad       (SActorT st msg u)
deriving instance (MonadThrow  u) => MonadThrow  (SActorT st msg u)
deriving instance (MonadCatch  u) => MonadCatch  (SActorT st msg u)
deriving instance (MonadMask   u) => MonadMask   (SActorT st msg u)

instance MonadTrans (SActorT st msg) where
  lift = MonadTrans.lift .> SActorT

instance (MonadConc u) => MonadState st (SActorT st msg u) where
  get = _SState_state <$> SActorT MonadState.get
  put value = SActorT $ do
    SState snapshots tokens _ <- MonadState.get
    MonadState.put (SState snapshots tokens value)

instance ( MonadConc u, Typeable st, Typeable msg
         ) => MonadActor (SActorT st msg u) where
  type A (SActorT st msg u) = SMailbox u
  type S (SActorT st msg u) = st
  type M (SActorT st msg u) = msg
  type U (SActorT st msg u) = WithSpawned u

  addrToTID _ = (\(SMailbox mb) -> mb)
                .> (MonadActor.addrToTID
                    (Proxy @(VCActorT (SState u st) (SMessage u msg) u)))

  spawn initial (SActorT act) = do
    mb <- liftWS (SMailbox <$> MonadActor.spawn (initialSState initial) act)
    WithSpawned (MonadState.modify (Map.insert _ _))
    pure mb

  self = SMailbox <$> SActorT MonadActor.self

  send (SMailbox addr) value = do
    -- FIXME: we need to send SMessageDone here
    tokens <- SActorT (Lens.use tokensInSState)
    me <- GenSMailbox <$> MonadActor.self
    SActorT (MonadActor.send addr (SMessageNormal tokens me value))

  recv cb = internalRecv (\(_, _, msg) -> void $ cb msg)

instance ( MonadConc u, Typeable st, Typeable msg
         ) => MonadVC (SActorT st msg u) where
  getClock = SActorT MonadVC.getClock

--------------------------------------------------------------------------------

internalRecv :: forall st msg u.
                (MonadConc u, Typeable st, Typeable msg)
             => ((STokens u, GenSMailbox u, msg) -> SActorT st msg u ())
             -> SActorT st msg u ()
internalRecv cb = do
  -- Handle an incoming 'SMessageNormal' message.
  let handleNormal :: (STokens u, GenSMailbox u, msg)
                   -> SActorT st msg u ()
      handleNormal (tokens, origin, value) = void $ do
        myTokenMap <- SActorT (Lens.use (tokensInSState . _STokens))

        let messageTokenMap :: Map (SnapshotID u) (GenSMailbox u)
            messageTokenMap = Lens.view _STokens tokens

        let diff :: (Ord k) => Map k a -> Map k a -> [(k, a)]
            diff a b = Map.toList (Map.difference a b)

        -- Iterate over the tokens that we are seeing for the first time in
        -- this message.
        forM_ (diff messageTokenMap myTokenMap) $ \(sid, observerGMB) -> do
          -- Send our state to the observer process of the token.
          void $ do
            me <- GenSMailbox <$> MonadActor.self
            gss <- gssGet
            gsmSend observerGMB (SMessageState sid me gss)

          -- Add the token to our tokens map.
          void $ do
            let combine :: GenSMailbox u -> GenSMailbox u -> GenSMailbox u
                combine _ _ = error "something very weird is happening"
            SActorT $ Lens.modifying (tokensInSState . _STokens)
              $ Map.insertWith combine sid observerGMB

        -- Iterate over the tokens that we have seen that are not in the
        -- received message.
        forM_ (diff myTokenMap messageTokenMap) $ \(sid, observerGMB) -> do
          -- Forward the message to the observer process, since it must have
          -- been sent before the snapshot.
          void $ do
            sender <- pure origin
            recip  <- GenSMailbox <$> MonadActor.self
            let contents :: (STokens u, Dynamic)
                contents = (tokens, Dynamic.toDyn value)
            gsmSend observerGMB (SMessageRecv sid sender recip contents)

        -- Yield control to the callback we were given.
        cb (tokens, origin, value)

  -- Handle an incoming 'SMessageRecv' message.
  let handleRecv :: (SnapshotID u, GenSMailbox u, GenSMailbox u, GenSMessage u)
                 -> SActorT st msg u ()
      handleRecv (sid, sender, recip, contents) = void $ do
        -- ~ snapshotAddMessage sid (gsmTID sender, gsmTID recip) contents
        let f :: ActorSnapshot u -> ActorSnapshot u
            f = Lens.over messagesInActorSnapshot
                (\v -> Vector.snoc v (gsmTID sender, contents))
        upsertSnapshot sid
          $ Lens.over statesInSystemSnapshot (Map.adjust f (gsmTID recip))

  -- Handle an incoming 'SMessageState' message.
  let handleState :: (SnapshotID u, GenSMailbox u, GenSState u)
                  -> SActorT st msg u ()
      handleState (sid, actor, state) = void $ do
        -- Set the state of the actor associated with the given 'GenSMailbox'
        -- to the given 'GenSState' in the 'SystemSnapshot' associated with
        -- the given 'SnapshotID'.
        snapshotSetState sid (gsmTID actor) state

  -- Handle an incoming 'SMessageStart' message.
  let handleStart :: (SnapshotID u, GenSMailbox u)
                  -> SActorT st msg u ()
      handleStart (sid, observer) = void $ do
        SActorT (Lens.modifying
                 (tokensInSState . _STokens) (Map.insert sid observer))

  -- Handle an incoming 'SMessageDone' message.
  let handleDone :: (SnapshotID u, GenSMailbox u)
                 -> SActorT st msg u ()
      handleDone (sid, actor) = void $ do
        -- Set the actor associated with the given 'GenSMailbox' to "done"
        -- in the 'SystemSnapshot' associated with the given 'SnapshotID'.
        upsertSnapshot sid
          $ Lens.over doneInSystemSnapshot
          $ Map.insert (gsmTID actor) True

  -- Dispatch on the received message.
  SActorT $ MonadActor.recv $ \msg -> do
    runSActorT $ case msg of
      SMessageNormal ts  f   value -> handleNormal (ts, f, value)
      SMessageRecv   sid s r value -> handleRecv   (sid, s, r, value)
      SMessageState  sid a   state -> handleState  (sid, a, state)
      SMessageStart  sid o         -> handleStart  (sid, o)
      SMessageDone   sid a         -> handleDone   (sid, a)

--------------------------------------------------------------------------------

addMapDefault :: (Ord k) => (k, v) -> Map k v -> Map k v
addMapDefault (k, v) = Map.alter (fromMaybe v .> Just) k

-- | Update the snapshot with the given 'SnapshotID' using the given function.
--   If there is no snapshot with that 'SnapshotID', we first create a default
--   using an empty 'SystemSnapshot'.
upsertSnapshot :: forall u st msg.
                  (MonadConc u, Typeable st, Typeable msg)
               => SnapshotID u
               -> (SystemSnapshot u -> SystemSnapshot u)
               -> SActorT st msg u ()
upsertSnapshot sid f = SActorT $ do
  Lens.modifying snapshotsInSState
    (addMapDefault (sid, emptySystemSnapshot) .> Map.adjust f sid)

-- | Update the 'ActorSnapshot' associated with the actor with the given
--   'MonadActor.TID' in the snapshot with the given 'SnapshotID'.
--
--   If there is already an 'ActorSnapshot' with that 'MonadActor.TID' and
--   'SnapshotID', the new 'ActorSnapshot' will be combined with the old in
--   the following way:
--     1. The new actor state replaces the old state.
--     2. The new message vector is appended to the old message vector.
upsertActorSnapshot :: forall u st msg.
                       (MonadConc u, Typeable st, Typeable msg)
                    => SnapshotID u
                    -> MonadActor.TID u
                    -> ActorSnapshot u
                    -> SActorT st msg u ()
upsertActorSnapshot sid tid snap = do
  let combine :: ActorSnapshot u -> ActorSnapshot u -> ActorSnapshot u
      combine (ActorSnapshot sOld mOld) (ActorSnapshot sNew mNew)
        = ActorSnapshot sNew (mOld <> mNew)
  upsertSnapshot sid
    $ Lens.over statesInSystemSnapshot (Map.insertWith (flip combine) tid snap)

-- | Set the state associated with the actor with the given 'MonadActor.TID'
--   in the snapshot with the given 'SnapshotID'.
snapshotSetState :: forall u st msg.
                    (MonadConc u, Typeable st, Typeable msg)
                 => SnapshotID u
                 -> MonadActor.TID u
                 -> GenSState u
                 -> SActorT st msg u ()
snapshotSetState sid tid state
  = upsertActorSnapshot sid tid (ActorSnapshot state mempty)

--------------------------------------------------------------------------------

snapshot :: forall st msg u.
            (MonadConc u, Typeable st, Typeable msg)
         => Vector (GenSMailbox u)
         -> SActorT st msg u (SystemSnapshot u)
snapshot actors = do
  -- Create the snapshot ID
  snapID :: SnapshotID u <- do
    origin <- MonadActor.selfTID
    start <- MonadVC.lookupVC origin <$> MonadVC.getClock
    pure (SnapshotID origin start)

  -- Save the current state of the observer to the snapshot.
  () <- do
    me <- MonadActor.selfTID
    saved <- GenSState <$> SActorT MonadState.get
    snapshotSetState snapID me saved

  -- For each actor `a`:
  Vector.forM_ actors $ \actor -> do
    -- Initialize `a` as "not done".
    upsertSnapshot snapID
      $ Lens.over doneInSystemSnapshot
      $ Map.insert (gsmTID actor) False

    -- Send a "start snapshot" message to `a`.
    me <- GenSMailbox <$> MonadActor.self
    gsmSend actor (SMessageStart snapID me)

  -- Receive messages until the snapshot is finished.
  --
  -- The actor saves the messages in a 'Vector' and then adds them back into the
  -- message queue at the end by sending them to itself.
  () <- do
    let recurse :: Vector (STokens u, GenSMailbox u, msg)
                -> SActorT st msg u ()
        recurse missed = do
          internalRecv $ \(tokens, origin, msg) -> SActorT $ do
            me <- MonadActor.self
            let missed' = Vector.snoc missed (tokens, origin, msg)
            -- If the "done" map associated with our snapshot is all 'True',
            -- then the snapshot is finished.
            finished <- Lens.use (snapshotsInSState . Lens.at snapID)
                        >>= fmap (Lens.view doneInSystemSnapshot)
                        .>  maybe False (Map.elems .> and)
                        .>  pure
            if finished
              then Vector.forM_ missed'
                   $ \(ts, o, m) -> MonadActor.send me (SMessageNormal ts o m)
              else runSActorT (recurse missed')

    -- Run `recurse` with an empty vector of missed messages to begin with.
    recurse Vector.empty

  -- The snapshot is now guaranteed to be finished, so we look it up in the
  -- hashtable of snapshots. The assertion should never fail, but we cannot
  -- guarantee this statically without much more complicated types.
  result <- SActorT (Lens.use (snapshotsInSState . Lens.at snapID))
            >>= maybe (fail "assertion failed!") pure

  -- Now that the snapshot is finished and we've retrieved it from the state,
  -- we can delete it from the state.
  SActorT (Lens.modifying snapshotsInSState (Map.delete snapID))

  pure result

--------------------------------------------------------------------------------

restore :: forall st msg u.
           (MonadConc u, Typeable st, Typeable msg)
        => SystemSnapshot u
        -> SActorT st msg u ()
restore = _

--------------------------------------------------------------------------------
