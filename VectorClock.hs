--------------------------------------------------------------------------------

{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
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

import           Control.Monad                  (forever)

import           Data.Map                       (Map)
import qualified Data.Map                       as Map

import qualified Control.Lens                   as Lens

import           Data.Maybe
import           Data.Monoid

import           Flow                           ((.>), (|>))

--------------------------------------------------------------------------------

class ( MonadActor st msg m, Ord (MonadActor.Addr m)
      ) => MonadVC st msg m | m -> st, m -> msg where
  getClock :: m (VC tid)

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

data WithVC m value
  = WithVC
    { vcClock :: !(VC (MonadConc.ThreadId m))
    , vcValue :: !value
    }

--------------------------------------------------------------------------------

newtype VCActorT st msg m ret
  = VCActorT (ActorT (WithVC m st) (WithVC m msg) m ret)

deriving instance (Functor     m) => Functor     (VCActorT st msg m)
deriving instance (Applicative m) => Applicative (VCActorT st msg m)
deriving instance (Monad       m) => Monad       (VCActorT st msg m)
deriving instance (MonadThrow  m) => MonadThrow  (VCActorT st msg m)
deriving instance (MonadCatch  m) => MonadCatch  (VCActorT st msg m)
deriving instance (MonadMask   m) => MonadMask   (VCActorT st msg m)

instance (MonadConc m) => MonadState st (VCActorT st msg m) where
  get = vcValue <$> VCActorT MonadState.get
  put value = VCActorT $ do
    WithVC clock _ <- MonadState.get
    MonadState.put (WithVC clock value)

instance (MonadConc m) => MonadActor st msg (VCActorT st msg m) where
  type Addr (VCActorT st msg m) = VCMailbox msg m
  type C    (VCActorT st msg m) = m

  spawn initial (VCActorT act) = do
    addr <- MonadActor.spawn (WithVC emptyVC initial) act
    pure (VCMailbox addr)

  self = VCMailbox <$> VCActorT MonadActor.self

  send (VCMailbox addr) msg = VCActorT $ do
    (WithVC clock state) <- MonadState.get
    me <- MonadTrans.lift MonadConc.myThreadId
    let clock' = incrVC me clock
    MonadState.put (WithVC clock' state)
    MonadActor.send addr (WithVC clock' msg)

  recv handler = VCActorT $ MonadActor.recv $ \(WithVC new msg) -> do
    let compose :: [a -> a] -> (a -> a)
        compose = map Endo .> mconcat .> appEndo

    (WithVC clock state) <- MonadState.get
    me <- MonadTrans.lift MonadConc.myThreadId
    let clock' = incrVC me clock
                 |> compose (updateVC <$> Map.toList (fromVC new))
    MonadState.put (WithVC clock' state)

    (\(VCActorT act) -> act) $ handler msg

--------------------------------------------------------------------------------

newtype VCMailbox msg m
  = VCMailbox (ActorT.Mailbox (WithVC m msg) m)

deriving instance (MonadConc m) => Eq   (VCMailbox msg m)
deriving instance (MonadConc m) => Ord  (VCMailbox msg m)

instance (MonadConc m) => Show (VCMailbox msg m) where
  show (VCMailbox mb) = "VC" ++ show mb

--------------------------------------------------------------------------------

-- liftVC :: forall st msg m ret.
--           (MonadConc m)
--        => ActorT   st msg m ret
--        -> VCActorT st msg m ret
-- liftVC actor = do
--   clockVar <- do
--     WithVC vc _ <- ActorT.get
--     MonadTrans.lift (MVar.newMVar vc)
--
--   let incrSelf :: m ()
--       incrSelf = do
--         self <- MonadConc.myThreadId
--         MVar.modifyMVar_ clockVar (incrVC self .> pure)
--
--   let modPut :: st -> m (WithVC msg m st)
--       modPut state = do
--         m <- MVar.readMVar clockVar
--         pure (WithVC m state)
--
--   let modGet :: WithVC msg m st -> m st
--       modGet = vcValue .> pure
--
--   let modSend :: msg -> m (WithVC msg m msg)
--       modSend message = do
--         incrSelf
--         m <- MVar.readMVar clockVar
--         pure (WithVC m message)
--
--   let modRecv :: WithVC msg m msg -> m msg
--       modRecv (WithVC m message) = do
--         incrSelf
--         let compose = map Endo .> mconcat .> appEndo
--         let fs = updateVC <$> Map.toList (fromVC m)
--         MVar.modifyMVar_ clockVar (compose fs .> pure)
--         pure message
--
--   ret <- ActorT.mapActorT
--          (Lens.iso modPut modGet)
--          (Lens.iso modSend modRecv)
--          actor
--
--   () <- do
--     WithVC _ state <- ActorT.get
--     vc <- MonadTrans.lift (MVar.readMVar clockVar)
--     ActorT.put (WithVC vc state)
--
--   pure ret

--------------------------------------------------------------------------------
