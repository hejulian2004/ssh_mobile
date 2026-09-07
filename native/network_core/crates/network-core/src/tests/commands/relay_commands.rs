#[tokio::test]
async fn relay_command_validation_checks_runtime_identity_and_credentials() {
    let state = Arc::new(RuntimeState::new(
        tokio::sync::mpsc::unbounded_channel().0,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let missing_identity = start_configure_relay(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand::default(),
    )
    .await
    .expect_err("Relay requires configured runtime identity");
    assert_eq!(
        missing_identity.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));
    let bad_seed = start_configure_relay(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 31],
        },
    )
    .await
    .expect_err("Relay seed length must be exact");
    assert_eq!(bad_seed.code, NetworkErrorCode::InvalidArgument as i32);

    let bad_url = start_configure_relay(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url: "  ".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 32],
        },
    )
    .await
    .expect_err("Relay URL and credential are required");
    assert_eq!(bad_url.code, NetworkErrorCode::InvalidArgument as i32);

    state.task_supervisor.shutdown().await;
    let stopping = start_configure_relay(
        state,
        network_protocol::ConfigureRelayCommand {
            relay_url: "ws://127.0.0.1:9".into(),
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 32],
        },
    )
    .await
    .expect_err("Relay configure must reject a stopping runtime");
    assert_eq!(stopping.code, NetworkErrorCode::Cancelled as i32);
}
#[tokio::test]
async fn relay_command_reports_async_control_connect_failure() {
    // A closed well-known port is environment-dependent: some Windows network
    // filters black-hole the SYN instead of returning connection-refused. Own
    // the failure fixture so the assertion observes a deterministic rejected
    // WebSocket handshake rather than a platform TCP timeout.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind deterministic rejected relay fixture");
    let relay_url = format!(
        "ws://{}",
        listener
            .local_addr()
            .expect("fixture listener must expose its bound address")
    );
    let rejected_handshake = tokio::spawn(async move {
        let (mut socket, _) = listener
            .accept()
            .await
            .expect("relay fixture should receive the control connection");
        socket
            .write_all(
                b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .await
            .expect("relay fixture should reject the WebSocket handshake");
    });
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    state.lifecycle.identity.write().await.replace(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".into(),
            [1u8; 32],
            [2u8; 32],
        ),
    ));

    start_configure_relay(
        Arc::clone(&state),
        network_protocol::ConfigureRelayCommand {
            relay_url,
            relay_credential: "credential".into(),
            relay_signing_seed: vec![0; 32],
        },
    )
    .await
    .expect("valid Relay command should queue its async task");

    let mut saw_connecting = false;
    let mut saw_failed = false;
    let mut saw_connected = false;
    tokio::time::timeout(Duration::from_secs(2), async {
        while let Some(event) = event_rx.recv().await {
            let Some(network_protocol::network_event::Payload::RelayStateChanged(change)) =
                event.payload
            else {
                continue;
            };
            match network_protocol::RelayConnectionState::try_from(change.state) {
                Ok(network_protocol::RelayConnectionState::Connecting) => saw_connecting = true,
                Ok(network_protocol::RelayConnectionState::Failed) => {
                    saw_failed = true;
                    break;
                }
                Ok(network_protocol::RelayConnectionState::Connected) => saw_connected = true,
                _ => {}
            }
        }
    })
    .await
    .expect("Relay failure event should arrive");
    rejected_handshake
        .await
        .expect("rejected relay fixture task should complete");
    state.task_supervisor.shutdown().await;
    assert!(saw_connecting);
    assert!(saw_failed);
    assert!(!saw_connected, "failed Relay setup must not emit Connected");
}
use tokio::io::AsyncWriteExt;
