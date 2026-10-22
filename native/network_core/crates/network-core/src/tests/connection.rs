use super::*;
use network_transport::testkit::WriterGate;
use network_transport::{TcpTransport, Transport};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;
use tokio::time::{sleep, timeout};

struct StartedGenericRoute {
    handle: GenericRouteHandle,
    inbound: mpsc::Receiver<GenericInboundFrame>,
    stop: CancellationToken,
    driver: JoinHandle<()>,
    server: TcpStream,
}

async fn started_tcp_generic_route() -> StartedGenericRoute {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind generic route test listener");
    let peer = listener
        .local_addr()
        .expect("generic route test listener address");
    let connection = GenericConnection::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
        .await
        .expect("connect generic route test client");
    let (server, _) = listener
        .accept()
        .await
        .expect("accept generic route test client");
    let runtime = prepare_generic_route(connection);
    assert_eq!(runtime.handle.peer_address(), Some(peer));
    let GenericRouteRuntime {
        handle,
        inbound,
        driver,
        ready,
        commit,
        stop,
        ..
    } = runtime;
    let driver = tokio::spawn(driver);
    timeout(Duration::from_secs(1), ready)
        .await
        .expect("generic route driver did not become ready")
        .expect("generic route ready signal dropped");
    commit
        .send(())
        .expect("generic route commit receiver dropped");
    StartedGenericRoute {
        handle,
        inbound,
        stop,
        driver,
        server,
    }
}

async fn read_wire_frame(stream: &mut TcpStream) -> Vec<u8> {
    let length = stream
        .read_u32()
        .await
        .expect("read generic route frame length") as usize;
    let mut payload = vec![0u8; length];
    stream
        .read_exact(&mut payload)
        .await
        .expect("read generic route frame payload");
    payload
}

async fn write_wire_frame(stream: &mut TcpStream, payload: &[u8]) {
    stream
        .write_u32(payload.len() as u32)
        .await
        .expect("write generic route frame length");
    stream
        .write_all(payload)
        .await
        .expect("write generic route frame payload");
}

fn spawn_write_pressure(
    handle: &GenericRouteHandle,
) -> Vec<JoinHandle<Result<(), ConnectionError>>> {
    let payload = Arc::new(vec![
        0x5a;
        network_quic::MAX_CHANNEL_FRAME_BYTES
            - GENERIC_FRAME_HEADER_BYTES
    ]);
    (0..256)
        .map(|_| {
            let handle = handle.clone();
            let payload = Arc::clone(&payload);
            tokio::spawn(async move {
                handle
                    .send(GenericFrameKind::DataMessage, payload.as_slice())
                    .await
            })
        })
        .collect()
}

async fn wait_for_pending_write(tasks: &[JoinHandle<Result<(), ConnectionError>>]) {
    timeout(Duration::from_secs(1), async {
        loop {
            if tasks.iter().any(|task| !task.is_finished()) {
                return;
            }
            sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("generic route test did not create pending writes");
}

#[test]
fn capability_mapping_and_route_selection_are_explicit() {
    assert!(ConnectionProfile::new(Route::direct(RouteTransport::Tcp))
        .supports(ConnectionCapability::ReliableStream));
    assert!(
        ConnectionProfile::new(Route::relay(RouteTransport::WebSocket))
            .supports(ConnectionCapability::ReliableMessage)
    );
    assert!(ConnectionProfile::new(Route::direct(RouteTransport::Udp))
        .supports(ConnectionCapability::UnreliableDatagram));
    assert!(ConnectionProfile::new(Route::direct(RouteTransport::Quic))
        .supports(ConnectionCapability::ReliableStream));

    assert!(!Route::direct(RouteTransport::Udp).supports(ConnectionCapability::ReliableMessage));
    assert_eq!(
        ConnectionRouteSelector::select(
            ConnectionCapability::ReliableStream,
            [
                RouteCandidate::blocked(Route::direct(RouteTransport::Quic)),
                RouteCandidate::available(Route::direct(RouteTransport::Tcp)),
            ]
        )
        .expect("TCP fallback")
        .route(),
        Route::direct(RouteTransport::Tcp)
    );
    assert_eq!(
        ConnectionRouteSelector::select(
            ConnectionCapability::ReliableMessage,
            [
                RouteCandidate::blocked(Route::direct(RouteTransport::Udp)),
                RouteCandidate::available(Route::relay(RouteTransport::WebSocket)),
            ],
        )
        .expect("WSS fallback")
        .route(),
        Route::relay(RouteTransport::WebSocket)
    );
    assert_eq!(
        ConnectionProfile::for_route(RouteType::Relay)
            .expect("Relay profile")
            .route(),
        Route::relay(RouteTransport::WebSocket)
    );
    assert_eq!(
        Route::direct(RouteTransport::Quic).to_wire(),
        Some(RouteType::QuicDirect)
    );
    assert_eq!(Route::direct(RouteTransport::Tcp).to_wire(), None);
}

#[test]
fn generic_frame_codec_rejects_bad_magic_version_kind_and_lengths() {
    let encoded = encode_generic_frame(GenericFrameKind::DataMessage, b"payload")
        .expect("valid generic frame");
    let decoded = decode_generic_frame(&encoded).expect("decode generic frame");
    assert_eq!(decoded.kind, GenericFrameKind::DataMessage);
    assert_eq!(decoded.payload, b"payload");

    assert!(matches!(
        encode_generic_frame(GenericFrameKind::DataMessage, &[]),
        Err(ConnectionError::FrameTooLarge)
    ));
    let mut bad_magic = encoded.clone();
    bad_magic[0] ^= 1;
    assert!(matches!(
        decode_generic_frame(&bad_magic),
        Err(ConnectionError::InvalidFrame)
    ));
    let mut bad_version = encoded.clone();
    bad_version[7] ^= 1;
    assert!(matches!(
        decode_generic_frame(&bad_version),
        Err(ConnectionError::InvalidFrame)
    ));
    let mut bad_kind = encoded.clone();
    bad_kind[8] = 0xff;
    assert!(matches!(
        decode_generic_frame(&bad_kind),
        Err(ConnectionError::InvalidFrame)
    ));
    let mut bad_length = encoded;
    bad_length[12] = 1;
    assert!(matches!(
        decode_generic_frame(&bad_length),
        Err(ConnectionError::FrameTooLarge)
    ));
    assert!(matches!(
        decode_generic_frame(&[0; 4]),
        Err(ConnectionError::InvalidFrame)
    ));
}

#[tokio::test]
async fn generic_connection_lifecycle_and_message_limit_are_enforced() {
    let left_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let right_socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let left_addr = left_socket.local_addr().unwrap();
    let right_addr = right_socket.local_addr().unwrap();
    left_socket.connect(right_addr).await.unwrap();
    right_socket.connect(left_addr).await.unwrap();
    let mut left = GenericConnection::from_transport(Transport::Udp(
        network_transport::UdpTransport::from_socket(left_socket, right_addr),
    ));
    let mut right = GenericConnection::from_transport(Transport::Udp(
        network_transport::UdpTransport::from_socket(right_socket, left_addr),
    ));

    assert_eq!(left.send(b"datagram").await.unwrap(), 8);
    assert_eq!(right.recv().await.unwrap(), b"datagram");
    assert!(matches!(
        left.send(&vec![0u8; network_transport::MAX_DATAGRAM_BYTES + 1])
            .await,
        Err(TransportError::FrameTooLarge)
    ));
    left.close().await.unwrap();
    assert!(matches!(
        left.send(b"closed").await,
        Err(TransportError::Closed)
    ));
    right.close().await.unwrap();
}

#[tokio::test]
async fn reliable_stream_wrapper_round_trips_and_shuts_down() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let peer = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut server =
            GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(stream)));
        let payload = server.recv().await.unwrap();
        server.send(&payload).await.unwrap();
        server.close().await.unwrap();
    });

    let mut client = GenericConnection::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
        .await
        .unwrap();
    assert_eq!(client.route(), Route::direct(RouteTransport::Tcp));
    client.send(b"reliable-stream").await.unwrap();
    assert_eq!(client.recv().await.unwrap(), b"reliable-stream");
    client.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn blocked_write_does_not_stop_inbound_ack_progress() {
    let mut route = started_tcp_generic_route().await;
    let mut server = route.server;
    let pressure = spawn_write_pressure(&route.handle);

    // Let the first write complete, then leave the peer's receive window
    // closed while enough queued frames make the client writer wait.
    let _ = read_wire_frame(&mut server).await;
    wait_for_pending_write(&pressure).await;

    let ack = encode_generic_frame(GenericFrameKind::DeliveryAck, b"ack")
        .expect("encode inbound delivery ack");
    write_wire_frame(&mut server, &ack).await;
    let frame = timeout(Duration::from_secs(1), route.inbound.recv())
        .await
        .expect("inbound ACK was blocked behind writer")
        .expect("generic route inbound channel closed");
    assert_eq!(frame.kind, GenericFrameKind::DeliveryAck);
    assert_eq!(frame.payload, b"ack");

    route.stop.cancel();
    timeout(Duration::from_secs(1), route.driver)
        .await
        .expect("route driver did not stop after cancellation")
        .expect("route driver panicked");
    for task in pressure {
        task.abort();
    }
}

/// Deterministic blocked-write proof: a `TransportWriter::send` parked at
/// the transport level (not merely command-channel backpressure) does not
/// stall the read half, and completes once the gate is released.
#[tokio::test]
async fn blocked_transport_write_delivers_ack_and_completes_after_release() {
    let gate = WriterGate::new();
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind gated route listener");
    let peer = listener.local_addr().expect("gated route peer address");
    let connection = GenericConnection::from_transport(
        Transport::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
            .await
            .expect("connect gated route client")
            .with_gated_writer(gate.clone()),
    );
    let (mut server, _) = listener.accept().await.expect("accept gated route client");

    let runtime = prepare_generic_route(connection);
    let GenericRouteRuntime {
        handle,
        mut inbound,
        driver,
        ready,
        commit,
        stop,
        ..
    } = runtime;
    let driver = tokio::spawn(driver);
    timeout(Duration::from_secs(1), ready)
        .await
        .expect("gated route driver did not become ready")
        .expect("gated route ready signal dropped");
    commit
        .send(())
        .expect("gated route commit receiver dropped");

    // A caller blocks inside `handle.send` at the transport level.
    let send_task = tokio::spawn({
        let handle = handle.clone();
        async move { handle.send(GenericFrameKind::DataMessage, b"blocked").await }
    });

    // The writer's `send` is provably in-flight and parked on the gate.
    timeout(Duration::from_secs(1), gate.entered())
        .await
        .expect("gated transport write never entered");
    assert!(
        !send_task.is_finished(),
        "send should be blocked at the transport writer"
    );

    // The reader still delivers an inbound ACK while the writer is parked.
    let ack = encode_generic_frame(GenericFrameKind::DeliveryAck, b"ack")
        .expect("encode inbound delivery ack");
    write_wire_frame(&mut server, &ack).await;
    let frame = timeout(Duration::from_secs(1), inbound.recv())
        .await
        .expect("inbound ACK was blocked behind the parked write")
        .expect("generic route inbound channel closed");
    assert_eq!(frame.kind, GenericFrameKind::DeliveryAck);
    assert_eq!(frame.payload, b"ack");

    // Release the gate: the parked write reaches the socket and the caller
    // completes with Ok.
    gate.release();
    let result = timeout(Duration::from_secs(1), send_task)
        .await
        .expect("blocked send did not complete after release")
        .expect("blocked send task panicked");
    assert!(matches!(result, Ok(())), "expected Ok, got {result:?}");

    // The peer observes the exact frame that was parked.
    let received = read_wire_frame(&mut server).await;
    let received = decode_generic_frame(&received).expect("decode released frame");
    assert_eq!(received.kind, GenericFrameKind::DataMessage);
    assert_eq!(received.payload, b"blocked");

    stop.cancel();
    timeout(Duration::from_secs(1), driver)
        .await
        .expect("gated route driver did not stop")
        .expect("gated route driver panicked");
}

#[tokio::test]
async fn inbound_queue_saturation_applies_backpressure_without_closing_route() {
    let mut route = started_tcp_generic_route().await;
    let frame = encode_generic_frame(GenericFrameKind::DataMessage, b"queued")
        .expect("encode inbound data frame");
    for _ in 0..=GENERIC_ROUTE_CHANNEL_CAPACITY {
        write_wire_frame(&mut route.server, &frame).await;
    }

    for _ in 0..=GENERIC_ROUTE_CHANNEL_CAPACITY {
        let received = timeout(Duration::from_secs(1), route.inbound.recv())
            .await
            .expect("inbound queue remained blocked after saturation")
            .expect("generic route closed while queue was saturated");
        assert_eq!(received.kind, GenericFrameKind::DataMessage);
        assert_eq!(received.payload, b"queued");
    }

    // Post-drain usability: after backpressure clears, the route still
    // accepts an outbound frame and still delivers an inbound ACK.
    route
        .handle
        .send(GenericFrameKind::DataMessage, b"after-drain")
        .await
        .expect("route did not accept a frame after drain");
    let received = read_wire_frame(&mut route.server).await;
    let received = decode_generic_frame(&received).expect("decode after-drain frame");
    assert_eq!(received.kind, GenericFrameKind::DataMessage);
    assert_eq!(received.payload, b"after-drain");

    let ack = encode_generic_frame(GenericFrameKind::DeliveryAck, b"post-drain")
        .expect("encode post-drain ack");
    write_wire_frame(&mut route.server, &ack).await;
    let received = timeout(Duration::from_secs(1), route.inbound.recv())
        .await
        .expect("post-drain ACK was blocked")
        .expect("route closed after drain");
    assert_eq!(received.kind, GenericFrameKind::DeliveryAck);
    assert_eq!(received.payload, b"post-drain");

    route.stop.cancel();
    timeout(Duration::from_secs(1), route.driver)
        .await
        .expect("route driver did not stop after queue test")
        .expect("route driver panicked");
}

#[tokio::test]
async fn cancellation_preempts_a_blocked_generic_route_write() {
    let route = started_tcp_generic_route().await;
    let mut server = route.server;
    let pressure = spawn_write_pressure(&route.handle);
    let _ = read_wire_frame(&mut server).await;
    wait_for_pending_write(&pressure).await;

    route.stop.cancel();
    timeout(Duration::from_secs(1), route.driver)
        .await
        .expect("cancellation did not preempt the blocked route write")
        .expect("route driver panicked");
    let mut remaining = [0u8; 64 * 1024];
    timeout(Duration::from_secs(1), async {
        loop {
            let read = server
                .read(&mut remaining)
                .await
                .expect("server read cancelled route");
            if read == 0 {
                break;
            }
        }
    })
    .await
    .expect("server did not observe cancelled route close");
    for task in pressure {
        task.abort();
    }
}

/// Deterministic cancellation of an in-flight transport write: a caller
/// blocked inside `handle.send` at the transport writer resolves promptly
/// to `ConnectionError::Cancelled` when the route is cancelled.
#[tokio::test]
async fn cancellation_resolves_a_caller_blocked_in_transport_write() {
    let gate = WriterGate::new();
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind cancellation listener");
    let peer = listener.local_addr().expect("cancellation peer address");
    let connection = GenericConnection::from_transport(
        Transport::connect_tcp("0.0.0.0:0".parse().unwrap(), peer)
            .await
            .expect("connect cancellation client")
            .with_gated_writer(gate.clone()),
    );
    let (_server, _) = listener.accept().await.expect("accept cancellation client");

    let runtime = prepare_generic_route(connection);
    let GenericRouteRuntime {
        handle,
        driver,
        ready,
        commit,
        stop,
        ..
    } = runtime;
    let driver = tokio::spawn(driver);
    timeout(Duration::from_secs(1), ready)
        .await
        .expect("cancellation route driver not ready")
        .expect("cancellation route ready signal dropped");
    commit
        .send(())
        .expect("cancellation route commit receiver dropped");

    let send_task = tokio::spawn({
        let handle = handle.clone();
        async move { handle.send(GenericFrameKind::DataMessage, b"blocked").await }
    });
    timeout(Duration::from_secs(1), gate.entered())
        .await
        .expect("gated write never entered the transport");
    assert!(
        !send_task.is_finished(),
        "send should be blocked at the transport writer"
    );

    // Cancelling the route preempts the in-flight transport write and the
    // blocked caller resolves promptly to Cancelled.
    stop.cancel();
    let result = timeout(Duration::from_secs(1), send_task)
        .await
        .expect("cancelled send caller did not resolve")
        .expect("cancelled send task panicked");
    assert!(
        matches!(result, Err(ConnectionError::Cancelled)),
        "expected Cancelled, got {result:?}"
    );

    timeout(Duration::from_secs(1), driver)
        .await
        .expect("route driver did not stop after cancellation")
        .expect("route driver panicked");
}

#[tokio::test]
async fn route_shutdown_releases_socket_for_a_replacement_route() {
    let first = started_tcp_generic_route().await;
    let mut first_server = first.server;
    first.stop.cancel();
    timeout(Duration::from_secs(1), first.driver)
        .await
        .expect("first route did not shut down")
        .expect("first route driver panicked");
    let mut byte = [0u8; 1];
    assert_eq!(
        timeout(Duration::from_secs(1), first_server.read(&mut byte))
            .await
            .expect("first route socket did not close")
            .expect("read first route shutdown"),
        0
    );

    let replacement = started_tcp_generic_route().await;
    let mut replacement_server = replacement.server;
    replacement
        .handle
        .send(GenericFrameKind::DataMessage, b"replacement")
        .await
        .expect("replacement route did not accept a frame");
    let received = read_wire_frame(&mut replacement_server).await;
    let received = decode_generic_frame(&received).expect("decode replacement frame");
    assert_eq!(received.kind, GenericFrameKind::DataMessage);
    assert_eq!(received.payload, b"replacement");
    replacement.stop.cancel();
    timeout(Duration::from_secs(1), replacement.driver)
        .await
        .expect("replacement route did not shut down")
        .expect("replacement route driver panicked");
}
