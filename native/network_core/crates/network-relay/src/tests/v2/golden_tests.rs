//! Golden fixture byte-comparison against `protocol/relay_v2_testdata/`.
//!
//! The fixtures are frozen (relay_v2.proto + generate_fixtures.py) and lock the
//! wire contract across Rust/Go. These tests re-encode the same deterministic
//! seed values with this crate's prost codec and assert byte-identity with the
//! committed `.bin` frames. If the fixture directory is absent (non-standard
//! checkout) the test is skipped rather than failed.

use std::path::PathBuf;

use super::proto::*;

/// 与 `protocol/relay_v2_testdata/generate_fixtures.py` 的 SEED 保持一致。
const EPOCH_A_HIGH: u64 = 0x6A09E667;
const EPOCH_A_LOW: u64 = 0xBB67AE85;
const EPOCH_B_HIGH: u64 = 0x9E3779B9;
const EPOCH_B_LOW: u64 = 0x7F4A7C15;
const REVISION_A: u32 = 7;
const REVISION_B: u32 = 3;
const REQUEST_ID: u64 = 1001;
const RESPONDER_REQUEST_ID: u64 = 2002;
const ATTEMPT_ID: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
const DEVICE_A: &str = "11111111111111111111111111111111";
const DEVICE_B: &str = "22222222222222222222222222222222";
const RESERVATION_ID: &str = "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d";
const REALTIME_ID: &str = "rt-9f8e7d6c5b4a39281706f5e4d3c2b1a0";
const SERVER_TIME_MS: i64 = 1723840800123;
const SENT_AT_MS: i64 = 1723840820123;
const PUBLISHED_AT_MS: i64 = 1723840800456;
const EXPIRES_AT_MS: i64 = 1723840860123;
const SEQUENCE: u64 = 42;
const CANDIDATE_A: &str = "cand:type=host;ip=192.168.1.10;port=54321;proto=quic";
const CANDIDATE_B: &str = "cand:type=srflx;ip=203.0.113.7;port=3478;proto=udp";
const ENDPOINT: &str = "wss://relay.example.test/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d";
const PROTOCOL_ERROR_MESSAGE: &str = "revision already published under a different runtime epoch";

fn epoch_a() -> RuntimeEpoch {
    RuntimeEpoch {
        high: EPOCH_A_HIGH,
        low: EPOCH_A_LOW,
    }
}

fn epoch_b() -> RuntimeEpoch {
    RuntimeEpoch {
        high: EPOCH_B_HIGH,
        low: EPOCH_B_LOW,
    }
}

fn snapshot_a() -> DiscoverySnapshot {
    DiscoverySnapshot {
        runtime_epoch: Some(epoch_a()),
        revision: REVISION_A,
        transport_capabilities: vec![1, 2, 6], // QUIC, TCP, RELAY_DATA
        candidate_bundle: Some(CandidateBundle {
            candidates: vec![
                CANDIDATE_A.as_bytes().to_vec(),
                CANDIDATE_B.as_bytes().to_vec(),
            ],
        }),
        published_at_ms: PUBLISHED_AT_MS,
    }
}

fn snapshot_b() -> DiscoverySnapshot {
    DiscoverySnapshot {
        runtime_epoch: Some(epoch_b()),
        revision: REVISION_B,
        transport_capabilities: vec![1, 6], // QUIC, RELAY_DATA
        candidate_bundle: Some(CandidateBundle {
            candidates: vec![CANDIDATE_A.as_bytes().to_vec()],
        }),
        published_at_ms: PUBLISHED_AT_MS,
    }
}

fn fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../protocol/relay_v2_testdata")
}

fn assert_matches_golden(file: &str, encoded: &[u8]) {
    let path = fixtures_root().join(file);
    let Some(golden) = std::fs::read(&path).ok() else {
        eprintln!(
            "skipping golden fixture {} (missing {})",
            file,
            path.display()
        );
        return;
    };
    assert_eq!(
        golden, encoded,
        "wire bytes drift from the frozen golden fixture {file}"
    );
    // 再验证自解码一致，保证编码/解码互为逆。
    if file.ends_with(".control.bin") {
        decode_control_frame(encoded)
            .unwrap_or_else(|error| panic!("fixture {file} does not round-trip: {error}"));
    } else {
        decode_data_frame(encoded)
            .unwrap_or_else(|error| panic!("fixture {file} does not round-trip: {error}"));
    }
}

#[test]
fn ready_frame_matches_the_frozen_golden_fixture() {
    let frame = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::Ready(Ready {
            protocol_version: RELAY_V2_VERSION,
            device_id: DEVICE_A.into(),
            server_time_ms: SERVER_TIME_MS,
            heartbeat_interval_s: HEARTBEAT_INTERVAL_S,
            presence_ttl_s: PRESENCE_TTL_S,
        })),
    };
    assert_matches_golden(
        "ready.control.bin",
        &encode_control_frame(&frame).expect("encode"),
    );
}

#[test]
fn heartbeat_frames_match_the_frozen_golden_fixtures() {
    let heartbeat = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::Heartbeat(Heartbeat {
            request_id: REQUEST_ID,
            sent_at_ms: SENT_AT_MS,
        })),
    };
    assert_matches_golden(
        "heartbeat.control.bin",
        &encode_control_frame(&heartbeat).expect("encode"),
    );

    let ack = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::HeartbeatAck(HeartbeatAck {
            request_id: REQUEST_ID,
            server_time_ms: SENT_AT_MS,
        })),
    };
    assert_matches_golden(
        "heartbeat_ack.control.bin",
        &encode_control_frame(&ack).expect("encode"),
    );
}

#[test]
fn discovery_frames_match_the_frozen_golden_fixtures() {
    let publish = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::DiscoveryPublish(DiscoveryPublish {
            request_id: REQUEST_ID,
            snapshot: Some(snapshot_a()),
        })),
    };
    assert_matches_golden(
        "discovery_publish.control.bin",
        &encode_control_frame(&publish).expect("encode"),
    );

    let ack = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::DiscoveryAck(DiscoveryAck {
            request_id: REQUEST_ID,
            runtime_epoch: Some(epoch_a()),
            revision: REVISION_A,
        })),
    };
    assert_matches_golden(
        "discovery_ack.control.bin",
        &encode_control_frame(&ack).expect("encode"),
    );
}

#[test]
fn resolve_frames_match_the_frozen_golden_fixtures() {
    for (file, status, discovery, retry) in [
        ("resolve_ready.control.bin", 1, Some(snapshot_a()), 0),
        ("resolve_offline.control.bin", 2, None, 0),
        ("resolve_not_ready.control.bin", 3, None, 2000),
        ("resolve_unknown.control.bin", 4, None, 5000),
    ] {
        let frame = RelayFrame {
            version: RELAY_V2_VERSION,
            kind: Some(relay_frame::Kind::ResolvePeerResponse(
                ResolvePeerResponse {
                    request_id: REQUEST_ID,
                    status,
                    discovery,
                    retry_after_ms: retry,
                },
            )),
        };
        assert_matches_golden(file, &encode_control_frame(&frame).expect("encode"));
    }
}

#[test]
fn connectivity_frames_match_the_frozen_golden_fixtures() {
    let offer = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::ConnectivityOffer(ConnectivityOffer {
            request_id: REQUEST_ID,
            attempt_id: ATTEMPT_ID.into(),
            initiator_device_id: DEVICE_A.into(),
            initiator_runtime_epoch: Some(epoch_a()),
            initiator_revision: REVISION_A,
            initiator_snapshot: Some(snapshot_a()),
        })),
    };
    assert_matches_golden(
        "connectivity_offer.control.bin",
        &encode_control_frame(&offer).expect("encode"),
    );

    let answer = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::ConnectivityAnswer(ConnectivityAnswer {
            request_id: RESPONDER_REQUEST_ID,
            attempt_id: ATTEMPT_ID.into(),
            accepted: true,
            responder_device_id: DEVICE_B.into(),
            responder_runtime_epoch: Some(epoch_b()),
            responder_revision: REVISION_B,
            responder_snapshot: Some(snapshot_b()),
        })),
    };
    assert_matches_golden(
        "connectivity_answer.control.bin",
        &encode_control_frame(&answer).expect("encode"),
    );
}

#[test]
fn presence_hint_frames_match_the_frozen_golden_fixtures() {
    let snapshot = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::PresenceHintSnapshot(
            PresenceHintSnapshot {
                peers: vec![
                    PeerPresenceHint {
                        device_id: DEVICE_A.into(),
                        online: true,
                        runtime_epoch: Some(epoch_a()),
                        revision: REVISION_A,
                    },
                    PeerPresenceHint {
                        device_id: DEVICE_B.into(),
                        online: true,
                        runtime_epoch: Some(epoch_b()),
                        revision: REVISION_B,
                    },
                ],
                published_at_ms: PUBLISHED_AT_MS,
            },
        )),
    };
    assert_matches_golden(
        "presence_hint_snapshot.control.bin",
        &encode_control_frame(&snapshot).expect("encode"),
    );

    let available = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::PeerAvailableHint(PeerAvailableHint {
            device_id: DEVICE_B.into(),
            runtime_epoch: Some(epoch_b()),
            revision: REVISION_B,
        })),
    };
    assert_matches_golden(
        "peer_available_hint.control.bin",
        &encode_control_frame(&available).expect("encode"),
    );

    let unavailable = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::PeerUnavailableHint(
            PeerUnavailableHint {
                device_id: DEVICE_B.into(),
                reason: "device offline".into(),
            },
        )),
    };
    assert_matches_golden(
        "peer_unavailable_hint.control.bin",
        &encode_control_frame(&unavailable).expect("encode"),
    );
}

#[test]
fn reservation_frames_match_the_frozen_golden_fixtures() {
    let request = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::RelayReserveRequest(
            RelayReserveRequest {
                request_id: REQUEST_ID,
                attempt_id: ATTEMPT_ID.into(),
                target_device_id: DEVICE_B.into(),
                desired_lifetime_s: RESERVATION_LIFETIME_S_DEFAULT,
            },
        )),
    };
    assert_matches_golden(
        "relay_reserve_request.control.bin",
        &encode_control_frame(&request).expect("encode"),
    );

    let response = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::RelayReserveResponse(
            RelayReserveResponse {
                request_id: REQUEST_ID,
                attempt_id: ATTEMPT_ID.into(),
                reservation_id: RESERVATION_ID.into(),
                relay_data_endpoint: ENDPOINT.into(),
                expires_at_ms: EXPIRES_AT_MS,
                local_token: (1..33).collect(),
            },
        )),
    };
    assert_matches_golden(
        "relay_reserve_response.control.bin",
        &encode_control_frame(&response).expect("encode"),
    );

    let incoming = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::IncomingRelayReservation(
            IncomingRelayReservation {
                attempt_id: ATTEMPT_ID.into(),
                reservation_id: RESERVATION_ID.into(),
                initiator_device_id: DEVICE_A.into(),
                relay_data_endpoint: ENDPOINT.into(),
                expires_at_ms: EXPIRES_AT_MS,
                local_token: (33..65).collect(),
            },
        )),
    };
    assert_matches_golden(
        "incoming_relay_reservation.control.bin",
        &encode_control_frame(&incoming).expect("encode"),
    );
}

#[test]
fn realtime_and_error_frames_match_the_frozen_golden_fixtures() {
    let signal = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::RealtimeSignal(RealtimeSignal {
            request_id: REQUEST_ID,
            realtime_id: REALTIME_ID.into(),
            target_device_id: DEVICE_B.into(),
            kind: 3, // REALTIME_SIGNAL_KIND_ICE_CANDIDATE
            revision: REVISION_A as u64,
            payload: b"sdp-mid=0;candidate:842163049 1 udp 1677729535 198.51.100.7 54321 typ srflx"
                .to_vec(),
            source_device_id: String::new(),
        })),
    };
    assert_matches_golden(
        "realtime_signal.control.bin",
        &encode_control_frame(&signal).expect("encode"),
    );

    let forwarded_signal = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::RealtimeSignal(RealtimeSignal {
            request_id: REQUEST_ID,
            realtime_id: REALTIME_ID.into(),
            target_device_id: DEVICE_B.into(),
            kind: 3, // REALTIME_SIGNAL_KIND_ICE_CANDIDATE
            revision: REVISION_A as u64,
            payload: b"sdp-mid=0;candidate:842163049 1 udp 1677729535 198.51.100.7 54321 typ srflx"
                .to_vec(),
            source_device_id: DEVICE_A.into(),
        })),
    };
    assert_matches_golden(
        "realtime_signal_forwarded.control.bin",
        &encode_control_frame(&forwarded_signal).expect("encode"),
    );

    let error = RelayFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_frame::Kind::ProtocolError(ProtocolError {
            request_id: REQUEST_ID,
            attempt_id: ATTEMPT_ID.into(),
            code: 7, // ERROR_CODE_EPOCH_CONFLICT
            message: PROTOCOL_ERROR_MESSAGE.into(),
        })),
    };
    assert_matches_golden(
        "protocol_error.control.bin",
        &encode_control_frame(&error).expect("encode"),
    );
}

#[test]
fn relay_data_frames_match_the_frozen_golden_fixtures() {
    let connect = RelayDataFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_data_frame::Kind::Connect(RelayDataConnect {
            reservation_id: RESERVATION_ID.into(),
            local_token: (1..33).collect(),
        })),
    };
    assert_matches_golden(
        "relay_data_connect.data.bin",
        &encode_data_frame(&connect).expect("encode"),
    );

    let payload = RelayDataFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_data_frame::Kind::Payload(RelayDataPayload {
            sequence: SEQUENCE,
            encrypted_payload: (65..129).collect(),
        })),
    };
    assert_matches_golden(
        "relay_data_payload.data.bin",
        &encode_data_frame(&payload).expect("encode"),
    );

    let close = RelayDataFrame {
        version: RELAY_V2_VERSION,
        kind: Some(relay_data_frame::Kind::Close(RelayDataClose {
            reason: 0,
            detail: String::new(),
        })),
    };
    assert_matches_golden(
        "relay_data_close.data.bin",
        &encode_data_frame(&close).expect("encode"),
    );
}
