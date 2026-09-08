use super::*;
use prost::Message;

#[test]
fn network_error_code_additions_preserve_existing_values() {
    assert_eq!(NetworkErrorCode::IoError as i32, 10);
    assert_eq!(NetworkErrorCode::Cancelled as i32, 11);
    assert_eq!(NetworkErrorCode::CredentialExpired as i32, 12);
    assert_eq!(NetworkErrorCode::IdentityConflict as i32, 13);
}

#[test]
fn retry_disposition_round_trips_as_wire_values() {
    assert_eq!(RetryDisposition::Unspecified as i32, 0);
    assert_eq!(RetryDisposition::NoRetry as i32, 1);
    assert_eq!(RetryDisposition::RetryWithBackoff as i32, 2);
    assert_eq!(RetryDisposition::RetryAfter as i32, 3);
    assert_eq!(RetryDisposition::RefreshCredentialThenRetry as i32, 4);
    assert_eq!(
        RetryDisposition::try_from(4),
        Ok(RetryDisposition::RefreshCredentialThenRetry)
    );
    assert!(RetryDisposition::try_from(99).is_err());
}

#[test]
fn network_error_new_retry_fields_default_to_zero() {
    let error = NetworkError {
        code: NetworkErrorCode::CredentialExpired as i32,
        message: "credential expired".into(),
        operation: "connect".into(),
        peer_id: String::new(),
        retry_disposition: RetryDisposition::Unspecified as i32,
        retry_after_seconds: 0,
    };
    let encoded = error.encode_to_vec();
    let decoded = NetworkError::decode(encoded.as_slice()).expect("decode");
    assert_eq!(decoded.code, NetworkErrorCode::CredentialExpired as i32);
    assert_eq!(decoded.retry_disposition, 0);
    assert_eq!(decoded.retry_after_seconds, 0);
}

#[test]
fn network_error_retry_fields_round_trip() {
    let error = NetworkError {
        code: NetworkErrorCode::CredentialExpired as i32,
        message: "credential expired".into(),
        operation: "connect".into(),
        peer_id: "peer-a".into(),
        retry_disposition: RetryDisposition::RefreshCredentialThenRetry as i32,
        retry_after_seconds: 30,
    };
    let encoded = error.encode_to_vec();
    let decoded = NetworkError::decode(encoded.as_slice()).expect("decode");
    assert_eq!(
        decoded.retry_disposition,
        RetryDisposition::RefreshCredentialThenRetry as i32
    );
    assert_eq!(decoded.retry_after_seconds, 30);
    assert_eq!(decoded.peer_id, "peer-a");
}

#[test]
fn realtime_snapshot_event_round_trips_state_and_revision() {
    let event = RealtimeSnapshotEvent {
        realtime_id: "00112233445566778899aabbccddeeff".into(),
        peer_id: "peer-a".into(),
        state: RealtimeSessionState::Connected as i32,
        revision: 7,
        generation: 11,
        error: Some(NetworkError {
            code: NetworkErrorCode::IdentityConflict as i32,
            message: "identity conflict".into(),
            operation: "connect".into(),
            peer_id: "peer-a".into(),
            retry_disposition: RetryDisposition::NoRetry as i32,
            retry_after_seconds: 0,
        }),
    };
    let encoded = event.encode_to_vec();
    let decoded = RealtimeSnapshotEvent::decode(encoded.as_slice()).expect("decode");
    assert_eq!(decoded.realtime_id, "00112233445566778899aabbccddeeff");
    assert_eq!(decoded.peer_id, "peer-a");
    assert_eq!(decoded.state, RealtimeSessionState::Connected as i32);
    assert_eq!(decoded.revision, 7);
    assert_eq!(decoded.generation, 11);
    let error = decoded.error.expect("snapshot error");
    assert_eq!(error.code, NetworkErrorCode::IdentityConflict as i32);
    assert_eq!(error.retry_disposition, RetryDisposition::NoRetry as i32);
}

#[test]
fn peer_presence_snapshot_round_trips_peers_and_state() {
    let event = NetworkEvent {
        event_id: "presence-event".into(),
        timestamp_ms: 123,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerPresenceSnapshot(
            PeerPresenceSnapshotEvent {
                peers: vec![
                    PeerPresenceChangedEvent {
                        peer_id: "peer-a".into(),
                        generation: 3,
                        state: PeerPresenceState::Online as i32,
                    },
                    PeerPresenceChangedEvent {
                        peer_id: "peer-b".into(),
                        generation: 0,
                        state: PeerPresenceState::Offline as i32,
                    },
                ],
            },
        )),
    };
    let encoded = event.encode_to_vec();
    let decoded = NetworkEvent::decode(encoded.as_slice()).expect("decode");
    match decoded.payload {
        Some(network_event::Payload::PeerPresenceSnapshot(snapshot)) => {
            assert_eq!(snapshot.peers.len(), 2);
            assert_eq!(snapshot.peers[0].peer_id, "peer-a");
            assert_eq!(snapshot.peers[0].generation, 3);
            assert_eq!(snapshot.peers[0].state, PeerPresenceState::Online as i32);
            assert_eq!(snapshot.peers[1].state, PeerPresenceState::Offline as i32);
        }
        other => panic!("unexpected event payload: {other:?}"),
    }
}

#[test]
fn route_attempt_events_round_trip_causal_fallback_phases() {
    let event = NetworkEvent {
        event_id: "peer-a/route-attempt/attempt-a".into(),
        timestamp_ms: 123,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RouteAttemptChanged(
            RouteAttemptChangedEvent {
                peer_id: "peer-a".into(),
                attempt_id: "attempt-a".into(),
                phase: RouteAttemptPhase::RelayFallbackStarted as i32,
                route_type: RouteType::Relay as i32,
                error: Some(NetworkError {
                    code: NetworkErrorCode::QuicError as i32,
                    message: "direct refused".into(),
                    operation: "connect".into(),
                    peer_id: "peer-a".into(),
                    retry_disposition: RetryDisposition::Unspecified as i32,
                    retry_after_seconds: 0,
                }),
                command_id: "command-a".into(),
            },
        )),
    };
    let decoded = NetworkEvent::decode(event.encode_to_vec().as_slice()).expect("decode");
    let Some(network_event::Payload::RouteAttemptChanged(attempt)) = decoded.payload else {
        panic!("expected route attempt event");
    };
    assert_eq!(attempt.peer_id, "peer-a");
    assert_eq!(attempt.attempt_id, "attempt-a");
    assert_eq!(
        attempt.phase,
        RouteAttemptPhase::RelayFallbackStarted as i32
    );
    assert_eq!(attempt.route_type, RouteType::Relay as i32);
    assert_eq!(attempt.command_id, "command-a");
    assert_eq!(
        attempt.error.expect("direct error").code,
        NetworkErrorCode::QuicError as i32
    );
}

#[test]
fn communication_class_values_are_stable_wire_identifiers() {
    // §17：五种固定 CommunicationClass，值不允许漂移。
    assert_eq!(CommunicationClass::Unspecified as i32, 0);
    assert_eq!(CommunicationClass::ReliableStream as i32, 1);
    assert_eq!(CommunicationClass::ReliableMessage as i32, 2);
    assert_eq!(CommunicationClass::BulkTransfer as i32, 3);
    assert_eq!(CommunicationClass::UnreliableDatagram as i32, 4);
    assert_eq!(CommunicationClass::RealtimeMedia as i32, 5);
    assert_eq!(
        CommunicationClass::try_from(5),
        Ok(CommunicationClass::RealtimeMedia)
    );
    assert!(CommunicationClass::try_from(99).is_err());
}

#[test]
fn connect_peer_command_defaults_communication_class_to_unspecified() {
    let command = ConnectPeerCommand {
        peer_id: "peer-a".into(),
        intent: 0,
        communication_class: 0,
    };
    let encoded = command.encode_to_vec();
    let decoded = ConnectPeerCommand::decode(encoded.as_slice()).expect("decode");
    assert_eq!(
        decoded.communication_class,
        CommunicationClass::Unspecified as i32
    );
}

#[test]
fn ssh_stream_commands_and_events_round_trip_through_the_wire() {
    let handle = StreamHandle {
        opener_device_id: "device-a".into(),
        stream_id: 7,
    };
    let open = NetworkCommand {
        command_id: "ssh-open".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamOpen(
            SshStreamOpenCommand {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
                service: "ssh".into(),
            },
        )),
    };
    let decoded = NetworkCommand::decode(open.encode_to_vec().as_slice()).expect("decode open");
    match decoded.payload {
        Some(network_command::Payload::SshStreamOpen(open)) => {
            assert_eq!(open.peer_id, "peer-a");
            assert_eq!(open.handle.as_ref().map(|handle| handle.stream_id), Some(7));
            assert_eq!(
                open.handle
                    .as_ref()
                    .map(|handle| handle.opener_device_id.as_str()),
                Some("device-a")
            );
            assert_eq!(open.service, "ssh");
        }
        other => panic!("unexpected command payload: {other:?}"),
    }

    let data = NetworkCommand {
        command_id: "ssh-data".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamData(
            SshStreamDataCommand {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
                data: b"SSH-bytes".to_vec(),
            },
        )),
    };
    let decoded = NetworkCommand::decode(data.encode_to_vec().as_slice()).expect("decode data");
    match decoded.payload {
        Some(network_command::Payload::SshStreamData(data)) => {
            assert_eq!(data.handle.as_ref().map(|handle| handle.stream_id), Some(7));
            assert_eq!(
                data.handle
                    .as_ref()
                    .map(|handle| handle.opener_device_id.as_str()),
                Some("device-a")
            );
            assert_eq!(data.data, b"SSH-bytes");
        }
        other => panic!("unexpected command payload: {other:?}"),
    }

    let close = NetworkCommand {
        command_id: "ssh-close".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SshStreamClose(
            SshStreamCloseCommand {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
            },
        )),
    };
    let decoded = NetworkCommand::decode(close.encode_to_vec().as_slice()).expect("decode close");
    assert!(matches!(
        decoded.payload,
        Some(network_command::Payload::SshStreamClose(close)) if close.handle.as_ref().is_some_and(|handle| handle.stream_id == 7 && handle.opener_device_id == "device-a")
    ));

    let received = NetworkEvent {
        event_id: "ssh-recv".into(),
        timestamp_ms: 123,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::SshStreamDataReceived(
            SshStreamDataReceivedEvent {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
                data: b"reply".to_vec(),
            },
        )),
    };
    let decoded = NetworkEvent::decode(received.encode_to_vec().as_slice()).expect("decode event");
    match decoded.payload {
        Some(network_event::Payload::SshStreamDataReceived(recv)) => {
            assert_eq!(recv.handle.as_ref().map(|handle| handle.stream_id), Some(7));
            assert_eq!(
                recv.handle
                    .as_ref()
                    .map(|handle| handle.opener_device_id.as_str()),
                Some("device-a")
            );
            assert_eq!(recv.data, b"reply");
        }
        other => panic!("unexpected event payload: {other:?}"),
    }

    let closed = NetworkEvent {
        event_id: "ssh-closed".into(),
        timestamp_ms: 124,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::SshStreamClosed(
            SshStreamClosedEvent {
                peer_id: "peer-a".into(),
                handle: Some(handle.clone()),
            },
        )),
    };
    let decoded =
        NetworkEvent::decode(closed.encode_to_vec().as_slice()).expect("decode closed event");
    assert!(matches!(
        decoded.payload,
        Some(network_event::Payload::SshStreamClosed(closed)) if closed.handle.as_ref().is_some_and(|handle| handle.stream_id == 7 && handle.opener_device_id == "device-a")
    ));
}

#[test]
fn v2_peer_config_remove_and_message_preserve_business_identity() {
    let command = NetworkCommand {
        command_id: "v2-message".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::SendMessageV2(
            SendMessageV2Command {
                peer_id: "peer-a".into(),
                message_id: "message-a".into(),
                channel_id: "control".into(),
                payload: b"hello".to_vec(),
                policy: DeliveryPolicyCode::Acked as i32,
                e2ee_policy: E2eePolicy::Required as i32,
            },
        )),
    };
    let decoded = NetworkCommand::decode(command.encode_to_vec().as_slice()).expect("decode");
    let Some(network_command::Payload::SendMessageV2(message)) = decoded.payload else {
        panic!("expected V2 message command");
    };
    assert_eq!(message.peer_id, "peer-a");
    assert_eq!(message.message_id, "message-a");
    assert_eq!(message.e2ee_policy, E2eePolicy::Required as i32);
}

#[test]
fn v2_lifecycle_diagnostics_and_environment_events_round_trip() {
    let event = NetworkEvent {
        event_id: "peer-a/lifecycle".into(),
        timestamp_ms: 1,
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::PeerLifecycle(PeerLifecycleEvent {
            peer_id: "peer-a".into(),
            state: PeerState::Online as i32,
            e2ee_policy: E2eePolicy::Required as i32,
            error: None,
        })),
    };
    let decoded = NetworkEvent::decode(event.encode_to_vec().as_slice()).expect("decode");
    assert!(matches!(
        decoded.payload,
        Some(network_event::Payload::PeerLifecycle(PeerLifecycleEvent {
            state,
            ..
        })) if state == PeerState::Online as i32
    ));

    let environment = NetworkCommand {
        command_id: "environment".into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::NetworkEnvironmentChanged(
            NetworkEnvironmentChangedCommand {
                generation: 4,
                has_connectivity: true,
                is_foreground: false,
                is_metered: true,
            },
        )),
    };
    let decoded = NetworkCommand::decode(environment.encode_to_vec().as_slice()).expect("decode");
    assert!(matches!(
        decoded.payload,
        Some(network_command::Payload::NetworkEnvironmentChanged(command))
            if command.generation == 4 && command.is_metered
    ));
}

#[test]
fn v2_public_error_codes_are_stable_and_distinct() {
    assert_eq!(NetworkErrorCode::Configuration as i32, 14);
    assert_eq!(NetworkErrorCode::SecurityPolicyMismatch as i32, 15);
    assert_eq!(NetworkErrorCode::RelayRequiresE2ee as i32, 16);
    assert_eq!(NetworkErrorCode::ResourceLimit as i32, 18);
    assert_eq!(NetworkErrorCode::ResumeRejected as i32, 24);
    assert_eq!(NetworkErrorCode::StreamClosed as i32, 25);
}

#[test]
fn screen_share_consent_wire_values_and_payload_round_trip() {
    assert_eq!(RealtimeSignalKind::ScreenShareConsent as i32, 6);
    assert_eq!(ScreenShareConsentDecision::Request as i32, 1);
    assert_eq!(ScreenShareConsentDecision::Accept as i32, 2);
    assert_eq!(ScreenShareConsentDecision::Reject as i32, 3);
    assert_eq!(ScreenShareConsentDecision::Cancel as i32, 4);
    assert_eq!(ScreenShareConsentPurpose::ScreenShare as i32, 1);
    assert_eq!(ScreenShareMediaKind::ScreenVideo as i32, 1);

    let consent = ScreenShareConsentV1 {
        schema_version: 1,
        operation_id: "operation-a".into(),
        realtime_id: "00112233445566778899aabbccddeeff".into(),
        generation: 7,
        issued_at_ms: 1_000,
        expires_at_ms: 61_000,
        decision: ScreenShareConsentDecision::Request as i32,
        sender_peer_id: "peer-a".into(),
        purpose: ScreenShareConsentPurpose::ScreenShare as i32,
        media: ScreenShareMediaKind::ScreenVideo as i32,
        requires_acceptance: true,
        action_revision: 1,
    };
    let decoded = ScreenShareConsentV1::decode(consent.encode_to_vec().as_slice())
        .expect("decode consent payload");
    assert_eq!(decoded.schema_version, 1);
    assert_eq!(decoded.operation_id, "operation-a");
    assert_eq!(decoded.realtime_id, "00112233445566778899aabbccddeeff");
    assert_eq!(decoded.generation, 7);
    assert_eq!(decoded.decision, ScreenShareConsentDecision::Request as i32);
    assert!(decoded.requires_acceptance);
    assert_eq!(decoded.action_revision, 1);
}
