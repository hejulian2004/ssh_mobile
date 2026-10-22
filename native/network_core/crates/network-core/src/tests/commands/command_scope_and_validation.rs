#[test]
fn command_peer_scope_mapping_covers_peer_and_runtime_commands() {
    let peer = "peer-a".to_string();
    let config = network_protocol::PeerConfig {
        peer_id: peer.clone(),
        ..Default::default()
    };
    let payloads = vec![
        network_command::Payload::ConnectPeer(network_protocol::ConnectPeerCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::SendFile(network_protocol::SendFileCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::ConfigureRuntime(Default::default()),
        network_command::Payload::UpsertPeer(network_protocol::UpsertPeerCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::RespondIncomingTransfer(Default::default()),
        network_command::Payload::ConfigureRelay(Default::default()),
        network_command::Payload::DisconnectPeer(network_protocol::DisconnectPeerCommand {
            peer_id: peer.clone(),
        }),
        network_command::Payload::DisconnectRelay(Default::default()),
        network_command::Payload::StartRealtimeSession(
            network_protocol::StartRealtimeSessionCommand {
                screen_video: false,
                peer_id: peer.clone(),
                ..Default::default()
            },
        ),
        network_command::Payload::StopRealtimeSession(Default::default()),
        network_command::Payload::SendRealtimeSignal(network_protocol::SendRealtimeSignalCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::UpsertPeerV2(network_protocol::UpsertPeerV2Command {
            config: Some(config),
        }),
        network_command::Payload::RemovePeer(network_protocol::RemovePeerCommand {
            peer_id: peer.clone(),
        }),
        network_command::Payload::SendMessageV2(network_protocol::SendMessageV2Command {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::Transfer(network_protocol::TransferCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::PeerDiagnostics(network_protocol::PeerDiagnosticsCommand {
            peer_id: peer.clone(),
        }),
        network_command::Payload::NetworkEnvironmentChanged(Default::default()),
        network_command::Payload::CancelTransfer(Default::default()),
        network_command::Payload::SendMessage(network_protocol::SendMessageCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::AcknowledgeMessage(network_protocol::AcknowledgeMessageCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::SshStreamOpen(network_protocol::SshStreamOpenCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::SshStreamData(network_protocol::SshStreamDataCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
        network_command::Payload::SshStreamClose(network_protocol::SshStreamCloseCommand {
            peer_id: peer.clone(),
            ..Default::default()
        }),
    ];
    for payload in payloads {
        let expected = match &payload {
            network_command::Payload::ConfigureRuntime(_)
            | network_command::Payload::RespondIncomingTransfer(_)
            | network_command::Payload::ConfigureRelay(_)
            | network_command::Payload::DisconnectRelay(_)
            | network_command::Payload::StopRealtimeSession(_)
            | network_command::Payload::NetworkEnvironmentChanged(_)
            | network_command::Payload::CancelTransfer(_) => None,
            network_command::Payload::UpsertPeerV2(command) => {
                command.config.as_ref().map(|_| peer.clone())
            }
            _ => Some(peer.clone()),
        };
        assert_eq!(
            command_peer_id(&NetworkCommand {
                command_id: "scope".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: Some(payload),
            }),
            expected
        );
    }
    assert_eq!(command_peer_id(&NetworkCommand::default()), None);
}

#[test]
fn public_error_mapping_and_wire_class_defaults_are_stable() {
    let cases = [
        (CoreNetworkError::MailboxFull, NetworkErrorCode::IoError),
        (
            CoreNetworkError::ResourceLimit("ledger"),
            NetworkErrorCode::IoError,
        ),
        (
            CoreNetworkError::SupervisorStopping,
            NetworkErrorCode::Cancelled,
        ),
        (CoreNetworkError::Cancelled, NetworkErrorCode::Cancelled),
        (CoreNetworkError::NoRoute, NetworkErrorCode::NoRoute),
        (
            CoreNetworkError::InvalidPeerId,
            NetworkErrorCode::InvalidArgument,
        ),
        (
            CoreNetworkError::InvalidCommandId,
            NetworkErrorCode::InvalidArgument,
        ),
        (
            CoreNetworkError::DuplicateCommand,
            NetworkErrorCode::InvalidArgument,
        ),
        (CoreNetworkError::StaleAttempt, NetworkErrorCode::Cancelled),
        (CoreNetworkError::StaleIntent, NetworkErrorCode::Cancelled),
        (
            CoreNetworkError::CapabilityUnavailable,
            NetworkErrorCode::NoRoute,
        ),
    ];
    for (error, code) in cases {
        assert_eq!(core_error("peer-a", "test", error).code, code as i32);
    }
    assert_eq!(
        decode_communication_class(0),
        CommunicationClass::ReliableMessage
    );
    assert_eq!(
        decode_communication_class(99),
        CommunicationClass::ReliableMessage
    );
    assert_eq!(
        decode_communication_class(CommunicationClass::BulkTransfer as i32),
        CommunicationClass::BulkTransfer
    );
    assert!(validate_e2ee_policy(network_protocol::E2eePolicy::Required as i32).is_ok());
    assert!(validate_e2ee_policy(99).is_err());
}

#[tokio::test]
async fn command_envelope_and_route_validation_fail_closed() {
    let state = Arc::new(RuntimeState::new(
        tokio::sync::mpsc::unbounded_channel().0,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let invalid_version = dispatch_command(
        NetworkCommand {
            command_id: "version".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION - 1,
            payload: None,
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("old protocol version must be rejected");
    assert_eq!(
        invalid_version.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let empty_id = dispatch_command(
        NetworkCommand {
            command_id: String::new(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: None,
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("empty command id must be rejected");
    assert_eq!(empty_id.code, NetworkErrorCode::InvalidArgument as i32);

    let oversized_id = dispatch_command(
        NetworkCommand {
            command_id: "x".repeat(129),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: None,
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("oversized command id must be rejected");
    assert_eq!(oversized_id.code, NetworkErrorCode::InvalidArgument as i32);

    let no_payload = dispatch_command(
        NetworkCommand {
            command_id: "payload".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: None,
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("missing command payload must be rejected");
    assert!(no_payload.message.contains("payload"));

    let transfer = dispatch_command(
        NetworkCommand {
            command_id: "transfer".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::Transfer(
                network_protocol::TransferCommand {
                    peer_id: String::new(),
                    transfer_id: String::new(),
                    ..Default::default()
                },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("transfer identity must be required");
    assert_eq!(transfer.code, NetworkErrorCode::InvalidArgument as i32);

    let valid_transfer = dispatch_command(
        NetworkCommand {
            command_id: "valid-transfer".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::Transfer(
                network_protocol::TransferCommand {
                    peer_id: "peer-a".into(),
                    transfer_id: "transfer-a".into(),
                    file_path: "/path/that/does/not/exist".into(),
                    ..Default::default()
                },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("valid transfer identity still validates its source");
    assert_eq!(valid_transfer.code, NetworkErrorCode::IoError as i32);

    let peer_v2 = dispatch_command(
        NetworkCommand {
            command_id: "peer-v2".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::UpsertPeerV2(
                network_protocol::UpsertPeerV2Command { config: None },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("peer config must be present");
    assert_eq!(peer_v2.code, NetworkErrorCode::InvalidArgument as i32);

    let unknown_policy = dispatch_command(
        NetworkCommand {
            command_id: "unknown-policy".into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::UpsertPeerV2(
                network_protocol::UpsertPeerV2Command {
                    config: Some(network_protocol::PeerConfig {
                        peer_id: "peer-a".into(),
                        e2ee_policy: 99,
                        ..Default::default()
                    }),
                },
            )),
        },
        Arc::clone(&state),
    )
    .await
    .expect_err("unknown E2EE policy must be rejected");
    assert_eq!(
        unknown_policy.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let bad_remove = remove_peer_v2(&state, String::new())
        .await
        .expect_err("empty peer id must be rejected");
    assert_eq!(bad_remove.code, NetworkErrorCode::InvalidArgument as i32);
    let bad_diagnostics = emit_peer_diagnostics(&state, String::new())
        .await
        .expect_err("empty diagnostics peer id must be rejected");
    assert_eq!(
        bad_diagnostics.code,
        NetworkErrorCode::InvalidArgument as i32
    );
}
