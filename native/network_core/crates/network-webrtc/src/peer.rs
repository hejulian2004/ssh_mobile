use std::time::Instant;

use bytes::BytesMut;
use rtc::data_channel::{RTCDataChannelId, RTCDataChannelInit};
use rtc::peer_connection::configuration::{
    RTCConfigurationBuilder, RTCIceServer, RTCIceTransportPolicy,
};
use rtc::peer_connection::event::RTCPeerConnectionEvent;
use rtc::peer_connection::message::RTCMessage;
use rtc::peer_connection::sdp::RTCSessionDescription;
use rtc::peer_connection::transport::RTCIceCandidateInit;
use rtc::peer_connection::{RTCPeerConnection, RTCPeerConnectionBuilder};
use rtc::rtp_transceiver::rtp_sender::{
    RTCRtpCodec, RTCRtpCodingParameters, RTCRtpEncodingParameters, RtpCodecKind,
};
use rtc::rtp_transceiver::{RTCRtpTransceiverDirection, RTCRtpTransceiverInit};
use rtc::sansio::Protocol;
use rtc::shared::TaggedBytesMut;

use crate::media::{h264_media_engine, H264ScreenVideo, RtpMediaError, VideoFrameError};
use crate::qos::{MediaFrame, MediaKind, MediaQos, MediaQosConfig};
use crate::signaling::{
    DescriptionType, IceCandidate, SessionDescription, SignalingError, SignalingState,
    SignalingStateMachine,
};

pub const MAX_DATA_CHANNEL_PAYLOAD_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IceServerConfig {
    pub urls: Vec<String>,
    pub username: Option<String>,
    pub credential: Option<String>,
}

impl IceServerConfig {
    pub fn stun(url: impl Into<String>) -> Self {
        Self {
            urls: vec![url.into()],
            username: None,
            credential: None,
        }
    }

    pub fn turn(
        url: impl Into<String>,
        username: impl Into<String>,
        credential: impl Into<String>,
    ) -> Self {
        Self {
            urls: vec![url.into()],
            username: Some(username.into()),
            credential: Some(credential.into()),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct WebRtcConfig {
    pub ice_servers: Vec<IceServerConfig>,
    /// Restrict ICE to TURN relay candidates.  This is used for privacy and
    /// for the direct-path-failure fallback test; the default keeps host and
    /// server-reflexive candidates enabled.
    pub relay_only: bool,
    pub qos: MediaQosConfig,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaDirection {
    Sendrecv,
    Sendonly,
    Recvonly,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DataChannelReliability {
    pub ordered: bool,
    pub max_packet_life_time: Option<u16>,
    pub max_retransmits: Option<u16>,
}

impl Default for DataChannelReliability {
    fn default() -> Self {
        Self {
            ordered: true,
            max_packet_life_time: None,
            max_retransmits: None,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum WebRtcError {
    #[error("WebRTC configuration is invalid: {0}")]
    InvalidConfiguration(String),
    #[error("WebRTC I/O failed: {0}")]
    Io(String),
    #[error("WebRTC operation failed: {0}")]
    Rtc(String),
    #[error(transparent)]
    Signaling(#[from] SignalingError),
    #[error("WebRTC data channel {0} does not exist")]
    DataChannelNotFound(RTCDataChannelId),
    #[error("WebRTC data channel payload exceeds the size limit")]
    DataChannelPayloadTooLarge,
    #[error("H.264 screen video has not been configured for this peer")]
    ScreenVideoNotConfigured,
    #[error("H.264 screen video cannot send until signaling negotiation is connected")]
    ScreenVideoNotReady,
    #[error("H.264 screen video is already configured for this peer")]
    ScreenVideoAlreadyConfigured,
    #[error(transparent)]
    VideoFrame(#[from] VideoFrameError),
    #[error(transparent)]
    RtpMedia(#[from] RtpMediaError),
}

pub struct WebRtcPeer {
    pub(crate) peer: RTCPeerConnection,
    pub(crate) signaling: SignalingStateMachine,
    qos: MediaQos,
    pub(crate) screen_video: Option<H264ScreenVideo>,
}

impl WebRtcPeer {
    pub fn new(config: WebRtcConfig) -> Result<Self, WebRtcError> {
        if config.ice_servers.len() > 8 {
            return Err(WebRtcError::InvalidConfiguration(
                "at most eight ICE servers are supported".into(),
            ));
        }

        let ice_servers = config
            .ice_servers
            .iter()
            .map(to_rtc_ice_server)
            .collect::<Result<Vec<_>, _>>()?;
        let media_engine = h264_media_engine()?;
        let mut configuration_builder =
            RTCConfigurationBuilder::new().with_ice_servers(ice_servers);
        if config.relay_only {
            configuration_builder =
                configuration_builder.with_ice_transport_policy(RTCIceTransportPolicy::Relay);
        }
        let configuration = configuration_builder.build();
        let peer = RTCPeerConnectionBuilder::new()
            .with_configuration(configuration)
            .with_media_engine(media_engine)
            .build()
            .map_err(rtc_error)?;

        Ok(Self {
            peer,
            signaling: SignalingStateMachine::default(),
            qos: MediaQos::from_config(config.qos),
            screen_video: None,
        })
    }

    pub fn signaling_state(&self) -> SignalingState {
        self.signaling.state()
    }

    pub fn signaling_revision(&self) -> u64 {
        self.signaling.revision()
    }

    pub fn create_offer(&mut self) -> Result<SessionDescription, WebRtcError> {
        let rtc_description = self.peer.create_offer(None).map_err(rtc_error)?;
        self.peer
            .set_local_description(rtc_description.clone())
            .map_err(rtc_error)?;
        let description = SessionDescription::new(DescriptionType::Offer, rtc_description.sdp)?;
        self.signaling.local_offer()?;
        Ok(description)
    }

    pub fn accept_remote_offer(
        &mut self,
        description: SessionDescription,
    ) -> Result<(), WebRtcError> {
        if description.kind != DescriptionType::Offer {
            return Err(WebRtcError::InvalidConfiguration(
                "remote offer must have type offer".into(),
            ));
        }
        let rtc_description = RTCSessionDescription::offer(description.sdp).map_err(rtc_error)?;
        self.peer
            .set_remote_description(rtc_description)
            .map_err(rtc_error)?;
        self.signaling.remote_offer()?;
        Ok(())
    }

    pub fn create_answer(&mut self) -> Result<SessionDescription, WebRtcError> {
        let rtc_description = self.peer.create_answer(None).map_err(rtc_error)?;
        self.peer
            .set_local_description(rtc_description.clone())
            .map_err(rtc_error)?;
        let description = SessionDescription::new(DescriptionType::Answer, rtc_description.sdp)?;
        self.signaling.local_answer()?;
        Ok(description)
    }

    pub fn accept_remote_answer(
        &mut self,
        description: SessionDescription,
    ) -> Result<(), WebRtcError> {
        if description.kind != DescriptionType::Answer {
            return Err(WebRtcError::InvalidConfiguration(
                "remote answer must have type answer".into(),
            ));
        }
        let rtc_description = RTCSessionDescription::answer(description.sdp).map_err(rtc_error)?;
        self.peer
            .set_remote_description(rtc_description)
            .map_err(rtc_error)?;
        self.signaling.remote_answer()?;
        Ok(())
    }

    pub fn add_remote_ice_candidate(&mut self, candidate: IceCandidate) -> Result<(), WebRtcError> {
        self.peer
            .add_remote_candidate(RTCIceCandidateInit {
                candidate: candidate.candidate,
                sdp_mid: candidate.sdp_mid,
                sdp_mline_index: candidate.sdp_mline_index,
                username_fragment: candidate.username_fragment,
                url: None,
            })
            .map_err(rtc_error)
    }

    /// Adds a locally bound host, server-reflexive, or relay candidate before
    /// an offer/answer is generated.  The sans-I/O rtc crate does not own a
    /// UDP socket, so its application-provided I/O driver must explicitly
    /// register the socket candidate.
    pub fn add_local_ice_candidate(&mut self, candidate: IceCandidate) -> Result<(), WebRtcError> {
        self.peer
            .add_local_candidate(RTCIceCandidateInit {
                candidate: candidate.candidate,
                sdp_mid: candidate.sdp_mid,
                sdp_mline_index: candidate.sdp_mline_index,
                username_fragment: candidate.username_fragment,
                url: None,
            })
            .map_err(rtc_error)
    }

    pub fn restart_ice(&mut self) -> Result<(), WebRtcError> {
        self.peer.restart_ice();
        self.signaling.restart()?;
        if let Some(video) = &mut self.screen_video {
            video.on_ice_restart();
        }
        Ok(())
    }

    pub fn add_media_transceiver(
        &mut self,
        kind: MediaKind,
        direction: MediaDirection,
        ssrc: Option<u32>,
    ) -> Result<(), WebRtcError> {
        self.add_media_transceiver_with_codec(kind, direction, ssrc, None)
    }

    pub(crate) fn add_media_transceiver_with_codec(
        &mut self,
        kind: MediaKind,
        direction: MediaDirection,
        ssrc: Option<u32>,
        codec: Option<RTCRtpCodec>,
    ) -> Result<(), WebRtcError> {
        let (codec_kind, rtc_direction) = match kind {
            MediaKind::Audio => (RtpCodecKind::Audio, direction),
            MediaKind::Video => (RtpCodecKind::Video, direction),
            MediaKind::DataChannel => {
                return Err(WebRtcError::InvalidConfiguration(
                    "DataChannel is not an RTP media transceiver".into(),
                ));
            }
        };
        let rtc_direction = match rtc_direction {
            MediaDirection::Sendrecv => RTCRtpTransceiverDirection::Sendrecv,
            MediaDirection::Sendonly => RTCRtpTransceiverDirection::Sendonly,
            MediaDirection::Recvonly => RTCRtpTransceiverDirection::Recvonly,
        };
        let send_encodings = if matches!(
            direction,
            MediaDirection::Sendrecv | MediaDirection::Sendonly
        ) {
            let ssrc = ssrc.ok_or_else(|| {
                WebRtcError::InvalidConfiguration(
                    "an SSRC is required for a sending media transceiver".into(),
                )
            })?;
            vec![RTCRtpEncodingParameters {
                rtp_coding_parameters: RTCRtpCodingParameters {
                    ssrc: Some(ssrc),
                    ..Default::default()
                },
                codec: codec.clone().unwrap_or_default(),
                ..Default::default()
            }]
        } else {
            Vec::new()
        };
        self.peer
            .add_transceiver_from_kind(
                codec_kind,
                Some(RTCRtpTransceiverInit {
                    direction: rtc_direction,
                    send_encodings,
                    ..Default::default()
                }),
            )
            .map(|_| ())
            .map_err(rtc_error)
    }

    pub fn create_data_channel(
        &mut self,
        label: &str,
        reliability: DataChannelReliability,
    ) -> Result<RTCDataChannelId, WebRtcError> {
        if label.is_empty() || label.len() > 256 {
            return Err(WebRtcError::InvalidConfiguration(
                "data channel label must contain 1-256 bytes".into(),
            ));
        }
        if reliability.max_packet_life_time.is_some() && reliability.max_retransmits.is_some() {
            return Err(WebRtcError::InvalidConfiguration(
                "data channel lifetime and retransmit limits are mutually exclusive".into(),
            ));
        }
        self.peer
            .create_data_channel(
                label,
                Some(RTCDataChannelInit {
                    ordered: reliability.ordered,
                    max_packet_life_time: reliability.max_packet_life_time,
                    max_retransmits: reliability.max_retransmits,
                    ..Default::default()
                }),
            )
            .map(|channel| channel.id())
            .map_err(rtc_error)
    }

    pub fn send_data(
        &mut self,
        channel_id: RTCDataChannelId,
        payload: &[u8],
    ) -> Result<(), WebRtcError> {
        if payload.is_empty() {
            return Err(WebRtcError::InvalidConfiguration(
                "data channel payload must not be empty".into(),
            ));
        }
        if payload.len() > MAX_DATA_CHANNEL_PAYLOAD_BYTES {
            return Err(WebRtcError::DataChannelPayloadTooLarge);
        }
        let mut channel = self
            .peer
            .data_channel(channel_id)
            .ok_or(WebRtcError::DataChannelNotFound(channel_id))?;
        channel.send(BytesMut::from(payload)).map_err(rtc_error)
    }

    pub fn enqueue_frame(
        &mut self,
        frame: MediaFrame,
        now: Instant,
    ) -> Result<crate::qos::EnqueueResult, crate::qos::QosError> {
        self.qos.enqueue(frame, now)
    }

    pub fn pop_frame(&mut self, now: Instant) -> Option<MediaFrame> {
        self.qos.pop_next(now)
    }

    pub fn on_connection_lost(&mut self) {
        self.qos.on_connection_lost();
        if let Some(video) = &mut self.screen_video {
            video.on_connection_lost();
        }
    }

    pub fn take_keyframe_request(&mut self) -> bool {
        self.qos.take_keyframe_request()
    }

    pub fn qos(&self) -> &MediaQos {
        &self.qos
    }

    pub fn handle_network_packet(&mut self, packet: TaggedBytesMut) -> Result<(), WebRtcError> {
        self.peer.handle_read(packet).map_err(rtc_error)
    }

    pub fn poll_network_packet(&mut self) -> Option<TaggedBytesMut> {
        self.peer.poll_write()
    }

    pub fn poll_message(&mut self) -> Option<RTCMessage> {
        self.peer.poll_read()
    }

    pub fn poll_event(&mut self) -> Option<RTCPeerConnectionEvent> {
        self.peer.poll_event()
    }

    pub fn handle_timeout(&mut self, now: Instant) -> Result<(), WebRtcError> {
        self.peer.handle_timeout(now).map_err(rtc_error)
    }

    pub fn poll_timeout(&mut self) -> Option<Instant> {
        self.peer.poll_timeout()
    }

    pub fn close(&mut self) -> Result<(), WebRtcError> {
        self.signaling.close();
        self.on_connection_lost();
        self.peer.close().map_err(rtc_error)
    }
}

fn to_rtc_ice_server(config: &IceServerConfig) -> Result<RTCIceServer, WebRtcError> {
    if config.urls.is_empty()
        || config
            .urls
            .iter()
            .any(|url| url.is_empty() || url.len() > 2048)
    {
        return Err(WebRtcError::InvalidConfiguration(
            "each ICE server must have 1-2048 byte URL entries".into(),
        ));
    }
    Ok(RTCIceServer {
        urls: config.urls.clone(),
        username: config.username.clone().unwrap_or_default(),
        credential: config.credential.clone().unwrap_or_default(),
    })
}

pub(crate) fn rtc_error(error: impl std::fmt::Display) -> WebRtcError {
    WebRtcError::Rtc(error.to_string())
}

#[cfg(test)]
#[path = "tests/peer.rs"]
mod tests;
