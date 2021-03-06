{-# LANGUAGE OverloadedStrings, BangPatterns, RecordWildCards #-}
module Network.Openflow.Messages ( ofpHelloRequest -- FIXME <- not needed
                                 -- , ofpParsePacket  -- FIXME <- not needed
                                 -- , parseMessageData
                                 , bsStrict
                                 , putMessage
                                 , header
                                 , featuresReply
                                 , echoReply
                                 , headReply
                                 , errorReply
                                 , descStatsReply
                                 , getConfigReply
                                 , putOfpPort
                                 , putOfpPacketIn
                                 -- * builder functions
                                 , buildMessage
                                 ) where

import Network.Openflow.Types
import Network.Openflow.Misc
import Network.Openflow.StrictPut
import Data.Binary (Binary(..))
import Data.Binary.Get
import Data.Word
import Data.ByteString (ByteString)
import Blaze.ByteString.Builder -- import Data.ByteString.Lazy.Builder
import Data.Monoid
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Control.Monad
import Control.Applicative

import Debug.Trace
-- FIXME: rename ofpParse* to getOfp*


ofpHeaderLen :: Int
ofpHeaderLen = (8 + 8 + 16 + 32) `div` 8

ofpHelloRequest :: Word8 -> Word32 -> PutM ()
ofpHelloRequest v xid = putMessageHeader h >> return ()
  where h = OfpHeader { ofp_hdr_version   = v
                      , ofp_hdr_type      = OFPT_HELLO
                      , ofp_packet_length = Nothing
                      , ofp_hdr_xid       = xid
                      }

header :: Word8 -> Word32 -> OfpType -> OfpHeader
header v x t = OfpHeader v t Nothing x

featuresReply :: Word8 -> OfpSwitchFeatures -> Word32 -> OfpMessage
featuresReply ov sw xid = OfpMessage hdr feature_repl
  where hdr = header ov xid OFPT_FEATURES_REPLY
        feature_repl = OfpFeaturesReply sw

echoReply :: Word8 -> ByteString -> Word32 -> OfpMessage
echoReply ov payload xid = OfpMessage hdr (OfpEchoReply payload)
  where hdr = header ov xid OFPT_ECHO_REPLY

headReply :: OfpHeader -> OfpType -> OfpMessage
headReply h t = OfpMessage newHead OfpEmptyReply
  where newHead = h {ofp_hdr_type = t, ofp_packet_length = Nothing}

errorReply :: OfpHeader -> OfpError -> OfpMessage
errorReply h tp = OfpMessage newHead (OfpErrorReply tp)
  where newHead = h { ofp_hdr_type = OFPT_ERROR, ofp_packet_length = Nothing}

getConfigReply :: OfpHeader -> OfpSwitchConfig -> OfpMessage
getConfigReply hdr cfg = OfpMessage newHead (OfpGetConfigReply cfg)
  where newHead = hdr { ofp_hdr_type = OFPT_GET_CONFIG_REPLY, ofp_packet_length = Nothing }


descStatsReply :: OfpHeader -> OfpMessage
descStatsReply h = OfpMessage sHead sData
  where sHead = h { ofp_hdr_type = OFPT_STATS_REPLY
                  , ofp_packet_length = Nothing
                  }
        sData = OfpStatsReply (OfpDescriptionStatsReply
                               "ARCCN"   -- Manufacturer description
                               "hcprobe" -- Hardware description
                               "hcprobe" -- Software description
                               "none"    -- Serial number
                               "none"    -- Human readable description of datapath
                              )


{-
ofpParseHeader :: Get OfpHeader
ofpParseHeader = do
    v   <- getWord8
    tp  <- getWord8
    len <- getWord16be
    xid <- getWord32be
    -- FIXME: enum code overflow
    return $ OfpHeader v (toEnum (fromIntegral tp)) len xid
-}


instance Binary OfpHeader where
  put _ = error "put message is not implemented" -- FIXME support method?
  get = OfpHeader <$> getWord8
                  <*> (toEnum . fromIntegral <$> getWord8)
                  <*> (Just . fromIntegral <$> getWord16be)
                  <*> getWord32be

instance Binary OfpMessage where
  put _ = error "put message is not supported" -- FIXME support method ?
  get = do hdr <- get
           case ofp_packet_length hdr of
             Just l -> do
               s <- getLazyByteString (fromIntegral l - fromIntegral ofpHeaderLen)
               let body = runGet (getMessage (ofp_hdr_type hdr)) s
               return (OfpMessage hdr body)
             Nothing -> error "unspecified OF packet length"

getMessage :: OfpType -> Get OfpMessageData
getMessage x = case x of
                 !OFPT_HELLO -> return OfpHello
                 !OFPT_FEATURES_REQUEST   -> return OfpFeaturesRequest
                 !OFPT_ECHO_REQUEST       -> OfpEchoRequest . bsStrict <$> getRemainingLazyByteString
                 !OFPT_SET_CONFIG         -> OfpSetConfig  <$>
                                               (OfpSwitchConfig <$> (toEnum . fromIntegral <$> getWord16be)
                                                                <*> getWord16be)
                 !OFPT_GET_CONFIG_REQUEST -> return (OfpGetConfigRequest)
                 !OFPT_PACKET_OUT         -> do bid  <- getWord32be
                                                pid  <- getWord16be
                                                alen <- getWord16be
                                                skip (fromIntegral alen)
                                                return (OfpPacketOut (OfpPacketOutData bid pid))
                 !OFPT_FLOW_MOD           -> OfpFlowMod <$> get
                 !OFPT_VENDOR             -> OfpVendor . bsStrict <$> getRemainingLazyByteString
                 !OFPT_STATS_REQUEST      -> do s <- getWord16be
                                                case toEnum (fromEnum s) of
                                                   OFPST_DESC -> return (OfpStatsRequest OfpDescriptionStatsRequest)
                                                   _ -> return (OfpUnsupported BS.empty)
                 x                        -> OfpUnsupported .bsStrict <$> getRemainingLazyByteString
-- getMessage !OFPT_FLOW_MOD           = OfpFlowMod . bsStrict <$> getRemainingLazyByteString
-- getMessage _                        = OfpUnsupported .bsStrict <$> getRemainingLazyByteString

{-
parseMessageData :: OfpMessage -> Maybe OfpMessage
parseMessageData (OfpMessage hdr (OfpMessageRaw bs)) = parse (ofp_hdr_type hdr)
  where
    parse OFPT_HELLO            = runParse (return OfpHello)
    parse OFPT_FEATURES_REQUEST = runParse (return OfpFeaturesRequest)
    parse OFPT_ECHO_REQUEST     = runParse (return (OfpEchoRequest bs))
    parse OFPT_SET_CONFIG       = runParse getOfpSetConfig
    parse OFPT_GET_CONFIG_REQUEST = runParse (return OfpGetConfigRequest)
    parse OFPT_PACKET_OUT       = runParse getPacketOut
    parse OFPT_VENDOR           = runParse (return (OfpVendor bs))
    parse OFPT_STATS_REQUEST    = runParse getStatsRequest
    parse _                     = runParse (return (OfpUnsupported bs))

    runParse fGet =
      case (runGet fGet bs) of
        (Left _, _)  -> Nothing
        (Right x, _) -> Just ((OfpMessage hdr) x)

parseMessageData x@(OfpMessage _ _) = Just x -- already parsed
-}

{-
getOfpSetConfig :: Get OfpMessageData
getOfpSetConfig = do
  wFlags <- getWord16be
  wSendL <- getWord16be
                             -- FIXME: possible enum overflow
  return $ OfpSetConfig $ OfpSwitchConfig { ofp_switch_cfg_flags = toEnum (fromIntegral wFlags)
                                          , ofp_switch_cfg_miss_send_len = wSendL
                                          }
-}

{-
getPacketOut :: Get OfpMessageData
getPacketOut = do
  bid  <- getWord32be
  pid  <- getWord16be
  alen <- getWord16be
  skip (fromIntegral alen)
  return $ OfpPacketOut (OfpPacketOutData bid pid)
-}

{-
getStatsRequest :: Get OfpMessageData
getStatsRequest  = do
  stype <- getWord16be
  case stype of
    0 -> return (OfpStatsRequest OFPST_DESC)
    _ -> return (OfpUnsupported (BS.empty))
-}

putMessage :: OfpMessage -> PutM ()
putMessage (OfpMessage h d) = do
    ds <- marker  -- запомнили где старт сообщения
    alen <- putMessageHeader h
    putMessageData d
    case ofp_packet_length h of
      Nothing -> undelay alen . Word16be . fromIntegral =<< distance ds
      Just x -> undelay alen (Word16be x)

putMessageHeader :: OfpHeader -> PutM (DelayedPut Word16be)
putMessageHeader h = do
    putWord8 version
    putWord8 tp
    x <- delayedWord16be
    putWord32be xid
    return x
  where version = ofp_hdr_version h
        tp      = (fromIntegral.fromEnum.ofp_hdr_type) h
        {-
        tolen :: Word16 -> Word16
        tolen x = ofp_hdr_length h + x
        -}
        xid     = ofp_hdr_xid h


putMessageData :: OfpMessageData -> PutM ()
putMessageData OfpHello = return ()

putMessageData (OfpFeaturesReply f) = do
  putWord64be (ofp_switch_features_datapath_id f)
  putWord32be (ofp_switch_features_n_buffers f)
  putWord8    (ofp_switch_features_n_tables f)
  replicateM_ 3 (putWord8 0)
  putWord32be (ofp_switch_features_capabilities f)
  putWord32be (ofp_switch_features_actions f)
  mapM_ putOfpPort (ofp_switch_features_ports f)

putMessageData (OfpEchoReply bs) = putByteString bs

putMessageData (OfpGetConfigReply cfg) = do
  putWord16be (fromIntegral (fromEnum (ofp_switch_cfg_flags cfg)))
  putWord16be (ofp_switch_cfg_miss_send_len cfg)

putMessageData (OfpErrorReply et) = do
  putWord16be (fromIntegral $ ofErrorType (ofp_error_type et))
  putWord16be (fromIntegral $ ofErrorCode (ofp_error_type et))
  putByteString (BS.take 64 (ofp_error_data et))

putMessageData OfpEmptyReply = return ()

putMessageData (OfpPacketInReply p) = putOfpPacketIn p

--struct ofp_stats_reply {
--    struct ofp_header header;
--    uint16_t type;              /* One of the OFPST_* constants. */
--    uint16_t flags;             /* OFPSF_REPLY_* flags. */
--    uint8_t body[0];            /* Body of the reply. */
--};
--OFP_ASSERT(sizeof(struct ofp_stats_reply) == 12);

-- #define DESC_STR_LEN   256
-- #define SERIAL_NUM_LEN 32
-- /* Body of reply to OFPST_DESC request.  Each entry is a NULL-terminated
-- * ASCII string. */
--struct ofp_desc_stats {
--    char mfr_desc[DESC_STR_LEN];       /* Manufacturer description. */
--    char hw_desc[DESC_STR_LEN];        /* Hardware description. */
--    char sw_desc[DESC_STR_LEN];        /* Software description. */
--    char serial_num[SERIAL_NUM_LEN];   /* Serial number. */
--    char dp_desc[DESC_STR_LEN];        /* Human readable description of datapath. */
--};
--OFP_ASSERT(sizeof(struct ofp_desc_stats) == 1056);
putMessageData (OfpStatsReply rep) = do
    putWord16be (fromIntegral . fromEnum . statsReplyToType $ rep)
    putWord16be 0
    case rep of
      OfpDescriptionStatsReply{..} -> do
          putASCIIZ 256 ofp_desc_stats_rep_mfr
          putASCIIZ 256 ofp_desc_stats_rep_hw
          putASCIIZ 256 ofp_desc_stats_rep_sw
          putASCIIZ 32  ofp_desc_stats_rep_serial_num
          putASCIIZ 256 ofp_desc_stats_rep_dp
      OfpFlowStatsReply{..} -> do
          putWord8 ofp_flow_stats_rep_table_id
          putOfpMatch ofp_flow_stats_rep_match
          putWord32be ofp_flow_stats_rep_duration_sec
          putWord32be ofp_flow_stats_rep_duration_nsec
          putWord16be ofp_flow_stats_rep_priority
          putWord16be ofp_flow_stats_rep_idle_timeout
          putWord16be ofp_flow_stats_rep_hard_timeout
          putWord64be ofp_flow_stats_rep_cookie
          putWord64be ofp_flow_stats_rep_packet_count
          putWord64be ofp_flow_stats_rep_byte_count
          putByteString ofp_flow_stats_rep_actions -- ^ TOFIX
      OfpAggregateStatsReply{..} -> do
          putWord64be ofp_aggregate_stats_rep_packet_count
          putWord64be ofp_aggregate_stats_rep_byte_count
          putWord32be ofp_aggregate_stats_rep_flow_count
          putZeros 4
      OfpTableStatsReply{..} -> do
          putWord8 ofp_table_stats_rep_table_id
          putZeros 3
          putASCIIZ 32 ofp_table_stats_rep_name
          putWord32be ofp_table_stats_rep_wildcards
          putWord32be ofp_table_stats_rep_max_entries
          putWord32be ofp_table_stats_rep_active_count
          putWord64be ofp_table_stats_rep_lookup_count
          putWord64be ofp_table_stats_rep_matched_count
      OfpPortStatsReply portStats -> forM_ portStats $ \OfpPortStats{..} -> do
          putWord16be ofp_port_stats_port_no
          putZeros 6
          putWord64be ofp_port_stats_rx_packets
          putWord64be ofp_port_stats_tx_packets
          putWord64be ofp_port_stats_rx_bytes
          putWord64be ofp_port_stats_tx_bytes
          putWord64be ofp_port_stats_rx_dropped
          putWord64be ofp_port_stats_tx_dropped
          putWord64be ofp_port_stats_rx_errors
          putWord64be ofp_port_stats_tx_errors
          putWord64be ofp_port_stats_rx_frame_err
          putWord64be ofp_port_stats_rx_over_err
          putWord64be ofp_port_stats_rx_crc_err
          putWord64be ofp_port_stats_collisions
      OfpQueueStatsReply{..} -> do
          putWord16be ofp_queue_stats_rep_port_no
          putZeros 2
          putWord32be ofp_queue_stats_rep_queue_id
          putWord64be ofp_queue_stats_rep_tx_bytes
          putWord64be ofp_queue_stats_rep_tx_packets
          putWord64be ofp_queue_stats_rep_tx_errors
      OfpVendorStatsReply bs ->
          putByteString bs

putMessageData (OfpFlowRemoved OfpFlowRemovedData{..}) = do
    putWord64be ofp_flow_removed_cookie
    putWord16be ofp_flow_removed_priority
    putWord8 (fromIntegral $ fromEnum ofp_flow_removed_reason)
    putWord8 ofp_flow_removed_table_id
    putWord32be ofp_flow_removed_duration_sec
    putWord32be ofp_flow_removed_duration_nsec
    putWord16be ofp_flow_removed_idle_timeout
    putWord16be ofp_flow_removed_hard_timeout
    putWord64be ofp_flow_removed_packet_count
    putWord64be ofp_flow_removed_byte_count
    putOfpMatch ofp_flow_removed_match

putMessageData (OfpPortStatus (OfpPortStatusData reason data_)) = do
    putWord8 . fromIntegral . fromEnum $ reason
    putZeros 7
    putOfpPort data_

putMessageData (OfpQueueGetConfigReply OfpQueueConfig{..}) = do
    putWord16be ofp_queue_config_port
    putZeros 6 -- padding
    forM_ ofp_queue_config_queues $ \OfpPacketQueue{..} -> do
        x <- marker
        putWord32be opq_queue_id
        qlen <- delayedWord16be
        putZeros 2
        forM_ opq_properties $ \prop ->
            case prop of
                OfpQueuePropertyNone -> do
                    putWord16be 0 -- OFPQT_NONE
                    putWord16be 8
                    putZeros 4    -- padding
                OfpQueuePropertyMinRate{..} -> do
                    putWord16be 1 -- OFPQT_MIN_RATE
                    putWord16be 16
                    putZeros 4    -- padding
                    putWord16be oqp_rate
                    putZeros 6   -- padding
        undelay qlen . Word16be . fromIntegral =<< distance x

putMessageData (OfpMessageRaw x) = putByteString x
-- FIXME: typed error handling
--putMessageData _        = error "Unsupported message: "

buildMessage :: OfpMessage -> Builder
buildMessage (OfpMessage h d) =
        buildMessageHeader h dsize <> fromLazyByteString dat
      where dat   = toLazyByteString (buildMessageData d)
            dsize = fromIntegral $! LBS.length dat

buildMessageHeader :: OfpHeader -> Int -> Builder
buildMessageHeader h l = fromWord8 (ofp_hdr_version h)
          <> fromWord8 (fromIntegral.fromEnum.ofp_hdr_type $! h)
          <> fromWord16be (fromIntegral ofpHeaderLen + fromIntegral l)
          <> fromWord32be (ofp_hdr_xid h)

buildMessageData :: OfpMessageData -> Builder
buildMessageData OfpHello = mempty
buildMessageData (OfpFeaturesReply f) =
        fromWord64be (ofp_switch_features_datapath_id f)  <>
        fromWord32be (ofp_switch_features_n_buffers   f)  <>
        fromWord8    (ofp_switch_features_n_tables    f)  <>
        fromWord8 0 <> fromWord8 0 <> fromWord8 0 <>
        fromWord32be (ofp_switch_features_capabilities f) <>
        fromWord32be (ofp_switch_features_actions f)      <>
        foldl (\x y -> x <> buildOfpPort y) mempty (ofp_switch_features_ports f)
buildMessageData (OfpEchoReply bs) = fromByteString bs
buildMessageData (OfpGetConfigReply cfg) =
        fromWord16be (fromIntegral (fromEnum (ofp_switch_cfg_flags cfg)))
        <> fromWord16be (ofp_switch_cfg_miss_send_len cfg)
buildMessageData (OfpErrorReply et) =
        fromWord16be (fromIntegral (ofErrorType (ofp_error_type et)))
        <> fromWord16be (fromIntegral (ofErrorCode (ofp_error_type et)))
        <> fromByteString (BS.take 64 (ofp_error_data et))
buildMessageData OfpEmptyReply = mempty
buildMessageData (OfpPacketInReply p) = buildOfpPacketIn p
buildMessageData (OfpStatsReply rep) =
     fromWord16be (fromIntegral . fromEnum . statsReplyToType $ rep)
     <> fromWord16be 0
     <> case rep of
          OfpDescriptionStatsReply{..} ->
              buildASCIIZ 256 ofp_desc_stats_rep_mfr
              <> buildASCIIZ 256 ofp_desc_stats_rep_hw
              <> buildASCIIZ 256 ofp_desc_stats_rep_sw
              <> buildASCIIZ 32  ofp_desc_stats_rep_serial_num
              <> buildASCIIZ 256 ofp_desc_stats_rep_dp

putOfpPort :: OfpPhyPort -> PutM ()
putOfpPort port = do
  putWord16be (ofp_port_no port)                                                            -- 2
  mapM_ putWord8 (drop 2 (unpack64 (ofp_port_hw_addr port)))                                -- 8
  putASCIIZ 16 (ofp_port_name port)    -- ASCIIZ(16)
  putWord32be $ ofp_port_config port      --(bitFlags ofConfigFlags (ofp_port_config port))
  putWord32be $ ofp_port_state port       --(bitFlags ofStateFlags (ofp_port_state port))
  putWord32be $ ofp_port_current port     --(bitFlags ofFeatureFlags (ofp_port_current port))
  putWord32be $ ofp_port_advertised port  --(bitFlags ofFeatureFlags (ofp_port_advertised port))
  putWord32be $ ofp_port_supported port   --(bitFlags ofFeatureFlags (ofp_port_supported port))
  putWord32be $ ofp_port_peer port        --(bitFlags ofFeatureFlags (ofp_port_peer port))

buildOfpPort :: OfpPhyPort -> Builder
buildOfpPort port = do
  fromWord16be (ofp_port_no port)
  <> (foldl (\x y -> x <> fromWord8 y) mempty (drop 2 (unpack64 (ofp_port_hw_addr port))))
  <> buildASCIIZ 16 (ofp_port_name port)
  <> fromWord32be (ofp_port_config port)      --(bitFlags ofConfigFlags (ofp_port_config port))
  <> fromWord32be (ofp_port_state port)       --(bitFlags ofStateFlags (ofp_port_state port))
  <> fromWord32be (ofp_port_current port)     --(bitFlags ofFeatureFlags (ofp_port_current port))
  <> fromWord32be (ofp_port_advertised port)  --(bitFlags ofFeatureFlags (ofp_port_advertised port))
  <> fromWord32be (ofp_port_supported port)   --(bitFlags ofFeatureFlags (ofp_port_supported port))
  <> fromWord32be (ofp_port_peer port)        --(bitFlags ofFeatureFlags (ofp_port_peer port))

putOfpPacketIn :: OfpPacketIn -> PutM ()
putOfpPacketIn pktIn = do
  putWord32be (ofp_pkt_in_buffer_id pktIn)
  al <- delayedWord16be
  putWord16be (ofp_pkt_in_in_port pktIn)
  putWord8    (fromIntegral $ fromEnum (ofp_pkt_in_reason pktIn))
  putWord8    0 -- padding
  x <- marker
  ofp_pkt_in_data pktIn
  undelay al . fromIntegral =<< distance x

buildOfpPacketIn :: OfpPacketIn -> Builder
buildOfpPacketIn pktIn =
      fromWord32be (ofp_pkt_in_buffer_id pktIn)
      <> fromWord16be (fromIntegral len)
      <> fromWord16be (ofp_pkt_in_in_port pktIn)
      <> fromWord8    (fromIntegral $ fromEnum (ofp_pkt_in_reason pktIn))
      <> fromWord8 0
      <> fromLazyByteString dat
  where
      -- FIXME: use only bytestring stuff
      dat = toLazyByteString $! fromByteString (runPutToByteString 32768 (ofp_pkt_in_data pktIn))
      len = LBS.length dat

putOfpMatch :: OfpMatch -> PutM ()
putOfpMatch OfpMatch{..} = do
    putWord32be ofp_match_wildcards
    putWord16be ofp_match_in_ports
    putWord64be ofp_match_dl_src
    putWord64be ofp_match_dl_dst
    putWord16be ofp_match_dl_vlan
    putWord8 ofp_match_dl_vlan_pcp
    putWord16be ofp_match_dl_type
    putWord8 ofp_match_nw_tos
    putWord8 ofp_match_nw_proto
    putWord32be ofp_match_nw_src
    putWord32be ofp_match_nw_dst
    putWord16be ofp_match_tp_src
    putWord16be ofp_match_tp_dst
