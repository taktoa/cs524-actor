--------------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GADTSyntax                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

--------------------------------------------------------------------------------

-- |
-- Module      :  Control.Concurrent.Actor
-- Copyright   :  (c) 2011 Alex Constandache
-- License     :  BSD3
-- Maintainer  :  alexander.the.average@gmail.com
-- Stability   :  alpha
-- Portability :  GHC only (requires throwTo)
--
-- This module implements Erlang-style actors
-- (what Erlang calls processes). It does not implement
-- network distribution (yet?). Here is an example:
--
--
-- > act1 :: ActorM ()
-- > act1 = do
-- >     me <- self
-- >     liftIO $ print "act1 started"
-- >     forever $ receive
-- >       [ Case $ \((n, a) :: (Int, Address)) ->
-- >             if n > 10000
-- >                 then do
-- >                     liftIO . throwIO $ NonTermination
-- >                 else do
-- >                     liftIO . putStrLn $ "act1 got " ++ show n ++ " from " ++ show a
-- >                     send a (n+1, me)
-- >       , Case $ \(e :: RemoteException) ->
-- >             liftIO . print $ "act1 received a remote exception"
-- >       , Default $ liftIO . print $ "act1: received a malformed message"
-- >       ]
-- >
-- > act2 :: Address -> ActorM ()
-- > act2 addr = do
-- >     monitor addr
-- >     -- setFlag TrapRemoteExceptions
-- >     me <- self
-- >     send addr (0 :: Int, me)
-- >     forever $ receive
-- >       [ Case $ \((n, a) :: (Int, Address)) -> do
-- >                     liftIO . putStrLn $ "act2 got " ++ (show n) ++ " from " ++ (show a)
-- >                     send a (n+1, me)
-- >       , Case $ \(e :: RemoteException) ->
-- >             liftIO . print $ "act2 received a remote exception: " ++ (show e)
-- >       ]
-- >
-- > act3 :: Address -> ActorM ()
-- > act3 addr = do
-- >     monitor addr
-- >     setFlag TrapRemoteExceptions
-- >     forever $ receive
-- >       [ Case $ \(e :: RemoteException) ->
-- >             liftIO . print $ "act3 received a remote exception: " ++ (show e)
-- >       ]
-- >
-- > main = do
-- >     addr1 <- spawn act1
-- >     addr2 <- spawn (act2 addr1)
-- >     spawn (act3 addr2)
-- >     threadDelay 20000000
module Control.Concurrent.Actor
  ( -- * Types
    Address
  , Handler (..)
  , ActorM
  , RemoteException
  , ActorExitNormal
  , Flag (..)

    -- * Actor actions
  , send
  , self
  , receive
  , receiveWithTimeout
  , spawn
  , monitor
  , link
  , setFlag
  , clearFlag
  , toggleFlag
  , testFlag
  ) where

--------------------------------------------------------------------------------

import           Control.Monad.IO.Class     (MonadIO (liftIO))
import           Data.Word                  (Word64)
import           System.Timeout             (timeout)

import qualified Control.Concurrent         as Conc

import           Control.Concurrent.Chan    (Chan)
import qualified Control.Concurrent.Chan    as Chan

import           Control.Concurrent.MVar    (MVar)
import qualified Control.Concurrent.MVar    as MVar

import           Control.Exception          (Exception, catches)
import qualified Control.Exception          as Exception

import qualified Data.Bits                  as Bits

import           Control.Monad.Trans.Reader (ReaderT)
import qualified Control.Monad.Trans.Reader as ReaderT

import           Data.Dynamic               (Dynamic)
import qualified Data.Dynamic               as Dynamic

import           Data.Typeable              (Typeable)

import           Data.Set                   (Set)
import qualified Data.Set                   as Set

import           Flow                       ((.>), (|>))

--------------------------------------------------------------------------------

-- | Exception raised by an actor on exit
data ActorExitNormal
  = ActorExitNormal
  deriving (Show)

instance Exception ActorExitNormal

data RemoteException
  = RemoteException Address Exception.SomeException
  deriving (Show)

instance Exception RemoteException

type Flags = Word64

data Flag
  = TrapRemoteExceptions
  deriving (Eq, Enum)

defaultFlags :: [Flag]
defaultFlags = []

setF :: Flag -> Flags -> Flags
setF = flip Bits.setBit . fromEnum

clearF :: Flag -> Flags -> Flags
clearF = flip Bits.clearBit . fromEnum

toggleF :: Flag -> Flags -> Flags
toggleF = flip Bits.complementBit . fromEnum

isSetF :: Flag -> Flags -> Bool
isSetF = flip Bits.testBit . fromEnum

data Context
  = Context
    { contextLSet  :: MVar (Set Address)
    , contextChan  :: Chan Message
    , contextFlags :: MVar Flags
    }
  deriving ()

--------------------------------------------------------------------------------

newtype Message
  = Message Dynamic
  deriving ()

instance Show Message where
    show (Message dyn) = show dyn

toMessage :: (Typeable a) => a -> Message
toMessage = Dynamic.toDyn .> Message

fromMessage :: (Typeable a) => Message -> Maybe a
fromMessage = (\(Message dyn) -> dyn) .> Dynamic.fromDynamic

--------------------------------------------------------------------------------

-- | The address of an actor, used to send messages
data Address
  = Address
    { addressThreadId :: Conc.ThreadId
    , addressContext  :: Context
    }
  deriving ()

instance Show Address where
  show (Address tid _) = "Address(" ++ show tid ++ ")"

instance Eq Address where
  addr1 == addr2 = let tid1 = addressThreadId addr1
                       tid2 = addressThreadId addr2
                   in tid1 == tid2

instance Ord Address where
  compare addr1 addr2 = let tid1 = addressThreadId addr1
                            tid2 = addressThreadId addr2
                        in compare tid1 tid2

--------------------------------------------------------------------------------

-- | The actor monad, just a reader monad on top of 'IO'.
newtype ActorM a
  = ActorM (ReaderT Context IO a)
  deriving (Functor, Applicative, Monad, MonadIO)

--------------------------------------------------------------------------------

data Handler where
  Case    :: (Typeable m) => (m -> ActorM ()) -> Handler
  Default ::                 ActorM ()        -> Handler

--------------------------------------------------------------------------------

-- | Used to obtain an actor's own address inside the actor
self :: ActorM Address
self = do
  c <- ActorM ReaderT.ask
  i <- liftIO Conc.myThreadId
  pure $ Address i c

--------------------------------------------------------------------------------

-- | Try to handle a message using a list of handlers.
-- The first handler matching the type of the message
-- is used.
receive :: [Handler] -> ActorM ()
receive hs = do
  ch <- ActorM (ReaderT.asks contextChan)
  msg <- liftIO (Chan.readChan ch)
  receiveHelper msg hs

-- | Same as receive, but times out after a specified
-- amount of time and runs a default action
receiveWithTimeout :: Int -> [Handler] -> ActorM () -> ActorM ()
receiveWithTimeout n hs act = do
  ch <- ActorM (ReaderT.asks contextChan)
  liftIO (timeout n (Chan.readChan ch))
    >>= maybe act (\m -> receiveHelper m hs)

receiveHelper :: Message -> [Handler] -> ActorM ()
receiveHelper msg = go
  where
    go []       = liftIO patMatchFail
    go (h : hs) = case h of
                    (Case cb)     -> maybe (go hs) cb (fromMessage msg)
                    (Default act) -> act

    patMatchFail = mconcat ["no handler for messages of type ", show msg]
                   |> Exception.PatternMatchFail
                   |> Exception.throwIO

--------------------------------------------------------------------------------

-- | Sends a message from inside the 'ActorM' monad
send :: Typeable m => Address -> m -> ActorM ()
send addr msg = do
  let ch = contextChan $ addressContext addr
  liftIO $ Chan.writeChan ch $ toMessage msg

--------------------------------------------------------------------------------

-- | Spawn a new actor with default flags
spawn :: ActorM () -> IO Address
spawn = spawn' defaultFlags

-- | Spawns a new actor, with the given flags set
spawn' :: [Flag] -> ActorM () -> IO Address
spawn' fs (ActorM act) = do
  ch <- liftIO Chan.newChan
  ls <- MVar.newMVar Set.empty
  fl <- MVar.newMVar (foldl (flip setF) 0x00 fs)
  let ctx = Context ls ch fl
  let orig = do ReaderT.runReaderT act ctx
                Exception.throwIO ActorExitNormal
  let wrap :: IO ()
      wrap = orig `catches` [ Exception.Handler remoteExH
                            , Exception.Handler someExH ]
      remoteExH :: RemoteException -> IO ()
      remoteExH e@(RemoteException a _) = do
        MVar.modifyMVar_ ls (Set.delete a .> pure)
        me <- Conc.myThreadId
        let se = Exception.toException e
        forward (RemoteException (Address me ctx) se)
      someExH :: Exception.SomeException -> IO ()
      someExH e = do
        me <- Conc.myThreadId
        forward (RemoteException (Address me ctx) e)
      forward :: RemoteException -> IO ()
      forward ex = do
        lset <- MVar.withMVar ls pure
        mapM_ (fwdaux ex) (Set.elems lset)
      fwdaux :: RemoteException -> Address -> IO ()
      fwdaux ex addr = do
        let rfs = contextFlags (addressContext addr)
        let rch = contextChan  (addressContext addr)
        trap <- MVar.withMVar rfs (pure . isSetF TrapRemoteExceptions)
        if trap
          then Chan.writeChan rch (toMessage ex)
          else Exception.throwTo (addressThreadId addr) ex
  tid <- Conc.forkIO wrap
  pure (Address tid ctx)

--------------------------------------------------------------------------------

-- | Monitors the actor at the specified address.
-- If an exception is raised in the monitored actor's
-- thread, it is wrapped in an 'ActorException' and
-- forwarded to the monitoring actor. If the monitored
-- actor terminates, an 'ActorException' is raised in
-- the monitoring actor.
monitor :: Address -> ActorM ()
monitor addr = do
  me <- self
  let ls = contextLSet (addressContext addr)
  liftIO $ MVar.modifyMVar_ ls (Set.insert me .> pure)

-- | Like `monitor`, but bi-directional
link :: Address -> ActorM ()
link addr = do
  monitor addr
  ls <- ActorM (ReaderT.asks contextLSet)
  liftIO $ MVar.modifyMVar_ ls (Set.insert addr .> pure)

--------------------------------------------------------------------------------

-- | Sets the specified flag in the actor's environment
setFlag :: Flag -> ActorM ()
setFlag flag = do
  fs <- ActorM (ReaderT.asks contextFlags)
  liftIO $ MVar.modifyMVar_ fs (setF flag .> pure)

-- | Clears the specified flag in the actor's environment
clearFlag :: Flag -> ActorM ()
clearFlag flag = do
  fs <- ActorM (ReaderT.asks contextFlags)
  liftIO $ MVar.modifyMVar_ fs (clearF flag .> pure)

-- | Toggles the specified flag in the actor's environment
toggleFlag :: Flag -> ActorM ()
toggleFlag flag = do
  fs <- ActorM (ReaderT.asks contextFlags)
  liftIO $ MVar.modifyMVar_ fs (toggleF flag .> pure)

-- | Checks if the specified flag is set in the actor's environment
testFlag :: Flag -> ActorM Bool
testFlag flag = do
  fs <- ActorM (ReaderT.asks contextFlags)
  liftIO $ MVar.withMVar fs (isSetF flag .> pure)

--------------------------------------------------------------------------------
