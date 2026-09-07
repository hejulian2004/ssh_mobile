use bytes::Bytes;
use rtc::rtp::{Header, Packet};

use crate::media::{EncodedVideoFrame, RtpPacketizer, RtpReassembler, VideoCodec};
use std::time::{Duration, Instant};

const H264_PAYLOAD_TYPE: u8 = 102;
const SSRC: u32 = 0x1357_2468;
const RTP_MTU: usize = 96;
const INITIAL_SEQUENCE: u16 = 4_096;

fn synthetic_h264_access_unit() -> Vec<u8> {
    let mut access_unit = vec![
        // SPS, PPS, then an IDR NALU, all in Annex-B form.
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1f, 0xe5, 0x88, 0x68, 0x00, 0x00, 0x00, 0x01,
        0x68, 0xce, 0x3c, 0x80, 0x00, 0x00, 0x00, 0x01, 0x65,
    ];
    access_unit.extend((0..640).map(|index| (index as u8).wrapping_mul(37)));
    access_unit
}

fn frame(sequence: u64, timestamp: u64, keyframe: bool) -> EncodedVideoFrame {
    EncodedVideoFrame::new(
        VideoCodec::H264,
        sequence,
        timestamp,
        1_920,
        1_080,
        keyframe,
        synthetic_h264_access_unit(),
        Instant::now() + Duration::from_secs(1),
    )
}

fn packet(sequence_number: u16, timestamp: u32, marker: bool, payload: &'static [u8]) -> Packet {
    Packet {
        header: Header {
            version: 2,
            marker,
            payload_type: H264_PAYLOAD_TYPE,
            sequence_number,
            timestamp,
            ssrc: SSRC,
            ..Default::default()
        },
        payload: Bytes::from_static(payload),
    }
}

#[test]
fn packetizer_fragments_annex_b_idr_and_reassembler_returns_the_same_frame() {
    let original = frame(7, 90_000, true);
    let mut packetizer = RtpPacketizer::new(RTP_MTU, H264_PAYLOAD_TYPE, SSRC, INITIAL_SEQUENCE);
    let packets = packetizer
        .packetize(&original)
        .expect("synthetic H.264 access unit packetizes");

    assert!(packets.len() > 2, "the IDR NALU must be fragmented");
    assert!(packets
        .iter()
        .all(|packet| packet.payload.len() + 12 <= RTP_MTU));
    assert_eq!(packets[0].header.sequence_number, INITIAL_SEQUENCE);
    assert!(packets
        .windows(2)
        .all(|window| window[1].header.sequence_number
            == window[0].header.sequence_number.wrapping_add(1)));
    assert!(packets
        .iter()
        .all(|packet| packet.header.timestamp == original.timestamp as u32));
    assert!(packets[..packets.len() - 1]
        .iter()
        .all(|packet| !packet.header.marker));
    assert!(packets.last().expect("at least one packet").header.marker);

    let mut reassembler = RtpReassembler::new();
    let mut reassembled = None;
    for packet in &packets {
        let completed = reassembler
            .push(packet)
            .expect("well-formed RTP packet is accepted");
        if packet.header.marker {
            reassembled = completed;
        } else {
            assert!(completed.is_none(), "a frame completes only at marker");
        }
    }

    let reassembled = reassembled.expect("marker completes the encoded frame");
    assert_eq!(reassembled.codec, VideoCodec::H264);
    assert_eq!(reassembled.timestamp, original.timestamp);
    assert_eq!(reassembled.width, original.width);
    assert_eq!(reassembled.height, original.height);
    assert_eq!(reassembled.keyframe, original.keyframe);
    assert_eq!(reassembled.payload, original.payload);
}

#[test]
fn packetizer_advances_sequence_between_frames_but_keeps_each_frame_timestamp() {
    let mut packetizer = RtpPacketizer::new(RTP_MTU, H264_PAYLOAD_TYPE, SSRC, INITIAL_SEQUENCE);
    let first = packetizer
        .packetize(&frame(1, 90_000, true))
        .expect("first frame packetizes");
    let second = packetizer
        .packetize(&frame(2, 96_000, false))
        .expect("second frame packetizes");

    assert_eq!(first[0].header.sequence_number, INITIAL_SEQUENCE);
    assert_eq!(
        second[0].header.sequence_number,
        INITIAL_SEQUENCE.wrapping_add(first.len() as u16)
    );
    assert!(first.iter().all(|packet| packet.header.timestamp == 90_000));
    assert!(second
        .iter()
        .all(|packet| packet.header.timestamp == 96_000));
    assert!(first.last().expect("first packets").header.marker);
    assert!(second.last().expect("second packets").header.marker);
}

#[test]
fn reassembler_rejects_malformed_and_stale_rtp_fragments() {
    let mut malformed_reassembler = RtpReassembler::new();
    // FU-A requires both the FU indicator and FU header; a one-byte payload is
    // malformed and must not create pending frame state.
    assert!(malformed_reassembler
        .push(&packet(INITIAL_SEQUENCE, 90_000, true, &[0x7c]))
        .is_err());

    let original = frame(9, 90_000, true);
    let mut packetizer = RtpPacketizer::new(RTP_MTU, H264_PAYLOAD_TYPE, SSRC, INITIAL_SEQUENCE);
    let packets = packetizer
        .packetize(&original)
        .expect("synthetic frame packetizes");
    let mut reassembler = RtpReassembler::new();
    for packet in &packets {
        reassembler
            .push(packet)
            .expect("baseline frame is accepted");
    }

    // Replaying a packet from an already completed timestamp is stale, even
    // though its bytes are otherwise valid RTP/H.264.
    assert!(reassembler.push(&packets[0]).is_err());
}

#[test]
fn released_endpoint_reassembler_does_not_inherit_frame_sequence() {
    let mut packetizer = RtpPacketizer::new(RTP_MTU, H264_PAYLOAD_TYPE, SSRC, INITIAL_SEQUENCE);
    let first_packets = packetizer
        .packetize(&frame(1, 90_000, true))
        .expect("first frame packetizes");
    let second_packets = packetizer
        .packetize(&frame(2, 96_000, true))
        .expect("second frame packetizes");
    let replacement_packets = packetizer
        .packetize(&frame(3, 102_000, true))
        .expect("replacement frame packetizes");

    let mut reassembler = RtpReassembler::new();
    let first = first_packets
        .iter()
        .find_map(|packet| reassembler.push(packet).expect("first packet is valid"))
        .expect("first frame completes");
    let second = second_packets
        .iter()
        .find_map(|packet| reassembler.push(packet).expect("second packet is valid"))
        .expect("second frame completes");
    assert_eq!(first.sequence, 0);
    assert_eq!(second.sequence, 1);

    reassembler.clear_for_endpoint_release();
    let replacement = replacement_packets
        .iter()
        .find_map(|packet| {
            reassembler
                .push(packet)
                .expect("replacement packet is valid")
        })
        .expect("replacement frame completes");
    assert_eq!(replacement.sequence, 0);
}
