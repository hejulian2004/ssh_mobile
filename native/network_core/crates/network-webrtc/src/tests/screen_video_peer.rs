use std::time::{Duration, Instant};

use crate::media::RtpPacketizer;
use crate::{
    EncodedVideoFrame, KeyframeRequestReason, MediaDirection, VideoCodec, VideoEnqueueResult,
    WebRtcConfig, WebRtcError, WebRtcPeer,
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
