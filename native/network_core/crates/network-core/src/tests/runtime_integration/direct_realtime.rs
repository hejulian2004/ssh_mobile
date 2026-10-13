/// A trusted direct connection must deliver the native Offer + consent without
/// any Relay configuration, then require an explicit claim before answering.
#[test]
fn direct_realtime_invitation_without_relay() {
    exercise_direct_realtime(false, false);
}

#[test]
fn direct_realtime_invitation_without_relay_over_tcp() {
    exercise_direct_realtime(true, false);
}

#[test]
fn direct_realtime_invitation_without_relay_wildcard_bind() {
    exercise_direct_realtime(false, true);
}

fn exercise_direct_realtime(tcp: bool, wildcard: bool) {
    use network_protocol::{StartRealtimeSessionCommand, SendRealtimeSignalCommand,
        RealtimeSignalKind, ScreenShareConsentV2, ScreenShareConsentDecision,
        ScreenShareConsentPurpose, ScreenShareMediaKind};
    use prost::Message as _;
    let a = NetworkRuntime::new().unwrap();
    let b = NetworkRuntime::new().unwrap();
    a.start().unwrap();
    b.start().unwrap();
    let root = std::env::temp_dir().join(format!("direct-realtime-{}", rand::random::<u64>()));
    let bind = if wildcard { "0.0.0.0:0" } else { "127.0.0.1:0" };
    let mut address_a = configure_runtime_for_test(&a, "direct-a", [41;32], [51;32], bind.parse().unwrap(), root.join("a"));
    let mut address_b = configure_runtime_for_test(&b, "direct-b", [42;32], [52;32], bind.parse().unwrap(), root.join("b"));
    address_a.set_ip("127.0.0.1".parse().unwrap()); address_b.set_ip("127.0.0.1".parse().unwrap());
    let key_a = DeviceIdentity::from_private_keys("direct-a".into(), [41;32], [51;32])
        .public_identity_key().to_bytes();
    let key_b = DeviceIdentity::from_private_keys("direct-b".into(), [42;32], [52;32])
        .public_identity_key().to_bytes();
    if tcp {
        let state = b.state.lock().unwrap().clone().unwrap();
        b.handle().block_on(async { state.lifecycle.endpoint.read().await.as_ref().unwrap()
            .close(quinn::VarInt::from_u32(0), b"force TCP fixture"); });
    }
    send_and_expect_accepted(&a, upsert_command_with_routes("pair-b", "direct-b", address_b, key_b, [52;32], true, false));
    send_and_expect_accepted(&b, upsert_command_with_routes("pair-a", "direct-a", address_a, key_a, [51;32], true, false));
    send_and_expect_accepted(&a, NetworkCommand { command_id: "direct-connect".into(), protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand { peer_id: "direct-b".into(), intent:0, communication_class:0 })) });
    assert!(wait_for_session_connected(&a, "direct-b", Duration::from_secs(20)));
    assert!(wait_for_session_connected(&b, "direct-a", Duration::from_secs(20)));
    let id = "00112233445566778899aabbccddeeff";
    send_and_expect_accepted(&a, NetworkCommand { command_id: "direct-realtime-start".into(), protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::StartRealtimeSession(StartRealtimeSessionCommand { screen_video: false,  realtime_id:id.into(), peer_id:"direct-b".into() })) });
    let event = poll_until(&a, Duration::from_secs(10), |e| matches!(e.payload,
        Some(network_event::Payload::RealtimeState(ref s)) if s.realtime_id == id && s.shared_session_instance_id.len() == 32)).expect("native negotiating identity");
    let Some(network_event::Payload::RealtimeState(snapshot)) = event.payload else { unreachable!() };
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    let request = ScreenShareConsentV2 { schema_version:2, operation_id:"direct-operation".into(), realtime_id:id.into(),
        shared_session_instance_id:snapshot.shared_session_instance_id, issued_at_ms:now, expires_at_ms:now+60000,
        decision:ScreenShareConsentDecision::Request as i32, sender_peer_id:"direct-a".into(),
        purpose:ScreenShareConsentPurpose::ScreenShare as i32, media:ScreenShareMediaKind::ScreenVideo as i32,
        requires_acceptance:true, action_revision:1 };
    send_and_expect_accepted(&a, NetworkCommand { command_id:"direct-consent".into(), protocol_version:NETWORK_PROTOCOL_VERSION,
        payload:Some(network_command::Payload::SendRealtimeSignal(SendRealtimeSignalCommand { realtime_id:id.into(), peer_id:"direct-b".into(),
            kind:RealtimeSignalKind::ScreenShareConsent as i32, revision:1, payload:request.encode_to_vec() })) });
    let incoming = poll_until(&b, Duration::from_secs(10), |e| matches!(e.payload,
        Some(network_event::Payload::RealtimeIncomingSessionOffer(ref s)) if s.realtime_id == id)).expect("direct invitation reaches recipient");
    let Some(network_event::Payload::RealtimeIncomingSessionOffer(offer)) = incoming.payload else { unreachable!() };
    assert_eq!(offer.authenticated_peer_id, "direct-a");
    assert!(!offer.claim_token.is_empty());
    assert!(poll_until(&b, Duration::from_millis(100), |e| matches!(e.payload,
        Some(network_event::Payload::RealtimeState(ref s)) if s.realtime_id == id)).is_none(), "no auto-answer before acceptance");
    send_and_expect_accepted(&b, NetworkCommand { command_id:"direct-accept-claim".into(), protocol_version:NETWORK_PROTOCOL_VERSION,
        payload:Some(network_command::Payload::ClaimIncomingRealtimeOffer(network_protocol::ClaimIncomingRealtimeOfferCommand {
            realtime_id:id.into(), peer_id:"direct-a".into(), claim_token:offer.claim_token })) });
    let mut accepted = request;
    accepted.decision = ScreenShareConsentDecision::Accept as i32;
    accepted.sender_peer_id = "direct-b".into();
    send_and_expect_accepted(&b, NetworkCommand { command_id:"direct-accept-consent".into(), protocol_version:NETWORK_PROTOCOL_VERSION,
        payload:Some(network_command::Payload::SendRealtimeSignal(SendRealtimeSignalCommand { realtime_id:id.into(), peer_id:"direct-a".into(),
            kind:RealtimeSignalKind::ScreenShareConsent as i32, revision:1, payload:accepted.encode_to_vec() })) });
    assert!(poll_until(&a, Duration::from_secs(10), |e| matches!(e.payload,
            Some(network_event::Payload::RealtimeSignal(ref s)) if s.kind == RealtimeSignalKind::ScreenShareConsent as i32
                && ScreenShareConsentV2::decode(s.payload.as_slice()).is_ok_and(|consent| consent.decision == ScreenShareConsentDecision::Accept as i32
                    && consent.sender_peer_id == "direct-b"))).is_some(), "accept returns over Direct");
    for runtime in [&a, &b] {
        assert!(poll_until(runtime, Duration::from_secs(10), |e| matches!(e.payload,
            Some(network_event::Payload::RealtimeState(ref s)) if s.realtime_id == id && s.state == network_protocol::RealtimeSessionState::Connected as i32)).is_some(), "Direct ICE/DTLS becomes connected");
    }
    a.stop().unwrap(); b.stop().unwrap();
    fs::remove_dir_all(root).ok();
}
