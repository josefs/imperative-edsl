{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}

module Concurrent where

import Prelude hiding (break)

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif

import Language.Embedded.Imperative
import Language.Embedded.Concurrent
import Language.Embedded.Expr

type L =
  ThreadCMD :+:
  ChanCMD Expr :+:
  ControlCMD Expr :+:
  FileCMD Expr

-- | Deadlocks due to channel becoming full.
deadlock :: Program L ()
deadlock = do
  c <- newChan 1
  t <- fork $ readChan c >>= printf "%d\n"
  writeChan c (1 :: Expr Int)
  writeChan c 2
  writeChan c 3
  printf "This never happens: %d\n" (4 :: Expr Int)

-- | Map a function over a file, then print the results. Mapping and printing
--   happen in separate threads.
mapFile :: (Expr Float -> Expr Float) -> FilePath -> Program L ()
mapFile f i = do
  c1 <- newCloseableChan 5
  c2 <- newCloseableChan 5
  fi <- fopen i ReadMode

  t1 <- fork $ do
    while (return true) $ do
      x <- readChan c1
      readOK <- lastChanReadOK c1
      iff readOK
        (void $ writeChan c2 (f x))
        (closeChan c2 >> break)

  t2 <- fork $ do
    while (lastChanReadOK c2) $ do
      readChan c2 >>= printf "%f\n"

  t3 <- fork $ do
    while (Not <$> feof fi) $ do
      fget fi >>= void . writeChan c1
    fclose fi
    closeChan c1
  waitThread t2

-- | Waiting for thread completion.
waiting :: Program L ()
waiting = do
  t <- fork $ printf "Forked thread printing %d\n" (0 :: Expr Int)
  waitThread t
  printf "Main thread printing %d\n" (1 :: Expr Int)

-- | A thread kills itself using its own thread ID.
suicide :: Program L ()
suicide = do
  tid <- forkWithId $ \tid -> do
    printf "This is printed. %d\n" (0 :: Expr Int)
    killThread tid
    printf "This is not. %d\n" (0 :: Expr Int)
  waitThread tid
  printf "The thread is dead, long live the thread! %d\n" (0 :: Expr Int)

