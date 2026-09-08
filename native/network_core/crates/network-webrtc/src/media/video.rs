use std::time::Instant;

use rtc::peer_connection::configuration::media_engine::{MediaEngine, MIME_TYPE_H264};
use rtc::peer_connection::event::{RTCPeerConnectionEvent, RTCTrackEvent};
use rtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use rtc::rtp_transceiver::rtp_sender::{RTCPFeedback, RTCRtpCodec, RTCRtpCodecParameters};
use rtc::rtp_transceiver::{RTCRtpReceiverId, RTCRtpSenderId};

use crate::peer::{rtc_error, MediaDirection, WebRtcError, WebRtcPeer};

use super::{
    EncodedVideoFrame, KeyframeRequestReason, RtpMediaError, RtpPacketizer, RtpReassembler,
    VideoEnqueueResult, VideoFrameError, VideoMediaStats, VideoQueue, MAX_SCREEN_VIDEO_HEIGHT,
    MAX_SCREEN_VIDEO_WIDTH, SCREEN_VIDEO_QUEUE_CAPACITY,
};

const H264_RTP_PAYLOAD_TYPE: u8 = 102;
const H264_RTP_MTU: usize = 1_200;

/// Bounded queue/recovery counters for one native H.264 screen-video
/// direction. Platform owners may expose these as low-frequency metadata; no
/// frame payload or per-frame event crosses the native boundary.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct H264ScreenVideoStats {
    pub enqueued: u64,
    pub dequeued: u64,
    pub dropped: u64,
    pub keyframe_requests: u64,
    pub packets_sent: u64,
    pub packets_received: u64,
    pub packets_lost: u64,
    pub frames_recovered: u64,
    pub jitter_ms: u64,
    pub rtt_ms: u64,
    pub queue_depth: u32,
    pub queue_capacity: u32,
}

impl H264ScreenVideoStats {
    fn from_direction(video: &H264ScreenVideo, queue: &VideoQueue, send: bool) -> Self {
        let stats: VideoMediaStats = queue.stats();
        Self {
            enqueued: stats.enqueued,
            dequeued: stats.dequeued,
            dropped: stats
                .dropped_stale
                .saturating_add(stats.dropped_overflow)
                .saturating_add(stats.dropped_unsafe_delta)
                .saturating_add(stats.dropped_on_disconnect),
            keyframe_requests: stats.keyframe_requests,
            packets_sent: if send { video.packets_sent } else { 0 },
            packets_received: if send { 0 } else { video.packets_received },
            packets_lost: if send { 0 } else { video.packets_lost },
            frames_recovered: if send { 0 } else { video.frames_recovered },
            jitter_ms: if send { 0 } else { video.jitter_ms() },
            // RTT is owned by the ICE/RTCP implementation. It remains zero
            // until that native statistics source is exposed by the rtc
            // integration; do not synthesize it from media arrival timing.
            rtt_ms: 0,
            queue_depth: queue.len().min(SCREEN_VIDEO_QUEUE_CAPACITY) as u32,
            queue_capacity: SCREEN_VIDEO_QUEUE_CAPACITY as u32,
        }
    }
}

/// Why a native sender target was selected. The value is carried only across
/// the native owner port and is never serialized as media payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum H264AdaptationReason {
    Steady,
    Congestion,
    Recovery,
}

/// One bounded target for the native H.264 sender.
///
/// A zero dimension means "keep the current capture size". In-place
/// resolution changes are still rejected by platform owners; callers must
/// stop/release/recreate for a source-size change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct H264AdaptationTarget {
    pub bitrate_kbps: u32,
    pub framerate: u32,
    pub width: u32,
    pub height: u32,
    pub reason: H264AdaptationReason,
}

impl H264AdaptationTarget {
    pub const MIN_BITRATE_KBPS: u32 = 256;
    pub const MAX_BITRATE_KBPS: u32 = 3 * 1024;
    pub const MIN_FRAMERATE: u32 = 5;
    pub const MAX_FRAMERATE: u32 = 30;

    pub const fn is_valid(self) -> bool {
        let dimensions_valid = (self.width == 0 && self.height == 0)
            || (self.width > 0
                && self.height > 0
                && self.width <= MAX_SCREEN_VIDEO_WIDTH
                && self.height <= MAX_SCREEN_VIDEO_HEIGHT);
        self.bitrate_kbps >= Self::MIN_BITRATE_KBPS
            && self.bitrate_kbps <= Self::MAX_BITRATE_KBPS
            && self.framerate >= Self::MIN_FRAMERATE
            && self.framerate <= Self::MAX_FRAMERATE
            && dimensions_valid
    }
}

pub(crate) struct H264ScreenVideo {
    sender_id: Option<RTCRtpSenderId>,
    outbound: VideoQueue,
    inbound: VideoQueue,
    packetizer: Option<RtpPacketizer>,
    reassembler: RtpReassembler,
    accepts_inbound: bool,
    inbound_track_id: Option<String>,
    inbound_receiver_id: Option<RTCRtpReceiverId>,
    inbound_media_ssrc: Option<u32>,
    adaptation_target: H264AdaptationTarget,
    packets_sent: u64,
    packets_received: u64,
    packets_lost: u64,
    frames_recovered: u64,
    recovery_pending: bool,
    last_inbound_sequence: Option<u16>,
    last_inbound_timestamp: Option<u32>,
    last_inbound_arrival: Option<Instant>,
    jitter_rtp_units: u64,
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
            inbound_receiver_id: None,
            inbound_media_ssrc: None,
            adaptation_target: H264AdaptationTarget {
                bitrate_kbps: H264AdaptationTarget::MAX_BITRATE_KBPS,
                framerate: H264AdaptationTarget::MAX_FRAMERATE,
                width: 0,
                height: 0,
                reason: H264AdaptationReason::Steady,
            },
            packets_sent: 0,
            packets_received: 0,
            packets_lost: 0,
            frames_recovered: 0,
            recovery_pending: false,
            last_inbound_sequence: None,
            last_inbound_timestamp: None,
            last_inbound_arrival: None,
            jitter_rtp_units: 0,
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
        self.inbound_receiver_id = None;
        self.inbound_media_ssrc = None;
        self.reset_inbound_timing();
        self.recovery_pending = self.accepts_inbound;
    }

    fn observe_inbound_packet(&mut self, packet: &rtc::rtp::Packet, now: Instant) {
        self.packets_received = self.packets_received.saturating_add(1);

        if let Some(previous) = self.last_inbound_sequence {
            let delta = packet.header.sequence_number.wrapping_sub(previous);
            // A forward jump in the RTP sequence space represents one or more
            // missing packets. Equal/backward values are duplicates or late
            // reordering and must not inflate loss counters.
            if delta > 0 && delta <= u16::MAX / 2 {
                self.packets_lost = self
                    .packets_lost
                    .saturating_add(u64::from(delta.saturating_sub(1)));
                self.last_inbound_sequence = Some(packet.header.sequence_number);
            }
        } else {
            self.last_inbound_sequence = Some(packet.header.sequence_number);
        }

        if let (Some(previous_timestamp), Some(previous_arrival)) =
            (self.last_inbound_timestamp, self.last_inbound_arrival)
        {
            let timestamp_delta = packet.header.timestamp.wrapping_sub(previous_timestamp);
            if timestamp_delta > 0 && timestamp_delta <= u32::MAX / 2 {
                let arrival_ticks = now
                    .saturating_duration_since(previous_arrival)
                    .as_nanos()
                    .saturating_mul(90_000)
                    / 1_000_000_000;
                let arrival_ticks = arrival_ticks.min(u128::from(u64::MAX)) as u64;
                let transit_delta = i128::from(arrival_ticks) - i128::from(timestamp_delta);
                let absolute_delta = if transit_delta >= 0 {
                    transit_delta as u64
                } else {
                    (-transit_delta) as u64
                };
                let jitter = self.jitter_rtp_units;
                self.jitter_rtp_units =
                    jitter.saturating_add(absolute_delta.saturating_sub(jitter) / 16);
                self.last_inbound_timestamp = Some(packet.header.timestamp);
                self.last_inbound_arrival = Some(now);
            }
        } else {
            self.last_inbound_timestamp = Some(packet.header.timestamp);
            self.last_inbound_arrival = Some(now);
        }
    }

    fn mark_recovery_needed(&mut self) {
        self.recovery_pending = true;
        self.inbound
            .request_keyframe(KeyframeRequestReason::PacketLoss);
    }

    fn reset_inbound_timing(&mut self) {
        self.last_inbound_sequence = None;
        self.last_inbound_timestamp = None;
        self.last_inbound_arrival = None;
        self.jitter_rtp_units = 0;
    }

    fn jitter_ms(&self) -> u64 {
        self.jitter_rtp_units.saturating_mul(1_000) / 90_000
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
                if let Some(video) = self.screen_video.as_mut() {
                    video.packets_sent = video.packets_sent.saturating_add(1);
                }
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
        if let Some(media_ssrc) = video.inbound_media_ssrc {
            // A negotiated track may carry retransmission or unrelated SSRCs;
            // only the first screen-video SSRC is allowed into the H.264
            // reassembler. Ignore a mismatched packet as a media-local event
            // instead of letting it perturb sequence/order state.
            if media_ssrc != packet.header.ssrc {
                return Ok(());
            }
        } else {
            video.inbound_media_ssrc = Some(packet.header.ssrc);
        }
        video.observe_inbound_packet(packet, now);
        match video.reassembler.push_at(packet, now) {
            Ok(Some(frame)) => {
                let keyframe = frame.keyframe;
                match video.inbound.enqueue(frame, now) {
                    Ok(
                        VideoEnqueueResult::Accepted
                        | VideoEnqueueResult::AcceptedAfterDropping { .. },
                    ) => {
                        if video.recovery_pending && keyframe {
                            video.frames_recovered = video.frames_recovered.saturating_add(1);
                            video.recovery_pending = false;
                        }
                    }
                    Ok(_) => {}
                    Err(VideoFrameError::InvalidAccessUnit) => {
                        video.reassembler.reset();
                        video.mark_recovery_needed();
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            Ok(None) => {}
            Err(
                error @ (RtpMediaError::MalformedPayload
                | RtpMediaError::StaleOrDiscontinuous
                | RtpMediaError::ReassembledFrameTooLarge),
            ) => {
                let _ = error;
                video.reassembler.reset();
                video.mark_recovery_needed();
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
                        video.inbound_receiver_id = Some(init.receiver_id);
                        video.inbound_media_ssrc = None;
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
                    video.inbound_receiver_id = None;
                    video.inbound_media_ssrc = None;
                    video.reassembler.reset();
                    video.reset_inbound_timing();
                    video.recovery_pending = video.accepts_inbound;
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

    /// Returns bounded queue and recovery counters for one screen-video
    /// direction. This is an observational native snapshot and never touches
    /// the media payload path.
    pub fn h264_screen_video_stats(
        &self,
        direction: MediaDirection,
    ) -> Result<H264ScreenVideoStats, WebRtcError> {
        let video = self
            .screen_video
            .as_ref()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        let stats = match direction {
            MediaDirection::Sendonly => {
                H264ScreenVideoStats::from_direction(video, &video.outbound, true)
            }
            MediaDirection::Recvonly => {
                H264ScreenVideoStats::from_direction(video, &video.inbound, false)
            }
            MediaDirection::Sendrecv => {
                let outbound = H264ScreenVideoStats::from_direction(video, &video.outbound, true);
                let inbound = H264ScreenVideoStats::from_direction(video, &video.inbound, false);
                H264ScreenVideoStats {
                    enqueued: outbound.enqueued.saturating_add(inbound.enqueued),
                    dequeued: outbound.dequeued.saturating_add(inbound.dequeued),
                    dropped: outbound.dropped.saturating_add(inbound.dropped),
                    keyframe_requests: outbound
                        .keyframe_requests
                        .saturating_add(inbound.keyframe_requests),
                    packets_sent: outbound.packets_sent,
                    packets_received: inbound.packets_received,
                    packets_lost: inbound.packets_lost,
                    frames_recovered: inbound.frames_recovered,
                    jitter_ms: outbound.jitter_ms.max(inbound.jitter_ms),
                    rtt_ms: outbound.rtt_ms.max(inbound.rtt_ms),
                    queue_depth: outbound.queue_depth.saturating_add(inbound.queue_depth),
                    queue_capacity: (SCREEN_VIDEO_QUEUE_CAPACITY * 2) as u32,
                }
            }
        };
        Ok(stats)
    }

    pub fn reset_h264_screen_video_decoder(&mut self) -> Result<(), WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        video.reassembler.reset();
        video.inbound.on_decoder_reset();
        video.recovery_pending = true;
        Ok(())
    }

    /// Requests a fresh keyframe for one native screen-video direction.
    ///
    /// The request is coalesced by the bounded queue and is consumed by the
    /// native WebRTC owner; no control or media payload crosses into Dart.
    pub fn request_h264_screen_video_keyframe(
        &mut self,
        direction: MediaDirection,
    ) -> Result<(), WebRtcError> {
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        match direction {
            MediaDirection::Sendonly => {
                video
                    .outbound
                    .request_keyframe(KeyframeRequestReason::PacketLoss);
            }
            MediaDirection::Recvonly => {
                video
                    .inbound
                    .request_keyframe(KeyframeRequestReason::PacketLoss);
            }
            MediaDirection::Sendrecv => {
                video
                    .outbound
                    .request_keyframe(KeyframeRequestReason::PacketLoss);
                video
                    .inbound
                    .request_keyframe(KeyframeRequestReason::PacketLoss);
            }
        }
        Ok(())
    }

    /// Flushes one pending receive-side keyframe request as native RTCP PLI.
    ///
    /// The request remains queued until the negotiated screen receiver exists
    /// and the peer can accept an RTCP packet. A missing receiver is expected
    /// during early negotiation and is therefore not a fatal peer error.
    pub fn flush_h264_screen_video_keyframe_requests(&mut self) {
        let pending = self.screen_video.as_mut().and_then(|video| {
            video
                .inbound
                .take_keyframe_request()
                .map(|reason| (reason, video.inbound_receiver_id, video.inbound_media_ssrc))
        });
        let Some((reason, receiver_id, media_ssrc)) = pending else {
            return;
        };
        let Some(receiver_id) = receiver_id else {
            if let Some(video) = self.screen_video.as_mut() {
                video.inbound.request_keyframe(reason);
            }
            return;
        };
        let Some(mut receiver) = self.peer.rtp_receiver(receiver_id) else {
            if let Some(video) = self.screen_video.as_mut() {
                video.inbound.request_keyframe(reason);
            }
            return;
        };
        let pli = PictureLossIndication {
            sender_ssrc: 0,
            media_ssrc: media_ssrc.unwrap_or_default(),
        };
        if receiver.write_rtcp(vec![Box::new(pli)]).is_err() {
            if let Some(video) = self.screen_video.as_mut() {
                video.inbound.request_keyframe(reason);
            }
        }
    }

    /// Applies a validated sender target while preserving the fixed queue
    /// capacity. Platform owners apply the target to their hardware encoder;
    /// the peer retains it as the native source of truth for the generation.
    pub fn apply_h264_screen_video_adaptation(
        &mut self,
        target: H264AdaptationTarget,
    ) -> Result<(), WebRtcError> {
        if !target.is_valid() {
            return Err(WebRtcError::InvalidConfiguration(
                "H.264 adaptation target is outside the bounded policy".into(),
            ));
        }
        let video = self
            .screen_video
            .as_mut()
            .ok_or(WebRtcError::ScreenVideoNotConfigured)?;
        if video.sender_id.is_none() {
            return Err(WebRtcError::ScreenVideoNotConfigured);
        }
        video.adaptation_target = target;
        Ok(())
    }

    /// Returns the latest native sender target for diagnostics and tests.
    pub fn h264_screen_video_adaptation(&self) -> Option<H264AdaptationTarget> {
        self.screen_video
            .as_ref()
            .filter(|video| video.sender_id.is_some())
            .map(|video| video.adaptation_target)
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
                video.reset_inbound_timing();
                video.recovery_pending = false;
            }
            MediaDirection::Sendrecv => {
                video.outbound.clear();
                video.inbound.clear();
                video.reassembler.clear_for_endpoint_release();
                video.reset_inbound_timing();
                video.recovery_pending = false;
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
