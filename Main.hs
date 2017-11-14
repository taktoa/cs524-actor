--------------------------------------------------------------------------------

{-# OPTIONS_GHC -Wall -Wno-unused-do-bind #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GADTSyntax                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedLists            #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}

--------------------------------------------------------------------------------

module Main
  ( module Main -- FIXME: specific export list
  ) where

--------------------------------------------------------------------------------

import           Control.Arrow
import           Data.Either
import           Data.Maybe

import           Flow                       ((.>), (|>))

import           Control.Exception
                 (Exception, NonTermination (NonTermination), throwIO)

import           Control.Monad.Catch        (MonadThrow (throwM))

import           Control.Monad              (forever)
import           Control.Monad.IO.Class     (MonadIO (liftIO))

import           Control.Concurrent         (threadDelay)

import           Control.Concurrent.MVar    (MVar)
import qualified Control.Concurrent.MVar    as MVar

import           Control.Concurrent.Actor   (ActorM)
import qualified Control.Concurrent.Actor   as Actor

import           Control.Monad.Trans.Class  (MonadTrans (lift))

import           Control.Monad.Trans.Reader (ReaderT)
import qualified Control.Monad.Trans.Reader as ReaderT

import           Control.Monad.Trans.State  (StateT)
import qualified Control.Monad.Trans.State  as StateT

import           Data.Text                  (Text)
import qualified Data.Text                  as Text

import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map

import           Data.Set                   (Set)
import qualified Data.Set                   as Set

import           Data.Vector                (Vector, (!?))
import qualified Data.Vector                as Vector

import           Data.Dynamic               (Dynamic)
import qualified Data.Dynamic               as Dynamic

import           Data.Typeable              (Typeable, typeOf)

--------------------------------------------------------------------------------

type ActorKey = Int
type ActorAddress = Actor.Address

--------------------------------------------------------------------------------

data VectorClock
  = VectorClock
    { vectorClockMap :: !(Map Actor.Address Int)
    }
  deriving ()

--------------------------------------------------------------------------------

data ActorState
  = ActorState
    { actorStateVars :: !(Vector Dynamic)
      -- ^ All of the 'AVar's created during this actor's execution so far.
    , actorStateVC   :: !VectorClock
      -- ^ The actor's current vector clock.
    }
  deriving ()

actorStateEmpty :: ActorState
actorStateEmpty = ActorState mempty (VectorClock mempty)

actorStateLookupVar :: ActorKey -> ActorState -> Maybe Dynamic
actorStateLookupVar key (ActorState vars _) = vars !? key

actorStateAddVar :: Dynamic -> ActorState -> (ActorState, ActorKey)
actorStateAddVar value (ActorState vars vc)
  = (ActorState (Vector.snoc vars value) vc, Vector.length vars)

actorStateIncrVC :: Actor.Address -> ActorState -> ActorState
actorStateIncrVC addr (ActorState vars (VectorClock m))
  = let old = fromMaybe 0 (Map.lookup addr m)
        m' = Map.insert addr (old + 1) m
    in ActorState vars (VectorClock m')

actorStateUpdateVC :: (Actor.Address, Int) -> ActorState -> ActorState
actorStateUpdateVC (addr, clock) (ActorState vars (VectorClock m))
  = let m' = Map.insertWith max addr clock m
    in ActorState vars (VectorClock m')

actorStateLookupVC :: Actor.Address -> ActorState -> Int
actorStateLookupVC addr (ActorState _ (VectorClock m))
  = fromMaybe 0 (Map.lookup addr m)

--------------------------------------------------------------------------------

data Snapshot
  = Snapshot
    { snapshotStates   :: Map Actor.Address ActorState
    , snapshotChannels :: [(Dynamic, Actor.Address, Actor.Address)]
    }
  deriving ()

snapshotLookupState :: Actor.Address -> Snapshot -> Maybe ActorState
snapshotLookupState addr (Snapshot m _) = Map.lookup addr m

--------------------------------------------------------------------------------

data SnapStart
  = SnapStart
  deriving ()

data SnapRemaining
  = SnapRemaining
    { snapRemainingOrigin    :: !Actor.Address
    , snapRemainingAddresses :: !(Vector Actor.Address)
    }
  deriving ()

data SnapMessage a
  = SnapMessage
    { snapMessageClock     :: !(Actor.Address, Int)
    , snapMessageRemaining :: !(Maybe SnapRemaining)
    , snapMessageValue     :: !a
    }
  deriving (Functor)

data SnapDone
  = SnapDone
  deriving ()

--------------------------------------------------------------------------------

type SnapActorState = (Bool, ActorState)

newtype SnapActorM a
  = SnapActorM (ReaderT (MVar SnapActorState) ActorM a)
  deriving (Functor, Applicative, Monad, MonadIO)

liftActorM :: forall a. ActorM a -> SnapActorM a
liftActorM action = SnapActorM (lift action)

-- NOT PUBLIC
snapActorModify :: StateT SnapActorState IO a -> SnapActorM a
snapActorModify action = SnapActorM $ do
  stateMVar <- ReaderT.ask
  liftIO $ MVar.modifyMVarMasked stateMVar $ \state -> do
    (\(a, b) -> (b, a)) <$> StateT.runStateT action state

snapActorIncrVC :: SnapActorM ()
snapActorIncrVC = do
  addr <- self
  snapActorModify $ StateT.modify (second (actorStateIncrVC addr))

snapActorGetVC :: SnapActorM VectorClock
snapActorGetVC = do
  actorStateVC . snd <$> snapActorModify StateT.get

snapActorLookupVC :: Actor.Address -> SnapActorM Int
snapActorLookupVC addr = do
  actorStateLookupVC addr . snd <$> snapActorModify StateT.get

-- startSnapshot :: SnapActorM ()
-- startSnapshot = SnapActorM $ do
--   stateMVar <- ReaderT.ask
--   liftIO $ MVar.modifyMVarMasked_ stateMVar (first (const True) .> pure)
--
-- stopSnapshot :: SnapActorM ()
-- stopSnapshot = SnapActorM $ do
--   stateMVar <- ReaderT.ask
--   liftIO $ MVar.modifyMVarMasked_ stateMVar (first (const False) .> pure)
--
-- isSnapshotInProgress :: SnapActorM Bool
-- isSnapshotInProgress = SnapActorM $ do
--   stateMVar <- ReaderT.ask
--   fst <$> liftIO (MVar.readMVar stateMVar)

--------------------------------------------------------------------------------

data SnapActorError
  = AVarLookupError
  | AVarDynamicError
  deriving (Eq, Show)

instance Exception SnapActorError

throwAVarLookupError :: forall m a. (MonadThrow m) => m a
throwAVarLookupError = throwM AVarLookupError

throwAVarDynamicError :: forall m a. (MonadThrow m) => m a
throwAVarDynamicError = throwM AVarDynamicError

--------------------------------------------------------------------------------

newtype AVar a
  = AVar ActorKey
  deriving ()

newAVar :: forall a. (Typeable a) => a -> SnapActorM (AVar a)
newAVar initial = SnapActorM $ do
  let initialDyn = Dynamic.toDyn initial
  stateMVar <- ReaderT.ask
  liftIO $ MVar.modifyMVarMasked stateMVar $ \(indices, state) -> do
    let (state', key) = actorStateAddVar initialDyn state
    pure ((indices, state'), AVar key)

readAVar :: forall a. (Typeable a) => AVar a -> SnapActorM a
readAVar (AVar key) = SnapActorM $ do
  stateMVar <- ReaderT.ask
  (_, state) <- liftIO (MVar.readMVar stateMVar)
  dyn <- actorStateLookupVar key state
         |> maybe (liftIO (throwIO AVarLookupError)) pure
  Dynamic.fromDynamic dyn
    |> maybe (liftIO (throwIO AVarDynamicError)) pure

--------------------------------------------------------------------------------

-- data Actor state msg where
--   Self  :: (Actor.Address -> Actor state msg) -> Actor state msg
--   Recv  :: (msg -> Actor state msg)           -> Actor state msg
--   Send  :: (msg, Actor.Address)               -> Actor state msg
--   Seq   :: [Actor state msg]                  -> Actor state msg
--   RunIO :: (IO a, a -> Actor state msg)       -> Actor state msg

data SnapHandler where
  Case    :: (Typeable msg) => (msg -> SnapActorM ()) -> SnapHandler
  Default ::                   SnapActorM ()          -> SnapHandler

--------------------------------------------------------------------------------

spawn :: SnapActorM () -> IO Actor.Address
spawn (SnapActorM action) = do
  stateMVar <- liftIO $ MVar.newMVar (False, actorStateEmpty)
  Actor.spawn (ReaderT.runReaderT action stateMVar)

self :: SnapActorM Actor.Address
self = liftActorM Actor.self

snapshot :: forall a.
            Vector Actor.Address
         -> (Snapshot -> SnapActorM a)
         -> SnapActorM a
snapshot callback = do
  _

receive :: [SnapHandler] -> SnapActorM ()
receive handlers = SnapActorM $ do
  stateMVar <- ReaderT.ask

  let fromSnapActorM :: SnapActorM a -> ActorM a
      fromSnapActorM (SnapActorM action) = do
        ReaderT.runReaderT action stateMVar

  let withSnap :: SnapHandler -> Vector Actor.Handler
      withSnap (Default m) = [ Actor.Default $ do
                                 fromSnapActorM m
                             ]
      withSnap (Case    f) = [ Actor.Case $ \msg -> do
                                 _
                                 fromSnapActorM (f (snapMessageValue msg))
                             ]

  let alreadySeen :: SnapMessage a -> ActorM Bool
      alreadySeen = _

  lift $ Actor.receive $ Vector.toList $ mconcat
    [ [ Actor.Case $ \SnapStart -> fromSnapActorM $ do
          let SnapMessage remaining SnapStart = msg
          bool <- isSnapshotInProgress
          case (bool, remaining) of
            (False, Just _) -> do startSnapshot

          if bool
            then do
                    startSnapshot
            else do _
          -- send state to observer process
          pure ()
      ]
    , Vector.concatMap withSnap (Vector.fromList handlers)
    ]

send :: forall message.
        (Typeable message)
     => Actor.Address
     -> message
     -> SnapActorM ()
send addr msg = do
  _

--------------------------------------------------------------------------------

printMsg :: (MonadIO m) => [String] -> m ()
printMsg = liftIO . putStrLn . mconcat

--------------------------------------------------------------------------------

act1 :: ActorM ()
act1 = do
  me <- Actor.self
  liftIO $ print "act1 started"
  forever $ Actor.receive
    [ Actor.Case $ \((n, a) :: (Int, Actor.Address)) -> do
        if n > 10000
          then do liftIO (throwIO NonTermination)
          else do printMsg ["act1 got ", show n, " from ", show a]
                  Actor.send a (n + 1, me)
    , Actor.Case $ \(_ :: Actor.RemoteException) -> do
        printMsg ["act1 received a remote exception"]
    , Actor.Default $ printMsg ["act1: received a malformed message"]
    ]


act2 :: Actor.Address -> ActorM ()
act2 addr = do
    Actor.monitor addr
    -- Actor.setFlag TrapRemoteExceptions
    me <- Actor.self
    Actor.send addr (0 :: Int, me)
    forever $ Actor.receive
      [ Actor.Case $ \((n, a) :: (Int, Actor.Address)) -> do
          printMsg ["act2 got ", show n, " from ", show a]
          Actor.send a (n + 1, me)
      , Actor.Case $ \(e :: Actor.RemoteException) -> do
          printMsg ["act2 received a remote exception: ", show e]
      ]

act3 :: Actor.Address -> ActorM ()
act3 addr = do
    Actor.monitor addr
    Actor.setFlag Actor.TrapRemoteExceptions
    forever $ Actor.receive
      [ Actor.Case $ \(e :: Actor.RemoteException) -> do
          printMsg ["act3 received a remote exception: ", show e]
      ]

--------------------------------------------------------------------------------

main :: IO ()
main = do
    addr1 <- Actor.spawn act1
    addr2 <- Actor.spawn (act2 addr1)
    Actor.spawn (act3 addr2)
    threadDelay 20000000

--------------------------------------------------------------------------------
