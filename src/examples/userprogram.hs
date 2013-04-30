{-# LANGUAGE OverloadedStrings #-}
-- | This module creates simple default switch without user program
-- that can be used for testing purposes:
--
-- This program should be as simple as possibe
module Main
  where

import Control.Concurrent (threadDelay)
import Control.Monad (replicateM_)
import Control.Monad.Trans (lift)
import Data.Bits                -- for IP creation [ TODO: remove ]
import HCProbe.EDSL
-- low level message generation
import Network.Openflow.Ethernet.Generator
import Network.Openflow.Ethernet.IPv4
import Network.Openflow.Ethernet.TCP
import HCProbe.Ethernet
import HCProbe.TCP
import HCProbe.EDSL.Handlers
import Data.IORef

main :: IO ()
main = do 
    let ip = 15 .|. (0x10 `shiftL` 24) -- TODO: make ip reasonable
    fakeSw <- config $ do
                switch ip $ do
                    features $ do
                      addPort [] [] [OFPPF_1GB_FD, OFPPF_COPPER] def
                      addPort [] [] [OFPPF_1GB_FD, OFPPF_COPPER] def
                    addMACs [1..450]
    print fakeSw

    withSwitch fakeSw "127.0.0.1" 6633 $ do
        
        packSt <- initPacketStats

        xid <- nextXID
        statsSend packSt $ putOFMessage $ do
                             putOFHeader $ do
                               putHdrVersion openflow_1_0
                               putHdrType OFPT_HELLO
                               putHdrXid xid

        -- wait for type examples: 
        lift $ putStr "waiting for barrier request.. "
        waitForType OFPT_BARRIER_REQUEST
        lift $ putStrLn  "[done]"
        lift $ putStr "waiting for echo request.. "
        --waitForType OFPT_ECHO_REQUEST
        lift $ putStrLn "[done]"
        
        -- thread delay example
        lift $ putStr "waiting for 1 second.. "
        lift $ threadDelay 1000000 -- wait for a second
        lift $ putStrLn "[done]"
        
        -- next buffer id example
        replicateM_ 10 $ do
            x <- nextBID
            lift . putStrLn $ "next buffer id " ++ show x

        count <- lift $ ( newIORef 0 :: IO (IORef Int))
        -- setUserHandler $ predicateHandler (\_->True) count

        -- Sending primitives:
        -- send simple packet
        -- tcp <- randomTCP
        lift $ putStrLn "sending packet. and waiting for responce."
        let port = 1
            m1   = 37
            m2   = 29
        dstGenMac <- genLocalMAC
        srcGenMac <- genLocalMAC
        let pl = putEthernetFrame . (EthFrameP m1 m2) . putIPv4Pkt $
                    TestPacketTCP { dstMAC = dstGenMac
                                  , srcMAC = srcGenMac
                                  , srcIP  = 99
                                  , dstIP  = 66
                                  , dstPort = 22
                                  , srcPort = 12342
                                  , testWSS = Just 3
                                  , testFlags = tcpFlagsOf [ACK]
                                  , testPayloadLen = 32
                                  , testAckNo = Nothing
                                  , testSeqNo = Nothing
                                  , testIpID = Nothing
                                  }
        bid <- statsSendOFPPacketIn packSt port pl
        waitForBID bid
        stats <- getStats packSt
        lift $ print stats
        lift $ putStrLn "done"
