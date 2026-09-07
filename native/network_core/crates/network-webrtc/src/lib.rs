//! Native-only WebRTC peer connection and bounded realtime media QoS.
//!
//! WebRTC remains a separate realtime subsystem. It owns SDP/ICE/DataChannel and
//! RTP media negotiation while generic TCP/UDP/WebSocket transports stay in the
//! `network-transport` crate. The FFI/client protocol is intentionally unchanged.

mod driver;
pub mod media;
mod peer;
mod qos;
mod signaling;

pub use driver::{
    run_realtime_io, RealtimeIoDriver, RealtimeIoDriverHandle, RealtimeIoEvent,
    REALTIME_IO_EVENT_CAPACITY,
};
pub use media::{
    EncodedVideoFrame, KeyframeRequestReason, VideoCodec, VideoEnqueueResult, VideoFrameError,
    VideoFrameMetadata, VideoMediaStats, VideoQueue, MAX_ENCODED_VIDEO_FRAME_BYTES,
    SCREEN_VIDEO_QUEUE_CAPACITY,
};
pub use peer::{
    DataChannelReliability, IceServerConfig, MediaDirection, WebRtcConfig, WebRtcError, WebRtcPeer,
    MAX_DATA_CHANNEL_PAYLOAD_BYTES,
};
pub use qos::{
    EnqueueResult, MediaFrame, MediaKind, MediaQos, MediaQosConfig, MediaQosPolicy, QosError,
    QosStats,
};
pub use signaling::{
    DescriptionType, IceCandidate, SessionDescription, SignalingError, SignalingState,
    SignalingStateMachine, MAX_ICE_CANDIDATE_BYTES, MAX_SDP_BYTES,
};

#[cfg(test)]
#[path = "tests/media.rs"]
mod media_tests;

#[cfg(test)]
#[path = "tests/rtp_media.rs"]
mod rtp_media_tests;

#[cfg(test)]
#[path = "tests/screen_video_peer.rs"]
mod screen_video_peer_tests;
