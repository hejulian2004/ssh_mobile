use std::time::{Duration, Instant};

use crate::media::{
    EncodedVideoFrame, KeyframeRequestReason, VideoCodec, VideoEnqueueResult, VideoFrameError,
    VideoQueue, MAX_ENCODED_VIDEO_FRAME_BYTES, SCREEN_VIDEO_QUEUE_CAPACITY,
};

fn frame(
    codec: VideoCodec,
    sequence: u64,
    timestamp_ms: u64,
    keyframe: bool,
    expires_at: Instant,
    payload: Vec<u8>,
) -> EncodedVideoFrame {
    EncodedVideoFrame::new(
        codec,
        sequence,
        timestamp_ms,
        1_920,
        1_080,
        keyframe,
        payload,
        expires_at,
    )
}

fn h264_frame(sequence: u64, timestamp_ms: u64, keyframe: bool, now: Instant) -> EncodedVideoFrame {
    frame(
        VideoCodec::H264,
        sequence,
        timestamp_ms,
        keyframe,
        now + Duration::from_secs(1),
        vec![0, 0, 0, 1, 0x65, sequence as u8],
    )
}

fn drain_sequences(queue: &mut VideoQueue, now: Instant) -> Vec<u64> {
    let mut sequences = Vec::new();
    while let Some(frame) = queue.pop(now) {
        sequences.push(frame.sequence);
    }
    sequences
}

#[test]
fn h264_is_the_only_codec_accepted_for_screen_video_frames() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();

    assert_eq!(
        queue.enqueue(h264_frame(1, 1_000, true, now), now),
        Ok(VideoEnqueueResult::Accepted)
    );
    for codec in [VideoCodec::Vp8, VideoCodec::Av1] {
        let result = queue.enqueue(
            frame(
                codec,
                2,
                1_001,
                false,
                now + Duration::from_secs(1),
                vec![0, 0, 0, 1, 0x65, 2],
            ),
            now,
        );
        assert!(matches!(
            result,
            Err(VideoFrameError::UnsupportedCodec(actual)) if actual == codec
        ));
    }

    assert_eq!(drain_sequences(&mut queue, now), vec![1]);
}

#[test]
fn oversized_frame_is_rejected_before_queue_commit() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    queue
        .enqueue(h264_frame(1, 1_000, true, now), now)
        .expect("baseline keyframe is accepted");

    let oversized = frame(
        VideoCodec::H264,
        2,
        1_001,
        false,
        now + Duration::from_secs(1),
        vec![0; MAX_ENCODED_VIDEO_FRAME_BYTES + 1],
    );
    assert!(matches!(
        queue.enqueue(oversized, now),
        Err(VideoFrameError::PayloadTooLarge)
    ));
    assert_eq!(queue.len(), 1, "rejection must not mutate pending video");
    assert_eq!(drain_sequences(&mut queue, now), vec![1]);
}

#[test]
fn malformed_annex_b_is_rejected_at_enqueue_boundary() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    let malformed = frame(
        VideoCodec::H264,
        1,
        1_000,
        true,
        now + Duration::from_secs(1),
        vec![0x65, 0x01, 0x02],
    );

    assert!(matches!(
        queue.enqueue(malformed, now),
        Err(VideoFrameError::InvalidAccessUnit)
    ));
    assert!(queue.is_empty());

    let empty_nalu = frame(
        VideoCodec::H264,
        2,
        1_001,
        true,
        now + Duration::from_secs(1),
        vec![0, 0, 0, 1],
    );
    assert!(matches!(
        queue.enqueue(empty_nalu, now),
        Err(VideoFrameError::InvalidAccessUnit)
    ));
}

#[test]
fn screen_video_queue_capacity_is_fixed_at_three_frames() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();

    assert_eq!(SCREEN_VIDEO_QUEUE_CAPACITY, 3);
    for sequence in 1..=SCREEN_VIDEO_QUEUE_CAPACITY as u64 {
        queue
            .enqueue(h264_frame(sequence, sequence, sequence == 1, now), now)
            .expect("frame fits the fixed queue");
    }

    assert_eq!(queue.len(), SCREEN_VIDEO_QUEUE_CAPACITY);
}

#[test]
fn stale_frame_is_dropped_before_queue_commit() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    let stale = frame(
        VideoCodec::H264,
        1,
        1_000,
        true,
        now - Duration::from_millis(1),
        vec![0, 0, 0, 1, 0x65, 1],
    );

    assert_eq!(
        queue.enqueue(stale, now),
        Ok(VideoEnqueueResult::DroppedStale)
    );
    assert_eq!(queue.len(), 0);
}

#[test]
fn overflow_discards_the_oldest_delta_before_a_recovery_keyframe() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    queue.enqueue(h264_frame(1, 1_000, true, now), now).unwrap();
    queue
        .enqueue(h264_frame(2, 1_001, false, now), now)
        .unwrap();
    queue
        .enqueue(h264_frame(3, 1_002, false, now), now)
        .unwrap();

    queue
        .enqueue(h264_frame(4, 1_003, false, now), now)
        .expect("a newer delta may replace an older delta");

    assert_eq!(drain_sequences(&mut queue, now), vec![1, 3, 4]);
}

#[test]
fn recovery_keyframe_is_preserved_when_an_unsafe_delta_is_dropped() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    queue
        .enqueue(h264_frame(10, 2_000, true, now), now)
        .unwrap();

    // A delta older than the queued recovery point cannot be decoded safely.
    let unsafe_delta = h264_frame(9, 1_999, false, now);
    assert_eq!(
        queue.enqueue(unsafe_delta, now),
        Ok(VideoEnqueueResult::DroppedIncoming)
    );
    assert_eq!(drain_sequences(&mut queue, now), vec![10]);
}

#[test]
fn disconnect_clears_pending_video_and_requests_a_keyframe() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    queue.enqueue(h264_frame(1, 1_000, true, now), now).unwrap();
    queue
        .enqueue(h264_frame(2, 1_001, false, now), now)
        .unwrap();

    queue.on_disconnect();

    assert_eq!(queue.len(), 0);
    assert_eq!(
        queue.take_keyframe_request(),
        Some(KeyframeRequestReason::Disconnected)
    );
    assert_eq!(queue.take_keyframe_request(), None);
}

#[test]
fn endpoint_clear_discards_frames_ordering_and_keyframe_request() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    queue.enqueue(h264_frame(1, 1_000, true, now), now).unwrap();
    queue.request_keyframe(KeyframeRequestReason::PacketLoss);

    queue.clear();

    assert_eq!(queue.len(), 0);
    assert_eq!(queue.take_keyframe_request(), None);
    assert_eq!(
        queue.enqueue(h264_frame(1, 1_000, true, now), now),
        Ok(VideoEnqueueResult::Accepted),
        "a replacement endpoint starts a fresh ordering generation"
    );
}

#[test]
fn decoder_reset_and_ice_restart_each_request_a_keyframe() {
    let mut queue = VideoQueue::new();

    queue.request_keyframe(KeyframeRequestReason::DecoderReset);
    assert_eq!(
        queue.take_keyframe_request(),
        Some(KeyframeRequestReason::DecoderReset)
    );

    queue.request_keyframe(KeyframeRequestReason::IceRestart);
    assert_eq!(
        queue.take_keyframe_request(),
        Some(KeyframeRequestReason::IceRestart)
    );
}

#[test]
fn sequence_and_timestamp_must_be_monotonic_even_for_keyframes() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    queue
        .enqueue(h264_frame(10, 1_000, true, now), now)
        .expect("baseline frame");

    assert_eq!(
        queue.enqueue(h264_frame(9, 1_001, true, now), now),
        Ok(VideoEnqueueResult::DroppedIncoming),
        "an older keyframe cannot replace newer pending content"
    );
    assert_eq!(
        queue.enqueue(h264_frame(11, 1_000, false, now), now),
        Ok(VideoEnqueueResult::DroppedIncoming),
        "a repeated timestamp cannot reorder the native media stream"
    );
    assert_eq!(drain_sequences(&mut queue, now), vec![10]);
}

#[test]
fn timestamp_and_resolution_limits_reject_before_queue_commit() {
    let now = Instant::now();
    let mut queue = VideoQueue::new();
    let timestamp_overflow = h264_frame(1, u64::from(u32::MAX) + 1, true, now);
    assert!(matches!(
        queue.enqueue(timestamp_overflow, now),
        Err(VideoFrameError::TimestampOutOfRange)
    ));
    let invalid_resolution = EncodedVideoFrame::new(
        VideoCodec::H264,
        1,
        1,
        0,
        1_080,
        true,
        vec![0, 0, 0, 1, 0x65, 1],
        now + Duration::from_secs(1),
    );
    assert!(matches!(
        queue.enqueue(invalid_resolution, now),
        Err(VideoFrameError::InvalidResolution)
    ));
    assert_eq!(queue.len(), 0);
}
