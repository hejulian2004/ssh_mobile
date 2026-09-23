use super::*;
use crate::connect::{PathRegistry, PeerId, PeerPathManager};
use crate::connection::{ConnectionProfile, Route, RouteTransport};
use std::sync::Mutex as StdMutex;
use tokio::sync::mpsc;

fn ready_stream_path() -> (
    Arc<PathRegistry>,
    PeerPathManager,
    crate::connect::PathHandle,
) {
    let registry = Arc::new(PathRegistry::new());
    let mut paths =
        PeerPathManager::new(PeerId::new("peer-a").expect("peer"), Arc::clone(&registry));
    let handle = paths
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("ready path");
    (registry, paths, handle)
}

#[tokio::test]
async fn stream_auto_ensures_reliable_stream() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let registry = Arc::new(PathRegistry::new());
    let mut paths =
        PeerPathManager::new(PeerId::new("peer-a").expect("peer"), Arc::clone(&registry));
    paths
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("ready path");
    state
        .peer_path_managers
        .write()
        .await
        .insert("peer-a".to_string(), Arc::new(StdMutex::new(paths)));
    state.allow_routes_for_test("peer-a").await;
    crate::transfer::ensure_business_path(
        &state,
        "peer-a",
        "stream-7",
        CommunicationClass::ReliableStream,
        CAPABILITY_RELIABLE_STREAM,
    )
    .await
    .expect("stream should ensure a reliable stream path");
}

#[test]
fn stream_identity_isolated_by_peer_and_opener() {
    let first = ReliableStreamIdentity::new("peer-a", "device-a", 7).expect("identity");
    let second = ReliableStreamIdentity::new("peer-b", "device-a", 7).expect("identity");
    let third = ReliableStreamIdentity::new("peer-a", "device-b", 7).expect("identity");
    assert_ne!(first, second);
    assert_ne!(first, third);
    assert!(ReliableStreamIdentity::new("", "device-a", 7).is_err());
    assert!(ReliableStreamIdentity::new("peer-a", "", 7).is_err());
    assert!(ReliableStreamIdentity::new("peer-a", "device-a", 0).is_err());
}

#[tokio::test]
async fn stream_manager_rejects_invalid_duplicate_closed_and_missing_operations() {
    let (manager, _event_rx) = test_manager();
    let (registry, _paths, handle) = ready_stream_path();
    assert!(matches!(
        manager
            .open(StreamOpener::Local, 1, "", StreamConsumer::Poll)
            .await,
        Err(StreamError::InvalidArgument)
    ));
    assert!(matches!(
        manager
            .open(
                StreamOpener::Local,
                1,
                &"x".repeat(MAX_SERVICE_BYTES + 1),
                StreamConsumer::Poll,
            )
            .await,
        Err(StreamError::InvalidArgument)
    ));
    let missing_lease = registry.acquire(&handle).expect("lease");
    assert!(matches!(
        manager
            .bind_lease(StreamOpener::Local, 1, missing_lease)
            .await,
        Err(StreamError::NotFound)
    ));
    assert!(matches!(
        manager
            .quic_send_bytes(StreamOpener::Local, 1, b"data")
            .await,
        Err(StreamError::NotFound)
    ));
    assert!(matches!(
        manager.quic_finish_send(StreamOpener::Local, 1).await,
        Err(StreamError::NotFound)
    ));

    manager
        .open(StreamOpener::Local, 1, "ssh", StreamConsumer::Poll)
        .await
        .expect("open");
    assert_eq!(manager.active_count().await, 1);
    assert!(matches!(
        manager
            .open(StreamOpener::Local, 1, "ssh", StreamConsumer::Poll)
            .await,
        Err(StreamError::AlreadyOpen)
    ));
    assert!(matches!(
        manager.take_lease(StreamOpener::Local, 1).await,
        Err(StreamError::NotConnected)
    ));
    let first = registry.acquire(&handle).expect("first lease");
    manager
        .bind_lease(StreamOpener::Local, 1, first)
        .await
        .expect("bind lease");
    let second = registry.acquire(&handle).expect("second lease");
    assert!(matches!(
        manager.bind_lease(StreamOpener::Local, 1, second).await,
        Err(StreamError::AlreadyOpen)
    ));
    let lease = manager
        .take_lease(StreamOpener::Local, 1)
        .await
        .expect("take lease");
    assert!(!manager.has_lease(StreamOpener::Local, 1).await);
    assert!(manager.restore_lease(StreamOpener::Local, 1, lease).await);
    assert!(manager.has_lease(StreamOpener::Local, 1).await);

    assert!(manager.send_guard(StreamOpener::Remote, 99).await.is_err());
    assert!(manager
        .next_send_seq(StreamOpener::Remote, 99)
        .await
        .is_err());
    assert!(manager
        .bump_send_seq(StreamOpener::Remote, 99, 1)
        .await
        .is_err());
    assert!(manager
        .receive(StreamOpener::Remote, 99, &mut [0u8; 1])
        .await
        .is_err());
    assert!(manager
        .close_local("peer-a", StreamOpener::Remote, 99)
        .await
        .is_ok());
    assert!(manager
        .handle_close("peer-a", StreamOpener::Remote, 99)
        .await
        .is_ok());

    manager
        .close_local("peer-a", StreamOpener::Local, 1)
        .await
        .expect("close local");
    assert!(matches!(
        manager.send_guard(StreamOpener::Local, 1).await,
        Err(StreamError::Closed)
    ));
    assert!(matches!(
        manager.next_send_seq(StreamOpener::Local, 1).await,
        Err(StreamError::Closed)
    ));
    assert!(matches!(
        manager.bump_send_seq(StreamOpener::Local, 1, 1).await,
        Err(StreamError::Closed)
    ));
    assert!(matches!(
        manager.take_lease(StreamOpener::Local, 1).await,
        Err(StreamError::Closed)
    ));
    manager
        .handle_close("peer-a", StreamOpener::Local, 1)
        .await
        .expect("close receive side");
    assert!(!manager.is_open(StreamOpener::Local, 1).await);
}

#[tokio::test]
async fn path_loss_closes_stream_instead_of_rebinding_it() {
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 9, "ssh", StreamConsumer::Poll)
        .await
        .expect("open");
    assert!(matches!(
        close_stream_after_path_loss(&manager, "peer-a", StreamOpener::Local, 9).await,
        StreamError::Closed
    ));
    assert!(!manager.is_open(StreamOpener::Local, 9).await);
    assert!(matches!(
        manager
            .open(StreamOpener::Local, 9, "ssh", StreamConsumer::Poll)
            .await,
        Err(StreamError::Closed)
    ));
}

#[tokio::test]
async fn stream_holds_lease_until_close() {
    let (registry, _paths, handle) = ready_stream_path();
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 10, "ssh", StreamConsumer::Poll)
        .await
        .expect("open");
    manager
        .bind_lease(
            StreamOpener::Local,
            10,
            registry.acquire(&handle).expect("stream lease"),
        )
        .await
        .expect("bind lease");
    assert!(manager.has_lease(StreamOpener::Local, 10).await);
    manager
        .handle_close("peer-a", StreamOpener::Local, 10)
        .await
        .expect("peer close");
    manager
        .close_local("peer-a", StreamOpener::Local, 10)
        .await
        .expect("local close");
    assert!(!manager.has_lease(StreamOpener::Local, 10).await);
}

#[tokio::test]
async fn normal_retire_waits_for_stream() {
    let (registry, mut paths, handle) = ready_stream_path();
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 11, "ssh", StreamConsumer::Poll)
        .await
        .expect("open");
    manager
        .bind_lease(
            StreamOpener::Local,
            11,
            registry.acquire(&handle).expect("stream lease"),
        )
        .await
        .expect("bind lease");
    paths.normal_drain();
    assert!(manager.has_lease(StreamOpener::Local, 11).await);
    assert!(
        registry.acquire(&handle).is_err(),
        "new streams are rejected"
    );
    manager.close_all("peer-a", "local-a").await;
    assert!(!manager.is_open(StreamOpener::Local, 11).await);
}

#[tokio::test]
async fn hard_close_closes_stream() {
    let (registry, mut paths, handle) = ready_stream_path();
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 12, "ssh", StreamConsumer::Poll)
        .await
        .expect("open");
    manager
        .bind_lease(
            StreamOpener::Local,
            12,
            registry.acquire(&handle).expect("stream lease"),
        )
        .await
        .expect("bind lease");
    paths.hard_close();
    let closed = manager.close_inactive("peer-a", "local-a").await;
    assert_eq!(closed, vec![(StreamOpener::Local, 12)]);
    assert!(!manager.is_open(StreamOpener::Local, 12).await);
}

#[tokio::test]
async fn stream_does_not_transparently_migrate() {
    let (registry, mut paths, old_handle) = ready_stream_path();
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 13, "ssh", StreamConsumer::Poll)
        .await
        .expect("open");
    manager
        .bind_lease(
            StreamOpener::Local,
            13,
            registry.acquire(&old_handle).expect("old lease"),
        )
        .await
        .expect("bind old lease");
    registry.drain(&old_handle);
    let new_handle = paths
        .publish_ready(ConnectionProfile::new(Route::direct(RouteTransport::Tcp)))
        .expect("new path");
    assert_ne!(old_handle, new_handle);
    assert!(manager.has_lease(StreamOpener::Local, 13).await);
    assert!(registry.acquire(&new_handle).is_ok());
    // The existing stream retained the old lease; it was not rebound to the
    // newly published path.
    assert!(manager.has_lease(StreamOpener::Local, 13).await);
}

fn test_manager() -> (ReliableStreamManager, mpsc::UnboundedReceiver<NetworkEvent>) {
    let (event_tx, event_rx) = mpsc::unbounded_channel();
    (ReliableStreamManager::new(event_tx), event_rx)
}

#[test]
fn stream_wire_frames_round_trip() {
    let data = encode_stream_bytes_frame("peer-a", 7, 3, b"hello").expect("encode bytes");
    let (opener, stream_id, seq, payload) = decode_stream_bytes_frame(&data).expect("decode bytes");
    assert_eq!((opener.as_str(), stream_id, seq), ("peer-a", 7, 3));
    assert_eq!(payload, b"hello");

    let open = encode_stream_open_frame("peer-a", 7, "ssh").expect("encode open");
    let (opener, stream_id, service) = decode_stream_open_frame(&open).expect("decode open");
    assert_eq!(
        (opener.as_str(), stream_id, service.as_str()),
        ("peer-a", 7, "ssh")
    );

    let close = encode_stream_close_frame("peer-a", 7).expect("encode close");
    assert_eq!(
        decode_stream_close_frame(&close).expect("decode close"),
        ("peer-a".to_string(), 7)
    );
    assert_eq!(stream_relay_token("peer-a", 7), "stream:peer-a:7");
    assert!(decode_stream_open_frame(b"\x00\x01\xff").is_err());
    assert!(decode_stream_bytes_frame(&[0u8; 8]).is_err());
}

#[test]
fn stream_wire_boundaries_reject_invalid_lengths_identity_and_services() {
    assert!(matches!(
        encode_stream_bytes_frame("", 1, 0, b"x"),
        Err(StreamError::InvalidArgument)
    ));
    assert!(matches!(
        encode_stream_bytes_frame(&"x".repeat(129), 1, 0, b"x"),
        Err(StreamError::InvalidArgument)
    ));
    assert!(matches!(
        encode_stream_bytes_frame("peer-a", 1, 0, &[]),
        Err(StreamError::InvalidArgument)
    ));

    assert!(matches!(
        decode_stream_bytes_frame(&[0u8; 15]),
        Err(StreamError::InvalidFrame)
    ));
    let mut invalid_opener = vec![1, 0xff];
    invalid_opener.resize(15, 0);
    assert!(matches!(
        decode_stream_bytes_frame(&invalid_opener),
        Err(StreamError::InvalidFrame)
    ));
    let mut long_opener = vec![129];
    long_opener.resize(15, 0);
    assert!(matches!(
        decode_stream_bytes_frame(&long_opener),
        Err(StreamError::InvalidFrame)
    ));
    let valid_bytes = encode_stream_bytes_frame("peer-a", 1, 0, b"x").unwrap();
    let mut extra_bytes = valid_bytes.clone();
    extra_bytes.push(0);
    assert!(matches!(
        decode_stream_bytes_frame(&extra_bytes),
        Err(StreamError::InvalidFrame)
    ));

    assert!(matches!(
        encode_stream_open_frame("peer-a", 1, ""),
        Err(StreamError::InvalidArgument)
    ));
    assert!(matches!(
        encode_stream_open_frame("peer-a", 1, &"x".repeat(MAX_SERVICE_BYTES + 1)),
        Err(StreamError::InvalidArgument)
    ));
    let valid_open = encode_stream_open_frame("peer-a", 1, "ssh").unwrap();
    assert!(matches!(
        decode_stream_open_frame(&valid_open[..3]),
        Err(StreamError::InvalidFrame)
    ));
    let mut zero_service = valid_open.clone();
    zero_service[9..11].copy_from_slice(&0u16.to_be_bytes());
    assert!(matches!(
        decode_stream_open_frame(&zero_service),
        Err(StreamError::InvalidFrame)
    ));
    let mut invalid_service = valid_open.clone();
    invalid_service[11] = 0xff;
    assert!(matches!(
        decode_stream_open_frame(&invalid_service),
        Err(StreamError::InvalidFrame)
    ));
    let mut extra_service = valid_open.clone();
    extra_service.push(0);
    assert!(matches!(
        decode_stream_open_frame(&extra_service),
        Err(StreamError::InvalidFrame)
    ));

    let valid_close = encode_stream_close_frame("peer-a", 1).unwrap();
    assert!(matches!(
        decode_stream_close_frame(&valid_close[..2]),
        Err(StreamError::InvalidFrame)
    ));
    let mut extra_close = valid_close.clone();
    extra_close.push(0);
    assert!(matches!(
        decode_stream_close_frame(&extra_close),
        Err(StreamError::InvalidFrame)
    ));
    assert!(matches!(
        decode_stream_frame_identity(GenericFrameKind::DataMessage, &valid_open),
        Err(StreamError::InvalidFrame)
    ));
    assert_eq!(
        decode_stream_frame_identity(GenericFrameKind::StreamBytes, &valid_bytes)
            .expect("bytes identity"),
        ("peer-a".to_string(), 1)
    );
    assert_eq!(
        decode_stream_frame_identity(GenericFrameKind::StreamClose, &valid_close)
            .expect("close identity"),
        ("peer-a".to_string(), 1)
    );
    assert!(matches!(
        encode_quic_stream_preamble(1, ""),
        Err(StreamError::InvalidArgument)
    ));
    assert!(matches!(
        encode_quic_stream_preamble(1, &"x".repeat(MAX_SERVICE_BYTES + 1)),
        Err(StreamError::InvalidArgument)
    ));

    assert_eq!(
        StreamError::InvalidArgument
            .into_protocol("peer-a", "stream")
            .code,
        NetworkErrorCode::InvalidArgument as i32
    );
    assert_eq!(
        StreamError::Closed.into_protocol("peer-a", "stream").code,
        NetworkErrorCode::IoError as i32
    );
}

#[test]
fn stream_command_handles_validate_presence_identity_and_range() {
    let missing = SshGatewayAdapter::parse_stream_handle(None, "peer-a", "ssh_stream_data")
        .expect_err("missing");
    assert_eq!(missing.code, NetworkErrorCode::InvalidArgument as i32);

    for handle in [
        StreamHandle {
            opener_device_id: String::new(),
            stream_id: 1,
        },
        StreamHandle {
            opener_device_id: "peer-a".repeat(129),
            stream_id: 1,
        },
        StreamHandle {
            opener_device_id: "peer-a".into(),
            stream_id: 0,
        },
        StreamHandle {
            opener_device_id: "peer-a".into(),
            stream_id: u32::from(u16::MAX) + 1,
        },
    ] {
        let error =
            SshGatewayAdapter::parse_stream_handle(Some(handle), "peer-a", "ssh_stream_data")
                .expect_err("invalid handle");
        assert_eq!(error.code, NetworkErrorCode::InvalidArgument as i32);
    }
    let (handle, stream_id) = SshGatewayAdapter::parse_stream_handle(
        Some(StreamHandle {
            opener_device_id: "peer-a".into(),
            stream_id: 7,
        }),
        "peer-a",
        "ssh_stream_data",
    )
    .expect("valid handle");
    assert_eq!(handle.opener_device_id, "peer-a");
    assert_eq!(stream_id, 7);
    assert!(!validate_peer("") && !validate_peer(&"x".repeat(129)));
    assert!(validate_peer("peer-a"));
}

#[tokio::test]
async fn stream_command_handlers_reject_invalid_arguments_before_network() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let handle = Some(StreamHandle {
        opener_device_id: "peer-a".into(),
        stream_id: 1,
    });

    let open_invalid_peer = handle_ssh_stream_open(
        Arc::clone(&state),
        SshStreamOpenCommand {
            peer_id: String::new(),
            handle: handle.clone(),
            service: "ssh".into(),
        },
    )
    .await
    .expect_err("invalid peer");
    assert_eq!(
        open_invalid_peer.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let open_invalid_service = handle_ssh_stream_open(
        Arc::clone(&state),
        SshStreamOpenCommand {
            peer_id: "peer-a".into(),
            handle: handle.clone(),
            service: String::new(),
        },
    )
    .await
    .expect_err("invalid service");
    assert_eq!(
        open_invalid_service.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let open_missing_handle = handle_ssh_stream_open(
        Arc::clone(&state),
        SshStreamOpenCommand {
            peer_id: "peer-a".into(),
            handle: None,
            service: "ssh".into(),
        },
    )
    .await
    .expect_err("missing handle");
    assert_eq!(
        open_missing_handle.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let data_invalid_peer = handle_ssh_stream_data(
        Arc::clone(&state),
        SshStreamDataCommand {
            peer_id: String::new(),
            handle: handle.clone(),
            data: b"data".to_vec(),
        },
    )
    .await
    .expect_err("invalid peer");
    assert_eq!(
        data_invalid_peer.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let close_missing_handle = handle_ssh_stream_close(
        state,
        SshStreamCloseCommand {
            peer_id: "peer-a".into(),
            handle: None,
        },
    )
    .await
    .expect_err("missing handle");
    assert_eq!(
        close_missing_handle.code,
        NetworkErrorCode::InvalidArgument as i32
    );
}

#[tokio::test]
async fn same_stream_id_isolated_by_opener_direction() {
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 1, "local", StreamConsumer::Poll)
        .await
        .expect("local open");
    manager
        .open(StreamOpener::Remote, 1, "remote", StreamConsumer::Poll)
        .await
        .expect("remote open");

    manager
        .handle_bytes("peer-a", StreamOpener::Local, 1, 0, b"from-local".to_vec())
        .await
        .expect("local bytes");
    manager
        .handle_bytes(
            "peer-a",
            StreamOpener::Remote,
            1,
            0,
            b"from-remote".to_vec(),
        )
        .await
        .expect("remote bytes");

    let mut buf = [0u8; 32];
    let n = manager
        .receive(StreamOpener::Local, 1, &mut buf)
        .await
        .expect("local receive");
    assert_eq!(&buf[..n], b"from-local");
    let n = manager
        .receive(StreamOpener::Remote, 1, &mut buf)
        .await
        .expect("remote receive");
    assert_eq!(&buf[..n], b"from-remote");
    assert!(manager.is_open(StreamOpener::Local, 1).await);
    assert!(manager.is_open(StreamOpener::Remote, 1).await);
}

#[tokio::test]
async fn session_teardown_retires_stream_identity_across_reconnect() {
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 7, "ssh", StreamConsumer::Poll)
        .await
        .expect("initial stream open");
    let closed = manager.close_all("peer-a", "local-a").await;
    assert_eq!(closed, vec![(StreamOpener::Local, 7)]);

    // The same logical handle cannot silently attach to a new Session.
    // A fresh stream id remains available, so reconnect is not globally
    // blocked while the old stream lease is retired.
    assert!(matches!(
        manager
            .open(StreamOpener::Local, 7, "ssh", StreamConsumer::Poll)
            .await,
        Err(StreamError::Closed)
    ));
    manager
        .open(StreamOpener::Local, 8, "ssh", StreamConsumer::Poll)
        .await
        .expect("new stream identity remains available");
}

#[tokio::test]
async fn inbound_frames_route_same_id_by_wire_opener() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys("local-a".into(), [1u8; 32], [2u8; 32]),
    ));
    let peer_id = "peer-b";
    let manager = state.stream_manager(peer_id).await;
    manager
        .open(StreamOpener::Local, 1, "local", StreamConsumer::Poll)
        .await
        .expect("local open");
    manager
        .open(StreamOpener::Remote, 1, "remote", StreamConsumer::Poll)
        .await
        .expect("remote open");

    let local_frame =
        encode_stream_bytes_frame("local-a", 1, 0, b"local-bytes").expect("encode local frame");
    handle_inbound_stream_frame(
        &state,
        peer_id,
        GenericFrameKind::StreamBytes,
        &local_frame,
        InboundPath::Current,
    )
    .await
    .expect("route local opener");
    let remote_frame =
        encode_stream_bytes_frame("peer-b", 1, 0, b"remote-bytes").expect("encode remote frame");
    handle_inbound_stream_frame(
        &state,
        peer_id,
        GenericFrameKind::StreamBytes,
        &remote_frame,
        InboundPath::Current,
    )
    .await
    .expect("route remote opener");

    let mut buf = [0u8; 32];
    let n = manager
        .receive(StreamOpener::Local, 1, &mut buf)
        .await
        .expect("receive local opener");
    assert_eq!(&buf[..n], b"local-bytes");
    let n = manager
        .receive(StreamOpener::Remote, 1, &mut buf)
        .await
        .expect("receive remote opener");
    assert_eq!(&buf[..n], b"remote-bytes");
}

#[tokio::test]
async fn inbound_stream_frames_reject_unknown_opener_and_kind() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    *state.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys("local-a".into(), [1u8; 32], [2u8; 32]),
    ));
    let peer_id = "peer-b";

    let open = encode_stream_open_frame("stranger", 1, "custom").expect("open frame");
    assert!(matches!(
        handle_inbound_stream_frame(
            &state,
            peer_id,
            GenericFrameKind::StreamOpen,
            &open,
            InboundPath::Current,
        )
        .await,
        Err(StreamError::InvalidFrame)
    ));
    let bytes = encode_stream_bytes_frame("stranger", 1, 0, b"data").expect("bytes frame");
    assert!(matches!(
        handle_inbound_stream_frame(
            &state,
            peer_id,
            GenericFrameKind::StreamBytes,
            &bytes,
            InboundPath::Current,
        )
        .await,
        Err(StreamError::InvalidFrame)
    ));
    let close = encode_stream_close_frame("stranger", 1).expect("close frame");
    assert!(matches!(
        handle_inbound_stream_frame(
            &state,
            peer_id,
            GenericFrameKind::StreamClose,
            &close,
            InboundPath::Current,
        )
        .await,
        Err(StreamError::InvalidFrame)
    ));
    assert!(matches!(
        handle_inbound_stream_frame(
            &state,
            peer_id,
            GenericFrameKind::DataMessage,
            &[],
            InboundPath::Current,
        )
        .await,
        Err(StreamError::InvalidFrame)
    ));
}

#[test]
fn quic_preamble_round_trip_and_dispatch_magic() {
    let preamble = encode_quic_stream_preamble(9, "ssh").expect("encode preamble");
    assert_eq!(&preamble[..4], &STREAM_QUIC_PREAMBLE_MAGIC);
    assert_ne!(&preamble[..4], &FILE_OFFER_MAGIC);
}

#[tokio::test]
async fn event_consumer_emits_data_and_close() {
    let (manager, mut event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 1, "custom", StreamConsumer::Event)
        .await
        .expect("open");
    // Event-mode bytes are buffered and delivered by the drainer task.
    let drainer = {
        let manager = manager.clone();
        tokio::spawn(async move {
            manager
                .drain_events("peer-a", StreamOpener::Local, 1, "local-device")
                .await
        })
    };
    manager
        .handle_bytes("peer-a", StreamOpener::Local, 1, 0, b"ping".to_vec())
        .await
        .expect("bytes");
    let event = event_rx.recv().await.expect("data event");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::SshStreamDataReceived(recv))
            if recv.peer_id == "peer-a" && recv.handle.as_ref().is_some_and(|handle| handle.opener_device_id == "local-device" && handle.stream_id == 1) && recv.data == b"ping"
    ));
    manager
        .handle_close("peer-a", StreamOpener::Local, 1)
        .await
        .expect("close");
    let event = event_rx.recv().await.expect("close event");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::SshStreamClosed(closed)) if closed.handle.as_ref().is_some_and(|handle| handle.opener_device_id == "local-device" && handle.stream_id == 1)
    ));
    // The drainer exits after it emits the close event.
    tokio::time::timeout(std::time::Duration::from_secs(1), drainer)
        .await
        .expect("drainer did not exit after close")
        .expect("drainer panicked");
}

#[tokio::test]
async fn poll_consumer_buffers_until_read_and_reports_eof() {
    let (manager, mut event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 2, "custom", StreamConsumer::Poll)
        .await
        .expect("open");
    manager
        .handle_bytes("peer-a", StreamOpener::Local, 2, 0, b"abc".to_vec())
        .await
        .expect("bytes");
    manager
        .handle_bytes("peer-a", StreamOpener::Local, 2, 1, b"de".to_vec())
        .await
        .expect("bytes");

    let mut buf = [0u8; 2];
    let n = manager
        .receive(StreamOpener::Local, 2, &mut buf)
        .await
        .expect("receive");
    assert_eq!((n, &buf[..n]), (2, &b"ab"[..]));
    let n = manager
        .receive(StreamOpener::Local, 2, &mut buf)
        .await
        .expect("receive");
    assert_eq!((n, &buf[..n]), (2, &b"cd"[..]));
    let n = manager
        .receive(StreamOpener::Local, 2, &mut buf)
        .await
        .expect("receive");
    assert_eq!((n, &buf[..n]), (1, &b"e"[..]));

    manager
        .handle_close("peer-a", StreamOpener::Local, 2)
        .await
        .expect("close");
    let n = manager
        .receive(StreamOpener::Local, 2, &mut buf)
        .await
        .expect("receive after close");
    assert_eq!(n, 0);
    // close_local removes the entry once both sides closed.
    manager
        .close_local("peer-a", StreamOpener::Local, 2)
        .await
        .expect("close local");
    assert!(!manager.is_open(StreamOpener::Local, 2).await);
    // Event channel was unused for the poll consumer.
    assert!(event_rx.try_recv().is_err());
}

#[tokio::test]
async fn data_after_close_is_dropped_not_an_error() {
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 3, "custom", StreamConsumer::Poll)
        .await
        .expect("open");
    manager
        .handle_close("peer-a", StreamOpener::Local, 3)
        .await
        .expect("close");
    // A late packet racing the close must not be treated as a fatal error.
    assert!(manager
        .handle_bytes("peer-a", StreamOpener::Local, 3, 0, b"late".to_vec())
        .await
        .is_ok());
}

#[tokio::test]
async fn duplicate_and_gap_sequence_handling() {
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 4, "custom", StreamConsumer::Poll)
        .await
        .expect("open");
    manager
        .handle_bytes("peer-a", StreamOpener::Local, 4, 0, b"a".to_vec())
        .await
        .expect("first");
    // Duplicate seq 0 is dropped silently.
    assert!(manager
        .handle_bytes("peer-a", StreamOpener::Local, 4, 0, b"dup".to_vec())
        .await
        .is_ok());
    // Gap (seq 2 after seq 0) is a protocol error for that stream only.
    assert!(matches!(
        manager
            .handle_bytes("peer-a", StreamOpener::Local, 4, 2, b"gap".to_vec())
            .await,
        Err(StreamError::InvalidFrame)
    ));
}

#[tokio::test]
async fn duplicate_inbound_open_ignored_keeps_existing_stream_live() {
    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let peer_id = "peer-a";
    let session_id = crate::session::SessionId::new();
    state
        .connection_sessions
        .register_pending_session(peer_id, session_id)
        .await
        .expect("register stream test session");
    state.allow_routes_for_test(peer_id).await;
    let route = crate::connection::test_blocking_generic_route();
    let route_id = route.handle.id();
    state
        .attach_test_generic_route(peer_id, session_id, route.handle)
        .await
        .expect("attach stream test path");
    route.worker.abort();
    // 首次 open 注册一条活动流（Event 消费者，数据以事件形式交付）。
    handle_inbound_open(
        &state,
        peer_id,
        StreamOpener::Remote,
        42,
        "custom",
        InboundPath::Generic(route_id),
    )
    .await
    .expect("first open");
    let manager = state.stream_manager(peer_id).await;
    assert!(
        manager.is_open(StreamOpener::Remote, 42).await,
        "first stream must be open"
    );

    // 同一 stream_id 的重复 open：必须被忽略，绝不能把现有活动流当作
    // 关闭处理（修复 #5：原先会 handle_close 关掉现有流的接收侧）。
    handle_inbound_open(
        &state,
        peer_id,
        StreamOpener::Remote,
        42,
        "custom",
        InboundPath::Generic(route_id),
    )
    .await
    .expect("duplicate open is ignored");
    assert!(
        manager.is_open(StreamOpener::Remote, 42).await,
        "existing stream must stay open"
    );
    assert!(
        !manager.is_recv_closed(StreamOpener::Remote, 42).await,
        "existing stream receive side must stay open"
    );

    // 现有流在重复 open 之后仍然接收字节（以事件交付）。
    manager
        .handle_bytes(peer_id, StreamOpener::Remote, 42, 0, b"still-live".to_vec())
        .await
        .expect("bytes after duplicate open");
    let event = tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
        .await
        .expect("timed out waiting for data event after duplicate open")
        .expect("event channel closed");
    assert!(matches!(
        event.payload,
        Some(network_event::Payload::SshStreamDataReceived(recv))
            if recv.handle.as_ref().is_some_and(|handle| handle.opener_device_id == "peer-a" && handle.stream_id == 42) && recv.data == b"still-live"
    ));
}

#[tokio::test]
async fn inbound_open_rejects_carrier_mismatch_without_rebinding() {
    let (event_tx, _event_rx) = mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let peer_id = "peer-a";
    let session_id = crate::session::SessionId::new();
    state
        .connection_sessions
        .register_pending_session(peer_id, session_id)
        .await
        .expect("register stream test session");
    state.allow_routes_for_test(peer_id).await;
    let route = crate::connection::test_blocking_generic_route();
    let route_id = route.handle.id();
    state
        .attach_test_generic_route(peer_id, session_id, route.handle)
        .await
        .expect("attach stream test path");
    route.worker.abort();

    let result = handle_inbound_open(
        &state,
        peer_id,
        StreamOpener::Remote,
        43,
        "custom",
        InboundPath::Generic(crate::connection::GenericRouteId::new(
            route_id.raw().wrapping_add(1),
        )),
    )
    .await;
    assert!(matches!(result, Err(StreamError::Closed)));
    assert!(
        !state
            .stream_manager(peer_id)
            .await
            .is_open(StreamOpener::Remote, 43)
            .await
    );
}

#[tokio::test]
async fn backpressure_blocks_until_consumer_drains() {
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 5, "custom", StreamConsumer::Poll)
        .await
        .expect("open");
    let big = vec![0x42u8; MAX_STREAM_FRAME_BYTES];
    // Fill the buffer to the cap.
    let mut pushed = 0;
    loop {
        if manager
            .handle_bytes("peer-a", StreamOpener::Local, 5, pushed, big.clone())
            .await
            .is_err()
        {
            break;
        }
        pushed += 1;
        if (pushed as usize) * big.len() >= MAX_PER_STREAM_BUFFER_CAPACITY {
            break;
        }
    }
    // The next push must block (bounded buffer), not drop or error.
    let blocked = {
        let manager = manager.clone();
        tokio::spawn(async move {
            manager
                .handle_bytes("peer-a", StreamOpener::Local, 5, pushed, vec![0x01; 1])
                .await
        })
    };
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert!(
        !blocked.is_finished(),
        "send should be blocked on a full buffer"
    );
    // Drain one chunk: the blocked writer completes.
    let mut buf = [0u8; MAX_STREAM_FRAME_BYTES];
    let n = manager
        .receive(StreamOpener::Local, 5, &mut buf)
        .await
        .expect("drain");
    assert_eq!(n, MAX_STREAM_FRAME_BYTES);
    let result = tokio::time::timeout(std::time::Duration::from_secs(1), blocked)
        .await
        .expect("blocked writer did not complete after drain")
        .expect("blocked writer task panicked");
    assert!(result.is_ok());
}

#[tokio::test]
async fn backpressure_wakeup_is_never_lost_under_repeated_races() {
    let (manager, _event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 9, "custom", StreamConsumer::Poll)
        .await
        .expect("open");
    // 回归修复 #4：填满-阻塞-腾空-唤醒循环反复执行，暴露「检查条件后释放
    // 锁、再注册等待」间隙里的 lost-wakeup。修复前用 `Notify`，该间隙中
    // 生产者 drain 后 `notify_waiters()` 不带许可，writer 会永久阻塞。
    let chunk = vec![0x42u8; MAX_STREAM_FRAME_BYTES];
    let mut pushed = 0u64;
    let mut sink = [0u8; MAX_STREAM_FRAME_BYTES];
    for _ in 0..50 {
        // 填满有界缓冲，使下一次写入必然阻塞（背压前提）。
        while manager
            .buffered_bytes(StreamOpener::Local, 9)
            .await
            .unwrap()
            + chunk.len()
            <= MAX_PER_STREAM_BUFFER_CAPACITY
        {
            manager
                .handle_bytes("peer-a", StreamOpener::Local, 9, pushed, chunk.clone())
                .await
                .expect("fill");
            pushed += 1;
        }
        // 阻塞的 writer：缓冲已满，等待消费者腾出空间。
        let blocked = {
            let manager = manager.clone();
            tokio::spawn(async move {
                manager
                    .handle_bytes("peer-a", StreamOpener::Local, 9, pushed, vec![0x01; 1])
                    .await
            })
        };
        // 给 writer 机会进入等待点并注册，放大检查-等待竞态窗口。
        tokio::task::yield_now().await;
        // 从另一任务 drain 一块：阻塞的 writer 必须完成，唤醒绝不丢失。
        let n = manager
            .receive(StreamOpener::Local, 9, &mut sink)
            .await
            .expect("drain");
        assert_eq!(n, MAX_STREAM_FRAME_BYTES);
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), blocked)
            .await
            .expect("blocked writer deadlocked: backpressure wakeup was lost")
            .expect("blocked writer task panicked");
        assert!(result.is_ok());
        pushed += 1;
        // 清空残留，使下一轮从空缓冲开始（保持「缓冲满才阻塞」前提成立）。
        while manager
            .buffered_bytes(StreamOpener::Local, 9)
            .await
            .unwrap()
            > 0
        {
            let _ = manager.receive(StreamOpener::Local, 9, &mut sink).await;
        }
    }
}

#[tokio::test]
async fn event_consumer_flood_stays_bounded_and_drains_in_order() {
    let (manager, mut event_rx) = test_manager();
    manager
        .open(StreamOpener::Local, 6, "custom", StreamConsumer::Event)
        .await
        .expect("open");

    // 洪水超过有界缓冲区：Event 流也必须把 writer 阻塞在
    // MAX_PER_STREAM_BUFFER_CAPACITY，而不是把每一帧直接灌入事件通道。
    let chunk = vec![0x42u8; MAX_STREAM_FRAME_BYTES];
    let total_chunks = MAX_PER_STREAM_BUFFER_CAPACITY / MAX_STREAM_FRAME_BYTES + 8;
    let flood = {
        let manager = manager.clone();
        tokio::spawn(async move {
            let mut pushed = 0u64;
            while pushed < total_chunks as u64 {
                manager
                    .handle_bytes("peer-a", StreamOpener::Local, 6, pushed, chunk.clone())
                    .await
                    .expect("handle_bytes");
                pushed += 1;
            }
            pushed
        })
    };
    // drainer 未启动时，writer 必须被阻塞（背压），不得逐帧灌入事件通道。
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert!(
        !flood.is_finished(),
        "flood must be blocked waiting for the Event drainer"
    );
    // 缓冲字节数不越过 cap，且尚未发出任何事件（事件只由 drainer 从缓冲吐出）。
    let buffered = manager
        .buffered_bytes(StreamOpener::Local, 6)
        .await
        .expect("stream");
    assert!(
        buffered <= MAX_PER_STREAM_BUFFER_CAPACITY,
        "buffered bytes must stay bounded: {buffered} > {MAX_PER_STREAM_BUFFER_CAPACITY}"
    );
    assert!(
        event_rx.try_recv().is_err(),
        "no event may be emitted while the drainer is paused"
    );

    // 启动 drainer：阻塞的 writer 随 drain 推进，全部字节最终按序以事件发出。
    let drainer = {
        let manager = manager.clone();
        tokio::spawn(async move {
            manager
                .drain_events("peer-a", StreamOpener::Local, 6, "local-device")
                .await
        })
    };
    let pushed = tokio::time::timeout(std::time::Duration::from_secs(5), flood)
        .await
        .expect("flood did not complete after the drainer started")
        .expect("flood panicked");
    assert_eq!(pushed, total_chunks as u64);

    let mut received = 0usize;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while received < pushed as usize * MAX_STREAM_FRAME_BYTES {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            panic!("not all flooded bytes were delivered; received {received} bytes");
        }
        let event = tokio::time::timeout(remaining, event_rx.recv())
            .await
            .expect("timed out waiting for stream data events")
            .expect("event channel closed");
        if let Some(network_event::Payload::SshStreamDataReceived(recv)) = event.payload {
            assert!(recv
                .handle
                .as_ref()
                .is_some_and(
                    |handle| handle.opener_device_id == "local-device" && handle.stream_id == 6
                ));
            received += recv.data.len();
        }
    }
    assert_eq!(received, pushed as usize * MAX_STREAM_FRAME_BYTES);

    // 关闭后 drainer 发出 close 事件并退出。
    manager
        .handle_close("peer-a", StreamOpener::Local, 6)
        .await
        .expect("close");
    let closed = tokio::time::timeout(std::time::Duration::from_secs(1), event_rx.recv())
        .await
        .expect("close event missing")
        .expect("event channel closed");
    assert!(matches!(
        closed.payload,
        Some(network_event::Payload::SshStreamClosed(c)) if c.handle.as_ref().is_some_and(|handle| handle.opener_device_id == "local-device" && handle.stream_id == 6)
    ));
    tokio::time::timeout(std::time::Duration::from_secs(1), drainer)
        .await
        .expect("drainer did not exit after close")
        .expect("drainer panicked");
}

#[tokio::test]
async fn stream_capacity_is_enforced() {
    let (manager, _event_rx) = test_manager();
    for id in 1..=MAX_CONCURRENT_STREAMS {
        manager
            .open(
                StreamOpener::Local,
                id as u16,
                "custom",
                StreamConsumer::Poll,
            )
            .await
            .expect("open");
    }
    assert!(matches!(
        manager
            .open(
                StreamOpener::Local,
                (MAX_CONCURRENT_STREAMS + 1) as u16,
                "custom",
                StreamConsumer::Poll
            )
            .await,
        Err(StreamError::CapacityExceeded)
    ));
}
