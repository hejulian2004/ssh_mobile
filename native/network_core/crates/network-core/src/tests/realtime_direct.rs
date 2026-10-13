use super::*;
use crate::tests::{
    configure_runtime_for_test, send_and_expect_accepted, upsert_command_with_routes,
    wait_for_session_connected,
};
use crate::NetworkRuntime;
use network_identity::DeviceIdentity;
use network_protocol::{
    network_command, ConnectPeerCommand, NetworkCommand, NETWORK_PROTOCOL_VERSION,
};
use std::time::Duration;

struct Pair {
    a: NetworkRuntime,
    b: NetworkRuntime,
    root: std::path::PathBuf,
    sa: Arc<RuntimeState>,
    sb: Arc<RuntimeState>,
}

impl Pair {
    fn new() -> Self {
        let a = NetworkRuntime::new().unwrap();
        let b = NetworkRuntime::new().unwrap();
        a.start().unwrap();
        b.start().unwrap();
        let root =
            std::env::temp_dir().join(format!("direct-signal-security-{}", rand::random::<u64>()));
        let aa = configure_runtime_for_test(
            &a,
            "unit-a",
            [61; 32],
            [71; 32],
            "127.0.0.1:0".parse().unwrap(),
            root.join("a"),
        );
        let ab = configure_runtime_for_test(
            &b,
            "unit-b",
            [62; 32],
            [72; 32],
            "127.0.0.1:0".parse().unwrap(),
            root.join("b"),
        );
        let ka = DeviceIdentity::from_private_keys("unit-a".into(), [61; 32], [71; 32])
            .public_identity_key()
            .to_bytes();
        let kb = DeviceIdentity::from_private_keys("unit-b".into(), [62; 32], [72; 32])
            .public_identity_key()
            .to_bytes();
        send_and_expect_accepted(
            &a,
            upsert_command_with_routes("unit-pair-b", "unit-b", ab, kb, [72; 32], true, false),
        );
        send_and_expect_accepted(
            &b,
            upsert_command_with_routes("unit-pair-a", "unit-a", aa, ka, [71; 32], true, false),
        );
        send_and_expect_accepted(
            &a,
            NetworkCommand {
                command_id: "unit-connect".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                    peer_id: "unit-b".into(),
                    intent: 0,
                    communication_class: 0,
                })),
            },
        );
        assert!(wait_for_session_connected(
            &a,
            "unit-b",
            Duration::from_secs(10)
        ));
        assert!(wait_for_session_connected(
            &b,
            "unit-a",
            Duration::from_secs(10)
        ));
        let sa = a.state.lock().unwrap().clone().unwrap();
        let sb = b.state.lock().unwrap().clone().unwrap();
        Self { a, b, root, sa, sb }
    }

    fn frame(&self, signal: &RealtimeSignal) -> Vec<u8> {
        self.a.handle().block_on(async {
            let key = self
                .sa
                .connection_sessions
                .current_session_id("unit-b")
                .await
                .unwrap()
                .wire_key();
            let mut bytes = header(&key).unwrap();
            bytes.extend(
                self.sa
                    .encrypt_application_payload("unit-b", &key, &bytes, &signal.encode_to_vec())
                    .await
                    .unwrap(),
            );
            bytes
        })
    }
}
impl Drop for Pair {
    fn drop(&mut self) {
        self.a.stop().unwrap();
        self.b.stop().unwrap();
        std::fs::remove_dir_all(&self.root).ok();
    }
}

fn close_signal() -> RealtimeSignal {
    RealtimeSignal {
        request_id: 1,
        realtime_id: "00112233445566778899aabbccddeeff".into(),
        target_device_id: "unit-b".into(),
        source_device_id: "unit-a".into(),
        kind: 5,
        revision: 1,
        payload: super::super::wire::encode_realtime_signal_payload(
            "00112233445566778899aabbccddeeff",
            &[],
        )
        .unwrap(),
    }
}

#[test]
fn direct_signals_reject_forgery_replay_stale_binding_and_wrong_recipient() {
    let pair = Pair::new();
    let mut forged = close_signal();
    forged.source_device_id = "forged".into();
    let forged_frame = pair.frame(&forged);
    assert!(
        pair.b
            .handle()
            .block_on(handle_direct_signal(&pair.sb, "unit-a", &forged_frame))
            .is_err(),
        "forged source"
    );
    let mut zero = close_signal();
    zero.revision = 0;
    let mut wrong = close_signal();
    wrong.target_device_id = "wrong".into();
    let mut invalid = close_signal();
    invalid.realtime_id = "invalid".into();
    for signal in [zero, wrong, invalid] {
        let frame = pair.frame(&signal);
        assert!(pair
            .b
            .handle()
            .block_on(handle_direct_signal(&pair.sb, "unit-a", &frame))
            .is_err());
    }
    let frame = pair.frame(&close_signal());
    assert!(pair
        .b
        .handle()
        .block_on(handle_direct_signal(&pair.sb, "unit-a", &frame))
        .is_ok());
    assert!(
        pair.b
            .handle()
            .block_on(handle_direct_signal(&pair.sb, "unit-a", &frame))
            .is_err(),
        "nonce replay"
    );
    let mut tampered = pair.frame(&close_signal());
    *tampered.last_mut().unwrap() ^= 1;
    assert!(pair
        .b
        .handle()
        .block_on(handle_direct_signal(&pair.sb, "unit-a", &tampered))
        .is_err());
    let mut stale = header("stale-session").unwrap();
    stale.extend_from_slice(b"ciphertext");
    assert!(pair
        .b
        .handle()
        .block_on(handle_direct_signal(&pair.sb, "unit-a", &stale))
        .is_err());
    assert!(pair
        .b
        .handle()
        .block_on(handle_direct_signal(&pair.sb, "unit-a", &[]))
        .is_err());
    assert!(pair
        .b
        .handle()
        .block_on(handle_direct_signal(&pair.sb, "unpaired", &frame))
        .is_err());
}

#[test]
fn rejected_direct_signal_publishes_bounded_diagnostics_without_changing_state() {
    let pair = Pair::new();
    let mut frame = pair.frame(&close_signal());
    *frame.last_mut().unwrap() ^= 1;
    assert!(pair
        .b
        .handle()
        .block_on(handle_direct_signal(&pair.sb, "unit-a", &frame))
        .is_err());
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    let mut found = false;
    while std::time::Instant::now() < deadline {
        if let Some(event) = pair.b.poll_event(100) {
            if let Some(network_protocol::network_event::Payload::PeerDiagnostics(diagnostics)) =
                event.payload
            {
                if let Some(error) = diagnostics.last_error {
                    assert_eq!(
                        error.message,
                        "Screen-share direct rejection: authentication"
                    );
                    assert_eq!(error.operation, "receive_realtime_signal");
                    found = true;
                    break;
                }
            }
        }
    }
    assert!(found, "rejection diagnostics must reach the App logger");
    assert!(pair
        .b
        .handle()
        .block_on(async { pair.sb.realtime.lock().await.sessions.is_empty() }));
}

#[test]
fn direct_sender_fails_closed_when_identity_or_payload_is_invalid() {
    let pair = Pair::new();
    pair.a.handle().block_on(async {
        let mut signal = OutboundSignal {
            realtime_id: "00112233445566778899aabbccddeeff".into(),
            peer_id: "unit-b".into(),
            shared_session_instance_id: "00112233445566778899aabbccddeeff".into(),
            kind: network_protocol::RealtimeSignalKind::WebRtcClose,
            revision: 1,
            payload: vec![],
        };
        assert!(try_send_direct(&pair.sa, &signal).await.unwrap());
        signal.peer_id = "unpaired".into();
        assert!(!try_send_direct(&pair.sa, &signal).await.unwrap());
        signal.peer_id = "unit-b".into();
        signal.payload = vec![0; MAX_FRAME];
        assert!(try_send_direct(&pair.sa, &signal).await.is_err());
        signal.payload.clear();
        signal.shared_session_instance_id = "bad".into();
        assert!(try_send_direct(&pair.sa, &signal).await.is_err());
        signal.shared_session_instance_id = "00112233445566778899aabbccddeeff".into();
        let identity = pair.sa.lifecycle.identity.write().await.take();
        assert!(try_send_direct(&pair.sa, &signal).await.is_err());
        *pair.sa.lifecycle.identity.write().await = identity;
    });
}

#[test]
fn direct_signal_frame_codec_is_bounded_and_session_bound() {
    assert!(header("").is_err());
    assert!(header(&"x".repeat(129)).is_err());
    let mut bytes = header("session").unwrap();
    bytes.extend_from_slice(b"encrypted");
    let (session, aad, payload) = split_frame(&bytes).unwrap();
    assert_eq!(session, "session");
    assert_eq!(aad, header("session").unwrap());
    assert_eq!(payload, b"encrypted");
    for invalid in [
        vec![],
        vec![0; 8],
        vec![0; MAX_FRAME + 1],
        b"SMRS2\0\0x".to_vec(),
        b"SMRS2\0\x81x".to_vec(),
        b"SMRS2\0\x07session".to_vec(),
        b"SMRS2\0\x01\xffx".to_vec(),
    ] {
        assert!(split_frame(&invalid).is_err());
    }
}
