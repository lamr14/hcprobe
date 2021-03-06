module Main ( main
            ) where

import System.Environment
import qualified HCProbe.FakeSwitch as FS
import HCProbe.ARP
import Network.Openflow.Types
import Network.Openflow.Ethernet.Types
import Network.Openflow.Ethernet.TCP
import Network.Openflow.Ethernet.Generator
import Network.Openflow.Messages
import Network.Openflow.Misc
import Network.Openflow.StrictPut
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Set as S
import Control.Applicative ((<$>))
import qualified Control.Concurrent as M
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMChan
import Control.Monad
import Control.Error
import Control.Monad.State
import Control.Monad.STM
import Control.Monad.Trans.Resource
import Data.Bits
import Data.Conduit
import Data.Conduit.Network
import Data.List
import Data.Maybe
import Data.Word
import qualified Data.Vector.Unboxed as V
import qualified Data.IntMap as M 
import System.Random
import Text.Printf
import Data.Time
import HCProbe.TCP

import Debug.Trace

fsDefaultHost       = "localhost"
fsDefaultPort       = "6633"

fsMacsPerPort       = 1000
fsPorts             = 48

pktSendTimeout      = 1
pktSendNumber       = 1000000

pktMsgOfVersion     = 1 :: Word8
pktMsgOfSwitch      = 1 :: Word32
pktMsgCapabuilities = [ OFPC_FLOW_STATS
                      , OFPC_TABLE_STATS
                      , OFPC_PORT_STATS
                      , OFPC_STP
                      , OFPC_RESERVED
                      , OFPC_IP_REASM
                      , OFPC_QUEUE_STATS
                      , OFPC_ARP_MATCH_IP
                      ]
pktMsgActionType    = FS.defActions
                      --[ OFPAT_OUTPUT
                      --, OFPAT_SET_VLAN_VID
                      --, OFPAT_SET_VLAN_PCP
                      --, OFPAT_STRIP_VLAN
                      --, OFPAT_SET_DL_SRC
                      --, OFPAT_SET_DL_DST
                      --, OFPAT_SET_NW_SRC
                      --, OFPAT_SET_NW_DST
                      --, OFPAT_SET_NW_TOS
                      --, OFPAT_SET_TP_SRC
                      --, OFPAT_SET_TP_DST
                      --, OFPAT_ENQUEUE
                      --, OFPAT_VENDOR
                      --]
pktMsgOfpPhyPorts   = []


{-
pktSendMsg pl = OfpMessage hdr (OfpPacketInReply  pktIn)
  where hdr   = header openflow_1_0 854 {-tid-} OFPT_PACKET_IN
        pktIn = OfpPacketIn { ofp_pkt_in_buffer_id = 2378 -- bid
                            , ofp_pkt_in_in_port   = 123123 -- pid 
                            , ofp_pkt_in_reason    = OFPR_NO_MATCH
                            , ofp_pkt_in_data      = pl
                            }
-}

pktSendMsg ::IO OfpMessage
pktSendMsg = do
    sdt <-dt
    return $ OfpMessage hd sdt
    where
        hd              = header pktMsgOfVersion pktMsgOfSwitch OFPT_FEATURES_REPLY
        dt              = do
            cb_st <- liftM (`mod` cb_l)           randomIO
            cb_c  <- liftM (`mod` (cb_l-cb_st))   randomIO
            at_st <- liftM (`mod` at_l)           randomIO
            at_c  <- liftM (`mod` (at_l-at_st))   randomIO
            return $ OfpFeatureReply 
                $ OfpSwitchFeatures 
                    1000 100 1 (cb cb_st cb_c) (at at_st at_c) pktMsgOfpPhyPorts

        cb start count  = listToFlags ofCapabilities $ drop start . take count $ pktMsgCapabuilities
        at start count  = listToFlags ofActionType $ drop start . take count $ pktMsgActionType 
        cb_l            = length pktMsgCapabuilities
        at_l            = length pktMsgActionType

ofClient fk@(FS.FakeSwitch sw switchIP _ sH rH) ad = replicateM_ pktSendNumber $ do
        liftM sendReplyT pktSendMsg
        M.threadDelay pktSendTimeout

payload = BS.replicate (16384*2) 0

client fk@(FS.FakeSwitch sw switchIP _ sH rH) ad = do
        let buffer = BS.replicate 65536 0
        send buffer buffer $ take pktSendNumber (cycle (liftM2 (,) [0..256] [0..256]) )
    where
        send _ _ [] = return ()
        send o b ((d,s):xs) = do
            let pl = putEthernetFrame $ testTCP d s
            (i,b') <-  liftIO $ runPutToBuffer b (putMessage (pktSendMsg pl))
            if i > 32768 
                then do yield (BS.take 32768 o) $$ appSink ad
                        (_, b'') <- liftIO $ runPutToBuffer o $ putByteString (BS.drop 32768 (BS.take i o))
                        liftIO $ M.threadDelay pktSendTimeout
                        send o b'' xs
                else send o b' xs
        -- liftIO $ FS.dump "OUT:" (ofp_header msg) replyBs
        -- maybe (return ()) (\x -> (liftIO.x) msg) sH
        -- where replyBs = FS.encodeMsg msg

zeroClient ad = replicateM_ pktSendNumber $ do
    yield replyBs $$ (appSink ad)
    where 
        replyBs = BS.replicate 32 $ 0

ofpClient sw host port client = runTCPClient (clientSettings port host) client

main = do
    args <- getArgs
    let (host,port) = host_port args
    fakeSw <- do
        let i = 100
        let ip = fromIntegral i .|. (0x10 `shiftL` 24)
        rnd <- newStdGen
        let macs = map (\x->FS.mcPrefix x) [1..fsPorts]
        return $ fst $ FS.makeSwitch (FS.defaultSwGen i ip rnd) 
                        (fromIntegral fsPorts) 
                        macs [] FS.defActions [] [] [OFPPF_1GB_FD,OFPPF_COPPER]
    let client = take_client fakeSw args
    initTime <- getCurrentTime
    ofpClient fakeSw (BS8.pack host) (read port) client
    now <- getCurrentTime

    putStr "Package nuber: "
    putStrLn $ show pktSendNumber
    putStr "Time for all is: "
    let timeDif = now `diffUTCTime` initTime
    print timeDif
    putStr "Time per package: "
    print $ timeDif / (fromIntegral pktSendNumber)
    where
        host_port (host:port:_) = (host,port)
        host_port (host:[]) = (host, fsDefaultPort)
        host_port [] = (fsDefaultHost, fsDefaultPort)
        take_client _ (_:_:"-0":_) = zeroClient
        take_client fs _ = ofClient fs
