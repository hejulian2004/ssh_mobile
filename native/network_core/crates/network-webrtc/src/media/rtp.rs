use std::time::{Duration, Instant};

use bytes::{Bytes, BytesMut};
use rtc::rtp::codec::h264::{
    H264Packet, H264Payloader, FUA_HEADER_SIZE, FUA_NALU_TYPE, NALU_TYPE_BITMASK,
    STAPA_NALU_LENGTH_SIZE, STAPA_NALU_TYPE,
};
use rtc::rtp::packetizer::{Depacketizer, Payloader};
use rtc::rtp::{Header, Packet};
use thiserror::Error;

use super::{
    queue::is_valid_annex_b, EncodedVideoFrame, VideoCodec, MAX_ENCODED_VIDEO_FRAME_BYTES,
    MAX_SCREEN_VIDEO_HEIGHT, MAX_SCREEN_VIDEO_WIDTH,
};

const RTP_HEADER_BYTES: usize = 12;
const DEFAULT_REMOTE_WIDTH: u32 = 1_920;
const DEFAULT_REMOTE_HEIGHT: u32 = 1_080;
const RECEIVED_FRAME_TTL: Duration = Duration::from_millis(250);

#[derive(Debug, Error)]
pub enum RtpMediaError {
    #[error("RTP MTU must leave room for an RTP header and H.264 payload")]
    InvalidMtu,
    #[error("only H.264 encoded frames can be packetized")]
    UnsupportedCodec,
    #[error("encoded frame must be Annex-B H.264 and fit the native limit")]
    InvalidAccessUnit,
    #[error("frame timestamp cannot be represented by RTP")]
    TimestampOutOfRange,
    #[error("H.264 payloading failed: {0}")]
    Payloading(String),
    #[error("malformed H.264 RTP payload")]
    MalformedPayload,
    #[error("RTP packet sequence or timestamp is stale or discontinuous")]
    StaleOrDiscontinuous,
    #[error("reassembled H.264 access unit exceeds the native limit")]
    ReassembledFrameTooLarge,
}

/// RFC 6184 packetizer for native Annex-B H.264 access units.
pub struct RtpPacketizer {
    mtu: usize,
    payload_type: u8,
    ssrc: u32,
    next_sequence_number: u16,
    payloader: H264Payloader,
}

impl RtpPacketizer {
    pub fn new(mtu: usize, payload_type: u8, ssrc: u32, initial_sequence: u16) -> Self {
        Self {
            mtu,
            payload_type,
            ssrc,
            next_sequence_number: initial_sequence,
            payloader: H264Payloader::default(),
        }
    }

    pub fn packetize(&mut self, frame: &EncodedVideoFrame) -> Result<Vec<Packet>, RtpMediaError> {
        if self.mtu <= RTP_HEADER_BYTES + FUA_HEADER_SIZE {
            return Err(RtpMediaError::InvalidMtu);
        }
        if frame.codec != VideoCodec::H264 {
            return Err(RtpMediaError::UnsupportedCodec);
        }
        if frame.payload.is_empty()
            || frame.payload.len() > MAX_ENCODED_VIDEO_FRAME_BYTES
            || !is_valid_annex_b(&frame.payload)
        {
            return Err(RtpMediaError::InvalidAccessUnit);
        }
        let timestamp =
            u32::try_from(frame.timestamp).map_err(|_| RtpMediaError::TimestampOutOfRange)?;
        let payloads = self
            .payloader
            .payload(
                self.mtu - RTP_HEADER_BYTES,
                &Bytes::copy_from_slice(&frame.payload),
            )
            .map_err(|error| RtpMediaError::Payloading(error.to_string()))?;
        if payloads.is_empty() {
            return Err(RtpMediaError::InvalidAccessUnit);
        }

        let last = payloads.len() - 1;
        Ok(payloads
            .into_iter()
            .enumerate()
            .map(|(index, payload)| {
                let sequence_number = self.next_sequence_number;
                self.next_sequence_number = self.next_sequence_number.wrapping_add(1);
                Packet {
                    header: Header {
                        version: 2,
                        marker: index == last,
                        payload_type: self.payload_type,
                        sequence_number,
                        timestamp,
                        ssrc: self.ssrc,
                        ..Default::default()
                    },
                    payload,
                }
            })
            .collect())
    }
}

/// Stateful native reassembly of one H.264 RTP track.
pub struct RtpReassembler {
    depacketizer: H264Packet,
    pending_payload: BytesMut,
    pending_timestamp: Option<u32>,
    expected_sequence: Option<u16>,
    last_completed_timestamp: Option<u32>,
    next_frame_sequence: u64,
    width: u32,
    height: u32,
}

impl Default for RtpReassembler {
    fn default() -> Self {
        Self::new()
    }
}

impl RtpReassembler {
    pub fn new() -> Self {
        Self::with_dimensions(DEFAULT_REMOTE_WIDTH, DEFAULT_REMOTE_HEIGHT)
    }

    pub fn with_dimensions(width: u32, height: u32) -> Self {
        Self {
            depacketizer: H264Packet::default(),
            pending_payload: BytesMut::new(),
            pending_timestamp: None,
            expected_sequence: None,
            last_completed_timestamp: None,
            next_frame_sequence: 0,
            width: width.clamp(1, MAX_SCREEN_VIDEO_WIDTH),
            height: height.clamp(1, MAX_SCREEN_VIDEO_HEIGHT),
        }
    }

    pub fn push(&mut self, packet: &Packet) -> Result<Option<EncodedVideoFrame>, RtpMediaError> {
        self.push_at(packet, Instant::now())
    }

    pub fn push_at(
        &mut self,
        packet: &Packet,
        now: Instant,
    ) -> Result<Option<EncodedVideoFrame>, RtpMediaError> {
        if packet.header.version != 2 || !is_valid_h264_payload(&packet.payload) {
            self.reset_pending();
            return Err(RtpMediaError::MalformedPayload);
        }
        if let Some(completed) = self.last_completed_timestamp {
            if !is_newer_timestamp(packet.header.timestamp, completed) {
                self.reset_pending();
                return Err(RtpMediaError::StaleOrDiscontinuous);
            }
        }

        match self.pending_timestamp {
            Some(timestamp) if timestamp != packet.header.timestamp => {
                self.reset_pending();
                return Err(RtpMediaError::StaleOrDiscontinuous);
            }
            Some(_)
                if self
                    .expected_sequence
                    .is_some_and(|expected| expected != packet.header.sequence_number) =>
            {
                self.reset_pending();
                return Err(RtpMediaError::StaleOrDiscontinuous);
            }
            Some(_) => {}
            None => {
                self.pending_timestamp = Some(packet.header.timestamp);
            }
        }

        let payload = match self.depacketizer.depacketize(&packet.payload) {
            Ok(payload) => payload,
            Err(_) => {
                self.reset_pending();
                return Err(RtpMediaError::MalformedPayload);
            }
        };
        self.expected_sequence = Some(packet.header.sequence_number.wrapping_add(1));
        if self.pending_payload.len().saturating_add(payload.len()) > MAX_ENCODED_VIDEO_FRAME_BYTES
        {
            self.reset_pending();
            return Err(RtpMediaError::ReassembledFrameTooLarge);
        }
        self.pending_payload.extend_from_slice(&payload);

        if !packet.header.marker {
            return Ok(None);
        }
        if self.pending_payload.is_empty() {
            self.reset_pending();
            return Err(RtpMediaError::MalformedPayload);
        }

        let timestamp = self
            .pending_timestamp
            .expect("pending timestamp is set before depacketization");
        let payload = self.pending_payload.to_vec();
        let frame = EncodedVideoFrame::new(
            VideoCodec::H264,
            self.next_frame_sequence,
            u64::from(timestamp),
            self.width,
            self.height,
            contains_idr_nalu(&payload),
            payload,
            now + RECEIVED_FRAME_TTL,
        );
        self.next_frame_sequence = self.next_frame_sequence.wrapping_add(1);
        self.last_completed_timestamp = Some(timestamp);
        self.reset_pending();
        Ok(Some(frame))
    }

    pub fn reset(&mut self) {
        self.reset_pending();
        self.last_completed_timestamp = None;
    }

    /// Clears all receive ordering state for a released endpoint lease.
    ///
    /// A decoder reset may keep its logical frame sequence within one live
    /// endpoint, but a replacement lease starts a new generation and must not
    /// inherit the previous endpoint's output sequence.
    pub fn clear_for_endpoint_release(&mut self) {
        self.reset();
        self.next_frame_sequence = 0;
    }

    fn reset_pending(&mut self) {
        self.depacketizer = H264Packet::default();
        self.pending_payload.clear();
        self.pending_timestamp = None;
        self.expected_sequence = None;
    }
}

fn is_valid_h264_payload(payload: &Bytes) -> bool {
    let Some(&header) = payload.first() else {
        return false;
    };
    match header & NALU_TYPE_BITMASK {
        1..=23 => payload.len() > 1,
        FUA_NALU_TYPE => payload.len() >= FUA_HEADER_SIZE,
        STAPA_NALU_TYPE => {
            let mut offset = 1;
            while offset < payload.len() {
                if offset + STAPA_NALU_LENGTH_SIZE > payload.len() {
                    return false;
                }
                let nalu_size =
                    (usize::from(payload[offset]) << 8) | usize::from(payload[offset + 1]);
                offset += STAPA_NALU_LENGTH_SIZE;
                if nalu_size == 0 || offset + nalu_size > payload.len() {
                    return false;
                }
                offset += nalu_size;
            }
            offset == payload.len()
        }
        _ => false,
    }
}

fn contains_idr_nalu(payload: &[u8]) -> bool {
    let mut index = 0;
    while index < payload.len() {
        let Some((start, start_code_len)) = next_start_code(payload, index) else {
            break;
        };
        let nalu_start = start + start_code_len;
        if nalu_start < payload.len() && payload[nalu_start] & NALU_TYPE_BITMASK == 5 {
            return true;
        }
        index = nalu_start;
    }
    false
}

fn next_start_code(payload: &[u8], from: usize) -> Option<(usize, usize)> {
    let mut index = from;
    while index + 3 <= payload.len() {
        if payload[index..].starts_with(&[0, 0, 1]) {
            return Some((index, 3));
        }
        if index + 4 <= payload.len() && payload[index..].starts_with(&[0, 0, 0, 1]) {
            return Some((index, 4));
        }
        index += 1;
    }
    None
}

fn is_newer_timestamp(candidate: u32, previous: u32) -> bool {
    candidate != previous && candidate.wrapping_sub(previous) < (u32::MAX / 2 + 1)
}
