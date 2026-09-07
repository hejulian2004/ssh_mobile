use std::collections::VecDeque;
use std::time::Instant;

use thiserror::Error;

/// Maximum accepted encoded H.264 access-unit size.
pub const MAX_ENCODED_VIDEO_FRAME_BYTES: usize = 4 * 1024 * 1024;
/// The screen-video transport queue is intentionally independent from generic
/// `MediaQos` and is never allowed to grow beyond this number of frames.
pub const SCREEN_VIDEO_QUEUE_CAPACITY: usize = 3;
pub const MAX_SCREEN_VIDEO_WIDTH: u32 = 7_680;
pub const MAX_SCREEN_VIDEO_HEIGHT: u32 = 4_320;
pub const MAX_SCREEN_VIDEO_PIXELS: u64 =
    MAX_SCREEN_VIDEO_WIDTH as u64 * MAX_SCREEN_VIDEO_HEIGHT as u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    H264,
    Vp8,
    Av1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoFrameMetadata {
    pub sequence: u64,
    pub timestamp: u64,
    pub width: u32,
    pub height: u32,
    pub keyframe: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedVideoFrame {
    pub codec: VideoCodec,
    pub sequence: u64,
    pub timestamp: u64,
    pub width: u32,
    pub height: u32,
    pub keyframe: bool,
    pub payload: Vec<u8>,
    pub expires_at: Instant,
}

impl EncodedVideoFrame {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        codec: VideoCodec,
        sequence: u64,
        timestamp: u64,
        width: u32,
        height: u32,
        keyframe: bool,
        payload: Vec<u8>,
        expires_at: Instant,
    ) -> Self {
        Self {
            codec,
            sequence,
            timestamp,
            width,
            height,
            keyframe,
            payload,
            expires_at,
        }
    }

    pub const fn metadata(&self) -> VideoFrameMetadata {
        VideoFrameMetadata {
            sequence: self.sequence,
            timestamp: self.timestamp,
            width: self.width,
            height: self.height,
            keyframe: self.keyframe,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoEnqueueResult {
    Accepted,
    AcceptedAfterDropping { count: usize },
    DroppedIncoming,
    DroppedStale,
}

#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
pub enum VideoFrameError {
    #[error("screen video only supports H.264, not {0:?}")]
    UnsupportedCodec(VideoCodec),
    #[error("encoded screen-video frame is empty")]
    EmptyPayload,
    #[error("encoded screen-video frame exceeds the 4 MiB limit")]
    PayloadTooLarge,
    #[error("encoded screen-video frame is not Annex-B H.264")]
    InvalidAccessUnit,
    #[error("screen-video timestamp cannot be represented by RTP")]
    TimestampOutOfRange,
    #[error("screen-video resolution is invalid or exceeds the native limit")]
    InvalidResolution,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyframeRequestReason {
    Disconnected,
    DecoderReset,
    IceRestart,
    PacketLoss,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct VideoMediaStats {
    pub enqueued: u64,
    pub dequeued: u64,
    pub dropped_stale: u64,
    pub dropped_overflow: u64,
    pub dropped_unsafe_delta: u64,
    pub dropped_on_disconnect: u64,
    pub keyframe_requests: u64,
}

/// A native-only, keyframe-aware screen-video queue.
///
/// It never changes the generic four-frame media QoS policy. A new screen
/// session receives a new queue, and disconnect clears all pending content.
pub struct VideoQueue {
    frames: VecDeque<EncodedVideoFrame>,
    last_sequence: Option<u64>,
    last_timestamp: Option<u64>,
    pending_keyframe_request: Option<KeyframeRequestReason>,
    stats: VideoMediaStats,
}

impl Default for VideoQueue {
    fn default() -> Self {
        Self::new()
    }
}

impl VideoQueue {
    pub fn new() -> Self {
        Self {
            frames: VecDeque::with_capacity(SCREEN_VIDEO_QUEUE_CAPACITY),
            last_sequence: None,
            last_timestamp: None,
            pending_keyframe_request: None,
            stats: VideoMediaStats::default(),
        }
    }

    pub fn enqueue(
        &mut self,
        frame: EncodedVideoFrame,
        now: Instant,
    ) -> Result<VideoEnqueueResult, VideoFrameError> {
        Self::validate_frame(&frame)?;
        self.evict_stale(now);
        if frame.expires_at <= now {
            self.stats.dropped_stale = self.stats.dropped_stale.saturating_add(1);
            return Ok(VideoEnqueueResult::DroppedStale);
        }

        if self.is_non_monotonic(&frame) {
            self.stats.dropped_unsafe_delta = self.stats.dropped_unsafe_delta.saturating_add(1);
            return Ok(VideoEnqueueResult::DroppedIncoming);
        }

        let mut dropped = 0;
        if frame.keyframe {
            dropped = self.frames.len();
            self.frames.clear();
        } else if self.frames.len() >= SCREEN_VIDEO_QUEUE_CAPACITY {
            if let Some(index) = self.frames.iter().position(|queued| !queued.keyframe) {
                self.frames.remove(index);
                dropped = 1;
            } else {
                self.stats.dropped_unsafe_delta = self.stats.dropped_unsafe_delta.saturating_add(1);
                return Ok(VideoEnqueueResult::DroppedIncoming);
            }
        }

        if dropped != 0 {
            self.stats.dropped_overflow =
                self.stats.dropped_overflow.saturating_add(dropped as u64);
        }
        self.last_sequence = Some(frame.sequence);
        self.last_timestamp = Some(frame.timestamp);
        self.frames.push_back(frame);
        self.stats.enqueued = self.stats.enqueued.saturating_add(1);
        Ok(if dropped == 0 {
            VideoEnqueueResult::Accepted
        } else {
            VideoEnqueueResult::AcceptedAfterDropping { count: dropped }
        })
    }

    pub fn pop(&mut self, now: Instant) -> Option<EncodedVideoFrame> {
        self.evict_stale(now);
        let frame = self.frames.pop_front()?;
        self.stats.dequeued = self.stats.dequeued.saturating_add(1);
        Some(frame)
    }

    pub fn on_disconnect(&mut self) {
        self.stats.dropped_on_disconnect = self
            .stats
            .dropped_on_disconnect
            .saturating_add(self.frames.len() as u64);
        self.frames.clear();
        self.last_sequence = None;
        self.last_timestamp = None;
        self.request_keyframe(KeyframeRequestReason::Disconnected);
    }

    pub fn on_decoder_reset(&mut self) {
        self.stats.dropped_on_disconnect = self
            .stats
            .dropped_on_disconnect
            .saturating_add(self.frames.len() as u64);
        self.frames.clear();
        self.last_sequence = None;
        self.last_timestamp = None;
        self.pending_keyframe_request = None;
        self.request_keyframe(KeyframeRequestReason::DecoderReset);
    }

    /// Clears all queued media and ordering state without requesting a
    /// keyframe. Endpoint release uses this neutral reset so a later lease on
    /// the same native peer can never observe frames or sequence constraints
    /// belonging to the released lease.
    pub fn clear(&mut self) {
        self.frames.clear();
        self.last_sequence = None;
        self.last_timestamp = None;
        self.pending_keyframe_request = None;
    }

    pub fn request_keyframe(&mut self, reason: KeyframeRequestReason) {
        if self.pending_keyframe_request.is_none() {
            self.pending_keyframe_request = Some(reason);
            self.stats.keyframe_requests = self.stats.keyframe_requests.saturating_add(1);
        }
    }

    pub fn take_keyframe_request(&mut self) -> Option<KeyframeRequestReason> {
        self.pending_keyframe_request.take()
    }

    pub fn len(&self) -> usize {
        self.frames.len()
    }

    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }

    pub const fn stats(&self) -> VideoMediaStats {
        self.stats
    }

    fn validate_frame(frame: &EncodedVideoFrame) -> Result<(), VideoFrameError> {
        if frame.codec != VideoCodec::H264 {
            return Err(VideoFrameError::UnsupportedCodec(frame.codec));
        }
        if frame.payload.is_empty() {
            return Err(VideoFrameError::EmptyPayload);
        }
        if frame.payload.len() > MAX_ENCODED_VIDEO_FRAME_BYTES {
            return Err(VideoFrameError::PayloadTooLarge);
        }
        if frame.timestamp > u64::from(u32::MAX) {
            return Err(VideoFrameError::TimestampOutOfRange);
        }
        let pixels = u64::from(frame.width) * u64::from(frame.height);
        if frame.width == 0
            || frame.height == 0
            || frame.width > MAX_SCREEN_VIDEO_WIDTH
            || frame.height > MAX_SCREEN_VIDEO_HEIGHT
            || pixels > MAX_SCREEN_VIDEO_PIXELS
        {
            return Err(VideoFrameError::InvalidResolution);
        }
        if !is_valid_annex_b(&frame.payload) {
            return Err(VideoFrameError::InvalidAccessUnit);
        }
        Ok(())
    }

    fn is_non_monotonic(&self, frame: &EncodedVideoFrame) -> bool {
        self.last_sequence
            .is_some_and(|last| frame.sequence <= last)
            || self
                .last_timestamp
                .is_some_and(|last| frame.timestamp <= last)
    }

    fn evict_stale(&mut self, now: Instant) {
        while self
            .frames
            .front()
            .is_some_and(|frame| frame.expires_at <= now)
        {
            self.frames.pop_front();
            self.stats.dropped_stale = self.stats.dropped_stale.saturating_add(1);
        }
    }
}

/// Validates the minimum Annex-B structure required by the H.264 RTP
/// payloader. A start code by itself is not an access unit: every NALU must
/// have a non-zero NAL type and at least one byte after its start code.
pub(crate) fn is_valid_annex_b(payload: &[u8]) -> bool {
    let mut index = 0;
    let mut found_nalu = false;
    while index < payload.len() {
        let Some((start, start_code_len)) = next_start_code(payload, index) else {
            return false;
        };
        let nalu_start = start + start_code_len;
        if nalu_start >= payload.len() {
            return false;
        }
        let nalu_end = next_start_code(payload, nalu_start)
            .map_or(payload.len(), |(next_start, _)| next_start);
        if nalu_end <= nalu_start || payload[nalu_start] & 0x1f == 0 {
            return false;
        }
        found_nalu = true;
        index = nalu_end;
    }
    found_nalu
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
