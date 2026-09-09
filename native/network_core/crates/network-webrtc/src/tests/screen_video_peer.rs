use std::time::{Duration, Instant};

use crate::media::RtpPacketizer;
use crate::{
    EncodedVideoFrame, H264AdaptationReason, H264AdaptationTarget, KeyframeRequestReason,
    MediaDirection, VideoCodec, VideoEnqueueResult, WebRtcConfig, WebRtcError, WebRtcPeer,
};
use rtc::peer_connection::event::{RTCPeerConnectionEvent, RTCTrackEvent, RTCTrackEventInit};
use rtc::rtp::Packet;

const SCREEN_SSRC: u32 = 0x1357_2468;

fn access_unit(sequence: u64, timestamp: u64) -> EncodedVideoFrame {
    let mut payload = vec![
        0, 0, 0, 1, 0x67, 0x42, 0, 0x1f, 0xe5, 0x88, 0x68, 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80, 0,
        0, 0, 1, 0x65,
    ];
    payload.extend((0..512).map(|index| (index as u8).wrapping_mul(29)));
    EncodedVideoFrame::new(
        VideoCodec::H264,
        sequence,
        timestamp,
        1_920,
        1_080,
        true,
        payload,
        Instant::now() + Duration::from_secs(1),
    )
}

fn packetize(frame: &EncodedVideoFrame, initial_sequence: u16) -> Vec<Packet> {
    RtpPacketizer::new(96, 102, SCREEN_SSRC, initial_sequence)
        .packetize(frame)
        .expect("valid screen access unit packetizes")
}

fn jitter_access_unit(sequence: u64, timestamp: u64) -> EncodedVideoFrame {
    let mut frame = access_unit(sequence, timestamp);
    frame.payload.extend(std::iter::repeat_n(0x41, 2_000));
    frame
}

#[test]
fn screen_video_offer_keeps_generic_codecs_while_advertising_h264() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    peer.configure_h264_screen_video(MediaDirection::Sendonly, Some(SCREEN_SSRC))
        .expect("screen video sender");

    let offer = peer.create_offer().expect("offer");
    assert!(offer.sdp.contains("H264"));
    assert!(
        offer.sdp.contains("VP8"),
        "generic video codecs remain registered"
    );
}

#[test]
fn data_channel_only_offer_does_not_add_a_screen_video_m_line() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    peer.create_data_channel("control", Default::default())
        .expect("data channel");

    let offer = peer.create_offer().expect("offer");
    assert!(
        !offer.sdp.contains("m=video"),
        "generic realtime sessions must not acquire an implicit screen track"
    );
}

#[test]
fn screen_video_requires_a_configured_h264_sender_and_stays_off_data_channels() {
    let now = Instant::now();
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    assert!(matches!(
        peer.enqueue_h264_screen_video(access_unit(1, 90_000), now),
        Err(WebRtcError::ScreenVideoNotConfigured)
    ));
    assert!(matches!(
        peer.flush_h264_screen_video(now),
        Err(WebRtcError::ScreenVideoNotConfigured)
    ));

    peer.configure_h264_screen_video(MediaDirection::Sendonly, Some(SCREEN_SSRC))
        .expect("screen video sender");
    assert!(matches!(
        peer.enqueue_h264_screen_video(access_unit(2, 93_000), now),
        Ok(VideoEnqueueResult::Accepted)
    ));
    assert!(matches!(
        peer.flush_h264_screen_video(now),
        Err(WebRtcError::ScreenVideoNotReady)
    ));
    assert_eq!(peer.pending_h264_screen_video_frames(), 1);
}

#[test]
fn screen_video_configuration_fails_closed_for_invalid_direction_or_ssrc() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    assert!(matches!(
        peer.configure_h264_screen_video(MediaDirection::Sendonly, None),
        Err(WebRtcError::InvalidConfiguration(_))
    ));
    assert!(matches!(
        peer.configure_h264_screen_video(MediaDirection::Recvonly, Some(SCREEN_SSRC)),
        Err(WebRtcError::InvalidConfiguration(_))
    ));
    peer.configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    assert!(matches!(
        peer.configure_h264_screen_video(MediaDirection::Recvonly, None),
        Err(WebRtcError::ScreenVideoAlreadyConfigured)
    ));
}

#[test]
fn screen_video_recovery_requests_a_keyframe_for_ice_restart_and_decoder_reset() {
    let mut sender = WebRtcPeer::new(WebRtcConfig::default()).expect("sender");
    sender
        .configure_h264_screen_video(MediaDirection::Sendonly, Some(SCREEN_SSRC))
        .expect("sender config");
    sender.restart_ice().expect("ICE restart");
    assert_eq!(
        sender.take_h264_screen_video_keyframe_request(),
        Some(KeyframeRequestReason::IceRestart)
    );

    let mut receiver = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    receiver
        .configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    receiver
        .reset_h264_screen_video_decoder()
        .expect("decoder reset");
    assert_eq!(
        receiver.take_h264_screen_video_keyframe_request(),
        Some(KeyframeRequestReason::DecoderReset)
    );
}

#[test]
fn explicit_keyframe_request_targets_the_configured_media_direction() {
    let mut sender = WebRtcPeer::new(WebRtcConfig::default()).expect("sender");
    sender
        .configure_h264_screen_video(MediaDirection::Sendonly, Some(SCREEN_SSRC))
        .expect("sender config");
    sender
        .request_h264_screen_video_keyframe(MediaDirection::Sendonly)
        .expect("sender keyframe request");
    assert_eq!(
        sender.take_h264_screen_video_keyframe_request(),
        Some(KeyframeRequestReason::PacketLoss)
    );

    let mut receiver = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    receiver
        .configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    receiver
        .request_h264_screen_video_keyframe(MediaDirection::Recvonly)
        .expect("receiver keyframe request");
    assert_eq!(
        receiver.take_h264_screen_video_keyframe_request(),
        Some(KeyframeRequestReason::PacketLoss)
    );
}

#[test]
fn receive_keyframe_request_is_retained_until_the_native_receiver_is_ready() {
    let mut receiver = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    receiver
        .configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    receiver
        .request_h264_screen_video_keyframe(MediaDirection::Recvonly)
        .expect("receiver keyframe request");

    // Early negotiation has no RTP receiver yet. Flushing must not drop the
    // request; the next native I/O tick can retry it after OnTrack activation.
    receiver.flush_h264_screen_video_keyframe_requests();
    assert_eq!(
        receiver.take_h264_screen_video_keyframe_request(),
        Some(KeyframeRequestReason::PacketLoss)
    );
}

#[test]
fn bounded_adaptation_is_native_sender_state_and_keeps_queue_capacity_fixed() {
    let mut sender = WebRtcPeer::new(WebRtcConfig::default()).expect("sender");
    sender
        .configure_h264_screen_video(MediaDirection::Sendonly, Some(SCREEN_SSRC))
        .expect("sender config");
    let target = H264AdaptationTarget {
        bitrate_kbps: 1_536,
        framerate: 7,
        width: 1_280,
        height: 720,
        reason: H264AdaptationReason::Congestion,
    };
    sender
        .apply_h264_screen_video_adaptation(target)
        .expect("bounded target");
    assert_eq!(sender.h264_screen_video_adaptation(), Some(target));
    assert_eq!(sender.pending_h264_screen_video_frames(), 0);

    let invalid = H264AdaptationTarget {
        bitrate_kbps: 1,
        ..target
    };
    assert!(matches!(
        sender.apply_h264_screen_video_adaptation(invalid),
        Err(WebRtcError::InvalidConfiguration(_))
    ));
}

#[test]
fn sendrecv_stats_keep_the_legacy_queue_capacity_at_three() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("peer");
    peer.configure_h264_screen_video(MediaDirection::Sendrecv, Some(SCREEN_SSRC))
        .expect("sendrecv config");

    let stats = peer
        .h264_screen_video_stats(MediaDirection::Sendrecv)
        .expect("native stats");
    assert!(stats.queue_depth <= stats.queue_capacity);
    assert_eq!(stats.queue_capacity, 3);
}

#[test]
fn packet_loss_reorder_and_duplicate_are_media_local_recovery_events() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    peer.configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    let now = Instant::now();

    let first = packetize(&access_unit(1, 90_000), 100);
    for (index, packet) in first.iter().enumerate() {
        if index == 1 {
            continue;
        }
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("packet loss must not fail the peer");
    }
    let next = packetize(&access_unit(2, 96_000), 200);
    for packet in &next {
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("a fresh keyframe recovers after loss");
    }
    assert!(peer.pop_remote_h264_screen_video(now).is_some());

    let reordered = packetize(&access_unit(3, 102_000), 300);
    peer.receive_h264_screen_video_rtp(&reordered[1], now)
        .expect("reordering must be media-local");
    peer.receive_h264_screen_video_rtp(&reordered[0], now)
        .expect("late first fragment must not fail the peer");
    for packet in reordered.iter().skip(2) {
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("reordered frame remains recoverable");
    }

    let duplicate = packetize(&access_unit(4, 108_000), 400);
    for packet in &duplicate {
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("baseline frame is accepted");
    }
    peer.receive_h264_screen_video_rtp(&duplicate[0], now)
        .expect("duplicate fragment must be discarded locally");
}

#[test]
fn screen_video_stats_report_rtp_loss_recovery_and_jitter_without_payloads() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    peer.configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    let now = Instant::now();
    let mut packetizer = RtpPacketizer::new(96, 102, SCREEN_SSRC, 100);

    let first = packetizer
        .packetize(&access_unit(10, 90_000))
        .expect("first frame packetizes");
    assert!(first.len() > 2, "test needs a multi-packet access unit");
    for packet in first.iter().take(1).chain(first.iter().skip(2)) {
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("loss remains media-local");
    }

    let recovered = packetizer
        .packetize(&access_unit(11, 96_000))
        .expect("recovery frame packetizes");
    for packet in &recovered {
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("recovery keyframe is accepted");
    }
    assert!(peer.pop_remote_h264_screen_video(now).is_some());

    let stats = peer
        .h264_screen_video_stats(MediaDirection::Recvonly)
        .expect("native stats");
    assert_eq!(
        stats.packets_received as usize,
        first.len() - 1 + recovered.len()
    );
    assert_eq!(stats.packets_lost, 1);
    assert_eq!(stats.frames_recovered, 1);
    assert_eq!(stats.keyframe_requests, 1);
    assert!(stats.jitter_ms > 0, "timestamp/arrival skew is observable");
    assert!(stats.queue_depth <= stats.queue_capacity);
    assert_eq!(stats.queue_capacity, 3);
}

#[test]
fn inbound_jitter_ewma_can_decrease_after_a_transient_arrival_burst() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    peer.configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    let base = Instant::now();
    let mut packetizer = RtpPacketizer::new(96, 102, SCREEN_SSRC, 10_000);

    for packet in packetizer
        .packetize(&jitter_access_unit(1, 90_000))
        .expect("first frame packetizes")
    {
        peer.receive_h264_screen_video_rtp(&packet, base)
            .expect("first frame accepted");
    }
    for packet in packetizer
        .packetize(&jitter_access_unit(2, 96_000))
        .expect("burst frame packetizes")
    {
        peer.receive_h264_screen_video_rtp(&packet, base + Duration::from_secs(1))
            .expect("burst frame accepted");
    }
    let burst = peer
        .h264_screen_video_stats(MediaDirection::Recvonly)
        .expect("burst stats")
        .jitter_ms;
    assert!(burst > 0);

    for sequence in 3_u64..=100 {
        let arrival =
            base + Duration::from_secs(1) + Duration::from_nanos(66_666_667 * (sequence - 2));
        let timestamp = 90_000 + sequence * 6_000;
        for packet in packetizer
            .packetize(&jitter_access_unit(sequence, timestamp))
            .expect("stable frame packetizes")
        {
            peer.receive_h264_screen_video_rtp(&packet, arrival)
                .expect("stable frame accepted");
        }
    }

    let settled = peer
        .h264_screen_video_stats(MediaDirection::Recvonly)
        .expect("settled stats")
        .jitter_ms;
    assert!(
        settled < burst,
        "jitter EWMA must recover: {burst} -> {settled}"
    );
}

#[test]
fn connection_loss_resets_rtp_ordering_without_erasing_bounded_counters() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    peer.configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    let now = Instant::now();
    let mut first_packetizer = RtpPacketizer::new(96, 102, SCREEN_SSRC, 10);
    let first = first_packetizer
        .packetize(&access_unit(20, 120_000))
        .expect("first frame packetizes");
    for packet in &first {
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("first frame accepted");
    }
    assert!(peer.pop_remote_h264_screen_video(now).is_some());

    peer.on_connection_lost();

    let mut replacement_packetizer = RtpPacketizer::new(96, 102, SCREEN_SSRC, 30_000);
    let replacement = replacement_packetizer
        .packetize(&access_unit(21, 126_000))
        .expect("replacement frame packetizes");
    for packet in &replacement {
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("replacement frame accepted");
    }
    assert!(peer.pop_remote_h264_screen_video(now).is_some());

    let stats = peer
        .h264_screen_video_stats(MediaDirection::Recvonly)
        .expect("native stats");
    assert_eq!(
        stats.packets_received as usize,
        first.len() + replacement.len()
    );
    assert_eq!(stats.packets_lost, 0);
    assert_eq!(stats.frames_recovered, 1);
}

#[test]
fn mismatched_screen_ssrc_is_ignored_after_track_binding() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    peer.configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    let now = Instant::now();

    for packet in packetize(&access_unit(5, 114_000), 500) {
        peer.receive_h264_screen_video_rtp(&packet, now)
            .expect("first screen SSRC is accepted");
    }
    assert!(peer.pop_remote_h264_screen_video(now).is_some());

    let mut foreign_ssrc = packetize(&access_unit(6, 120_000), 600);
    for packet in &mut foreign_ssrc {
        packet.header.ssrc = SCREEN_SSRC.wrapping_add(1);
        peer.receive_h264_screen_video_rtp(packet, now)
            .expect("foreign SSRC is ignored without failing the peer");
    }
    assert!(peer.pop_remote_h264_screen_video(now).is_none());
}

#[test]
fn mixed_rtp_tracks_do_not_enter_the_screen_h264_depacketizer() {
    let mut peer = WebRtcPeer::new(WebRtcConfig::default()).expect("receiver");
    peer.configure_h264_screen_video(MediaDirection::Recvonly, None)
        .expect("receiver config");
    peer.observe_screen_video_event(&RTCPeerConnectionEvent::OnTrack(RTCTrackEvent::OnOpen(
        RTCTrackEventInit {
            track_id: "screen-track".to_owned(),
            ..Default::default()
        },
    )));

    let malformed = Packet::default();
    peer.receive_h264_screen_video_rtp_for_track("audio-track", &malformed, Instant::now())
        .expect("unrelated track is ignored");
    assert!(peer.pop_remote_h264_screen_video(Instant::now()).is_none());
}
