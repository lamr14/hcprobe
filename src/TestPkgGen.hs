{-# Language OverloadedStrings #-}
module Main where

import Network.Openflow.Ethernet.Types
import Network.Openflow.Ethernet.TCP
import Network.Openflow.Ethernet.Generator
import Network.Openflow.Misc
import HCProbe.TCP
import HCProbe.FakeSwitch (mcPrefix)

import Nettle.OpenFlow.StrictPut
import Data.Word
import Control.Monad
import System.IO
import qualified Data.ByteString as BS
import System.Random

data TestEthernetFrame = TestEthernetFrame !Int !MACAddr !MACAddr

instance EthernetFrame TestEthernetFrame where
  dstMacAddress  (TestEthernetFrame _ a _) = a
  {-# INLINE dstMacAddress #-}
  srcMacAddress (TestEthernetFrame _ _ b)  = b 
  {-# INLINE srcMacAddress #-}
  vlanID         = const Nothing
  {-# INLINE vlanID #-}
  typeCode       = const 0x806
  {-# INLINE typeCode #-}
  putPayload  (TestEthernetFrame n _ _)  = putEmptyPayload n 
  {-# INLINE putPayload #-}

pktNum = 1000000

main = do
  forM_ [1..pktNum] $ \i -> do
--    tcp <- testTCP' i i
    let s = makeEthernetFrame (TestEthernetFrame 64 i i)
    BS.hPutStr stdout s

