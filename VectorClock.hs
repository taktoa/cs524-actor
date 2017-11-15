--------------------------------------------------------------------------------

{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}

--------------------------------------------------------------------------------

module VectorClock
  ( module VectorClock
  ) where

--------------------------------------------------------------------------------

import           Actor                          (ActorT)
import qualified Actor                          as ActorT

import           Control.Monad.Trans.Class      (MonadTrans)
import qualified Control.Monad.Trans.Class      as MonadTrans


import           Control.Monad.Conc.Class       (MonadConc)
import qualified Control.Monad.Conc.Class       as MonadConc

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

type Clock = Int

--------------------------------------------------------------------------------

type TID monad = MonadConc.ThreadId monad

newtype VC monad
  = VC (Map (TID monad) Clock)

emptyVC :: (MonadConc monad)
        => VC monad
emptyVC = VC Map.empty

lookupVC :: (MonadConc monad)
         => TID monad
         -> VC monad
         -> Clock
lookupVC tid (VC m) = fromMaybe 0 (Map.lookup tid m)

incrVC :: (MonadConc monad)
       => TID monad
       -> VC monad
       -> VC monad
incrVC tid (VC m) = let old = fromMaybe 0 (Map.lookup tid m)
                    in VC (Map.insert tid (old + 1) m)

updateVC :: (MonadConc monad)
         => (TID monad, Clock)
         -> VC monad
         -> VC monad
updateVC (tid, clock) (VC m) = VC (Map.insertWith max tid clock m)

fromVC :: (MonadConc monad)
       => VC monad
       -> Map (TID monad) Clock
fromVC (VC m) = m

--------------------------------------------------------------------------------

data WithVC message monad value
  = WithVC
    { vcClock :: !(VC monad)
    , vcValue :: !value
    }

--------------------------------------------------------------------------------

type VCActorT st message monad ret
  = ActorT (WithVC message monad st) (WithVC message monad message) monad ret

type VCAddress message monad
  = ActorT.Address (WithVC message monad message) monad

--------------------------------------------------------------------------------

liftVC :: forall st message monad ret.
          (MonadConc monad, Ord (MonadConc.ThreadId monad))
       => ActorT   st message monad ret
       -> VCActorT st message monad ret
liftVC actor = do
  clockVar <- do
    WithVC vc _ <- ActorT.get
    MonadTrans.lift (MVar.newMVar vc)

  let incrSelf :: monad ()
      incrSelf = do
        self <- MonadConc.myThreadId
        MVar.modifyMVar_ clockVar (incrVC self .> pure)

  let modPut :: st -> monad (WithVC message monad st)
      modPut state = do
        m <- MVar.readMVar clockVar
        pure (WithVC m state)

  let modGet :: WithVC message monad st -> monad st
      modGet = vcValue .> pure

  let modSend :: message -> monad (WithVC message monad message)
      modSend message = do
        incrSelf
        m <- MVar.readMVar clockVar
        pure (WithVC m message)

  let modRecv :: WithVC message monad message -> monad message
      modRecv (WithVC m message) = do
        incrSelf
        let compose = map Endo .> mconcat .> appEndo
        let fs = updateVC <$> Map.toList (fromVC m)
        MVar.modifyMVar_ clockVar (compose fs .> pure)
        pure message

  ret <- ActorT.mapActorT
         (Lens.iso modPut modGet)
         (Lens.iso modSend modRecv)
         actor

  () <- do
    WithVC _ state <- ActorT.get
    vc <- MonadTrans.lift (MVar.readMVar clockVar)
    ActorT.put (WithVC vc state)

  pure ret

--------------------------------------------------------------------------------
