use std::time::Instant;

use rtc::peer_connection::configuration::media_engine::{MediaEngine, MIME_TYPE_H264};
use rtc::peer_connection::event::{RTCPeerConnectionEvent, RTCTrackEvent};
use rtc::rtp_transceiver::rtp_sender::{RTCPFeedback, RTCRtpCodec, RTCRtpCodecParameters};
use rtc::rtp_transceiver::RTCRtpSenderId;

use crate::peer::{rtc_error, MediaDirection, WebRtcError, WebRtcPeer};

use super::{
    EncodedVideoFrame, KeyframeRequestReason, RtpMediaError, RtpPacketizer, RtpReassembler,
    VideoEnqueueResult, VideoFrameError, VideoQueue,
};

const H264_RTP_PAYLOAD_TYPE: u8 = 102;
const H264_RTP_MTU: usize = 1_200;

pub(crate) struct H264ScreenVideo {
    sender_id: Option<RTCRtpSenderId>,
    outbound: VideoQueue,
    inbound: VideoQueue,
    packetizer: Option<RtpPacketizer>,
    reassembler: RtpReassembler,
    accepts_inbound: bool,
    inbound_track_id: Option<String>,
}

impl H264ScreenVideo {
    fn new(sender_id: Option<RTCRtpSenderId>, ssrc: Option<u32>, accepts_inbound: bool) -> Self {
        Self {
            sender_id,
            outbound: VideoQueue::new(),
            inbound: VideoQueue::new(),
            packetizer: ssrc.map(|ssrc| {
                RtpPacketizer::new(
                    H264_RTP_MTU,
                    H264_RTP_PAYLOAD_TYPE,
                    ssrc,
                    (ssrc as u16).wrapping_add(1),
                )
            }),
            reassembler: RtpReassembler::new(),
            accepts_inbound,
            inbound_track_id: None,
        }
    }

    pub(crate) fn on_ice_restart(&mut self) {
        self.outbound
            .request_keyframe(KeyframeRequestReason::IceRestart);
    }

    pub(crate) fn on_connection_lost(&mut self) {
        self.outbound.on_disconnect();
        self.inbound.on_disconnect();
        self.reassembler.reset();
        self.inbound_track_id = None;
    }
}

impl WebRtcPeer {
    /// Configures the peer's one native H.264 screen-video track.
    ///
    /// The track and RTP sender stay owned by this native peer. Callers enqueue
    /// encoded access units only; they never receive a PeerConnection, sender,
    /// or DataChannel handle.
    pub fn configure_h264_screen_video(
        &mut self,
        direction: MediaDirection,
        ssrc: Option<u32>,
    ) -> Result<(), WebRtcError> {
        if self.screen_video.is_some() {
            return Err(WebRtcError::ScreenVideoAlreadyConfigured);
        }
        let sends = matches!(
            direction,
            MediaDirection::Sendonly | MediaDirection::Sendrecv
        );
        if sends != ssrc.is_some() {
            return Err(WebRtcError::InvalidConfiguration(
                "a screen-video SSRC is required exactly for a sending H.264 transceiver".into(),
            ));
        }

        self.add_media_transceiver_with_codec(
            crate::qos::MediaKind::Video,
            direction,
            ssrc,
            Some(h264_codec_parameters().rtp_codec),
        )?;
        let sender_id = if sends {
            Some(self.peer.get_senders().last().ok_or_else(|| {
                WebRtcError::Rtc("screen-video RTP sender was not created".to_owned())
            })?)
        } else {
            None
        };
        self.screen_video = Some(H264ScreenVideo::new(
            sender_id,
            ssrc,
            matches!(
                direction,
                MediaDirection::Recvonly | MediaDirection::Sendrecv
            ),
        ));
        Ok(())
    }

    /// Enqueues one native H.264 access unit. It is bounded before it reaches
    /// RTP and cannot use the DataChannel path.
    pub fn enqueue_h264_screen_video(
        &mut self,
        frame: EncodedVideoFrame,
        now: Instant,
    ) -> Result<VideoEnqueueResult, WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        if video.sender_id.is_none() {
            return Err(WebRtcError::ScreenVideoNotConfigured);
        }
        video.outbound.enqueue(frame, now).map_err(Into::into)
    }

    /// Writes all eligible native H.264 frames to the RTP sender. The I/O
    /// driver drains the resulting SRTP packets over its UDP socket.
    pub fn flush_h264_screen_video(&mut self, now: Instant) -> Result<usize, WebRtcError> {
        let sender_id = self
            .screen_video
            .as_ref()
            .and_then(|video| video.sender_id)
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        if self.signaling.state() != crate::signaling::SignalingState::Connected {
            return Err(WebRtcError::ScreenVideoNotReady);
        }
        let mut packet_count = 0;
        loop {
            let packets = {
                let video = self
                    .screen_video
                    .as_mut()
                    .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
                let Some(frame) = video.outbound.pop(now) else {
                    break;
                };
                video
                    .packetizer
                    .as_mut()
                    .ok_or(WebRtcError::ScreenVideoNotConfigured)?
                    .packetize(&frame)?
            };
            let mut sender = self
                .peer
                .rtp_sender(sender_id)
                .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
            for packet in packets {
                sender.write_rtp(packet).map_err(rtc_error)?;
                packet_count += 1;
            }
        }
        Ok(packet_count)
    }

    /// Runtime-only variant used by the I/O owner. A peer without a sending
    /// screen track, or one that has not finished SDP negotiation, simply has
    /// no media work to drain yet.
    pub(crate) fn flush_pending_h264_screen_video(
        &mut self,
        now: Instant,
    ) -> Result<usize, WebRtcError> {
        if self
            .screen_video
            .as_ref()
            .is_none_or(|video| video.sender_id.is_none())
            || self.signaling.state() != crate::signaling::SignalingState::Connected
        {
            return Ok(0);
        }
        self.flush_h264_screen_video(now)
    }

    /// Accepts an RTP packet only inside the native media owner and stores a
    /// completed encoded access unit in the bounded incoming queue.
    pub fn receive_h264_screen_video_rtp(
        &mut self,
        packet: &rtc::rtp::Packet,
        now: Instant,
    ) -> Result<(), WebRtcError> {
        self.receive_h264_screen_video_rtp_inner(packet, now)
    }

    /// Accepts RTP only when the packet belongs to the negotiated screen
    /// receiver. Packets from unrelated audio/video tracks are ignored and
    /// never reach the H.264 depacketizer.
    pub(crate) fn receive_h264_screen_video_rtp_for_track(
        &mut self,
        track_id: &str,
        packet: &rtc::rtp::Packet,
        now: Instant,
    ) -> Result<(), WebRtcError> {
        let matches_screen_track = self
            .screen_video
            .as_ref()
            .and_then(|video| video.inbound_track_id.as_deref())
            .is_some_and(|screen_track_id| screen_track_id == track_id);
        if !matches_screen_track {
            return Ok(());
        }
        self.receive_h264_screen_video_rtp_inner(packet, now)
    }

    fn receive_h264_screen_video_rtp_inner(
        &mut self,
        packet: &rtc::rtp::Packet,
        now: Instant,
    ) -> Result<(), WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        if !video.accepts_inbound {
            return Err(WebRtcError::ScreenVideoNotConfigured);
        }
        match video.reassembler.push_at(packet, now) {
            Ok(Some(frame)) => match video.inbound.enqueue(frame, now) {
                Ok(_) => {}
                Err(VideoFrameError::InvalidAccessUnit) => {
                    video.reassembler.reset();
                    video
                        .inbound
                        .request_keyframe(KeyframeRequestReason::PacketLoss);
                }
                Err(error) => return Err(error.into()),
            },
            Ok(None) => {}
            Err(
                error @ (RtpMediaError::MalformedPayload
                | RtpMediaError::StaleOrDiscontinuous
                | RtpMediaError::ReassembledFrameTooLarge),
            ) => {
                let _ = error;
                video.reassembler.reset();
                video
                    .inbound
                    .request_keyframe(KeyframeRequestReason::PacketLoss);
            }
            Err(error) => return Err(error.into()),
        }
        Ok(())
    }

    /// Records the negotiated H.264 receiver track. The peer's event queue is
    /// the authority for track identity; RTP packets are accepted only after
    /// this check succeeds.
    pub(crate) fn observe_screen_video_event(&mut self, event: &RTCPeerConnectionEvent) {
        match event {
            RTCPeerConnectionEvent::OnTrack(RTCTrackEvent::OnOpen(init)) => {
                let is_h264 =
                    self.peer
                        .rtp_receiver(init.receiver_id)
                        .is_some_and(|mut receiver| {
                            receiver
                                .get_parameters()
                                .rtp_parameters
                                .codecs
                                .iter()
                                .any(|codec| {
                                    codec
                                        .rtp_codec
                                        .mime_type
                                        .eq_ignore_ascii_case(MIME_TYPE_H264)
                                })
                        });
                if is_h264 {
                    if let Some(video) = self.screen_video.as_mut() {
                        video.inbound_track_id = Some(init.track_id.clone());
                    }
                }
            }
            RTCPeerConnectionEvent::OnTrack(
                RTCTrackEvent::OnError(track_id)
                | RTCTrackEvent::OnClosing(track_id)
                | RTCTrackEvent::OnClose(track_id),
            ) if self
                .screen_video
                .as_ref()
                .and_then(|video| video.inbound_track_id.as_deref())
                .is_some_and(|screen_track_id| screen_track_id == track_id) =>
            {
                if let Some(video) = self.screen_video.as_mut() {
                    video.inbound_track_id = None;
                    video.reassembler.reset();
                }
            }
            _ => {}
        }
    }

    /// Returns an encoded remote H.264 access unit to another native owner.
    /// It is intentionally never exposed through the Dart/FFI event stream.
    pub fn pop_remote_h264_screen_video(&mut self, now: Instant) -> Option<EncodedVideoFrame> {
        self.screen_video
            .as_mut()
            .and_then(|video| video.inbound.pop(now))
    }

    pub fn pending_h264_screen_video_frames(&self) -> usize {
        self.screen_video
            .as_ref()
            .map_or(0, |video| video.outbound.len())
    }

    pub fn reset_h264_screen_video_decoder(&mut self) -> Result<(), WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        video.reassembler.reset();
        video.inbound.on_decoder_reset();
        Ok(())
    }

    /// Clears the queue and partial RTP reassembly state for one endpoint
    /// direction. This is intentionally separate from connection-loss and
    /// decoder-reset handling: releasing an endpoint must not request a
    /// keyframe or retain ordering state for a future endpoint lease.
    pub fn clear_h264_screen_video(
        &mut self,
        direction: MediaDirection,
    ) -> Result<(), WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        match direction {
            MediaDirection::Sendonly => video.outbound.clear(),
            MediaDirection::Recvonly => {
                video.inbound.clear();
                video.reassembler.clear_for_endpoint_release();
            }
            MediaDirection::Sendrecv => {
                video.outbound.clear();
                video.inbound.clear();
                video.reassembler.clear_for_endpoint_release();
            }
        }
        Ok(())
    }

    pub fn take_h264_screen_video_keyframe_request(&mut self) -> Option<KeyframeRequestReason> {
        self.screen_video.as_mut().and_then(|video| {
            video
                .outbound
                .take_keyframe_request()
                .or_else(|| video.inbound.take_keyframe_request())
        })
    }
}

pub(crate) fn h264_media_engine() -> Result<MediaEngine, WebRtcError> {
    let mut media_engine = MediaEngine::default();
    media_engine.register_default_codecs().map_err(rtc_error)?;
    Ok(media_engine)
}

pub(crate) fn h264_codec_parameters() -> RTCRtpCodecParameters {
    RTCRtpCodecParameters {
        rtp_codec: RTCRtpCodec {
            mime_type: MIME_TYPE_H264.to_owned(),
            clock_rate: 90_000,
            channels: 0,
            sdp_fmtp_line: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
                .to_owned(),
            rtcp_feedback: vec![
                RTCPFeedback {
                    typ: "nack".to_owned(),
                    parameter: "".to_owned(),
                },
                RTCPFeedback {
                    typ: "nack".to_owned(),
                    parameter: "pli".to_owned(),
                },
                RTCPFeedback {
                    typ: "ccm".to_owned(),
                    parameter: "fir".to_owned(),
                },
            ],
        },
        payload_type: H264_RTP_PAYLOAD_TYPE,
    }
}
