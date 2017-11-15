--------------------------------------------------------------------------------

{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

--------------------------------------------------------------------------------

module BrockAckerman
  ( module BrockAckerman
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

import           Control.Monad                  (forever, void)

import qualified Test.DejaFu                    as DejaFu
import qualified Test.DejaFu.Conc               as DejaFu

--------------------------------------------------------------------------------

eager :: forall m. (MonadConc m) => (Int -> m ()) -> m ()
eager printInt = void $ do
  let viewer :: ActorT () Int m ()
      viewer = forever $ do
        ActorT.recv $ \m -> do
          MonadTrans.lift (printInt m)
  viewerAddr <- ActorT.spawn () viewer
  let sender :: ActorT Bool Int m ()
      sender = do
        ActorT.recv $ \m -> do
          ActorT.send viewerAddr m
          first <- ActorT.get
          if first
            then ActorT.put False >> sender
            else forever (ActorT.recv (\_ -> pure ()))
  senderAddr <- ActorT.spawn True sender
  let recep :: ActorT () Int m ()
      recep = forever $ do
        ActorT.recv $ \m -> do
          ActorT.send senderAddr m
          ActorT.send senderAddr m
  ActorT.spawn () recep
  pure ()

autocheckExhaustive :: (Eq a, Show a)
                    => (forall s. DejaFu.ConcST s a)
                    -> IO Bool
autocheckExhaustive action = do
  let way = DejaFu.systematically DejaFu.noBounds
  let mt = DejaFu.SequentialConsistency
  DejaFu.autocheckWay way mt action

main :: IO ()
main = void $ do
  autocheckExhaustive $ do
    ioVar <- MVar.newMVar []
    eager (\x -> MVar.modifyMVar_ ioVar (\xs -> pure (x : xs)))
    reverse <$> MVar.readMVar ioVar

--------------------------------------------------------------------------------
