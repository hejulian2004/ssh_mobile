//! Bounded native H.264 screen-video primitives.
//!
//! This module deliberately contains encoded access units only. It has no Dart,
//! Relay, or DataChannel boundary, so high-frequency screen content remains in
//! the native WebRTC owner.

mod queue;
mod rtp;
mod video;

pub use queue::{
    EncodedVideoFrame, KeyframeRequestReason, VideoCodec, VideoEnqueueResult, VideoFrameError,
    VideoFrameMetadata, VideoMediaStats, VideoQueue, MAX_ENCODED_VIDEO_FRAME_BYTES,
    MAX_SCREEN_VIDEO_HEIGHT, MAX_SCREEN_VIDEO_PIXELS, MAX_SCREEN_VIDEO_WIDTH,
    SCREEN_VIDEO_QUEUE_CAPACITY,
};
pub use rtp::{RtpMediaError, RtpPacketizer, RtpReassembler};
pub(crate) use video::{h264_media_engine, H264ScreenVideo};
