use super::*;
use crate::generic_auth::authenticate_responder;
use crate::runtime::ConnectDecision;
use network_transport::{TcpTransport, Transport, WebSocketTransport};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};

async fn generic_connection_pair() -> (GenericConnection, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind generic route test listener");
    let address = listener
        .local_addr()
        .expect("generic route listener address");
    let (server_result, client_result) =
        tokio::join!(listener.accept(), TcpStream::connect(address));
    let server = server_result.expect("accept generic route test socket").0;
    let client = client_result.expect("connect generic route test socket");
    (
        GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(client))),
        server,
    )
}

async fn quic_connection_pair() -> (quinn::Endpoint, quinn::Connection) {
    let server = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("server bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("server endpoint");
    let server_address = server.endpoint.local_addr().expect("server address");
    let server_endpoint = server.endpoint;
    let server_task = tokio::spawn(async move {
        server_endpoint
            .accept()
            .await
            .expect("incoming QUIC connection")
            .await
            .expect("server QUIC connection")
    });
    let client = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("client bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("client endpoint");
    let connection = client
        .endpoint
        .connect(server_address, "ssh-mobile")
        .expect("connect QUIC candidate")
        .await
        .expect("QUIC connection");
    let _server_connection = server_task.await.expect("server task");
    (client.endpoint, connection)
}

async fn new_test_state() -> Arc<RuntimeState> {
    let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel();
    Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))))
}

async fn send_channel_frame_for_test(
    state: &RuntimeState,
    peer_id: &str,
    relay_token: &str,
    kind: GenericFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let required_capability = match kind {
        GenericFrameKind::DataMessage | GenericFrameKind::DeliveryAck => {
            crate::connect::CAPABILITY_RELIABLE_MESSAGE
        }
        GenericFrameKind::StreamOpen
        | GenericFrameKind::StreamBytes
        | GenericFrameKind::StreamClose => crate::connect::CAPABILITY_RELIABLE_STREAM,
    };
    let manager = state.peer_path_managers.read().await.get(peer_id).cloned();
    let Some(manager) = manager else {
        return Err(
            std::io::Error::new(std::io::ErrorKind::NotConnected, "path unavailable").into(),
        );
    };
    let lease = manager
        .lock()
        .expect("peer path manager lock")
        .acquire(required_capability)
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::NotConnected, "path unavailable"))?
        .1;
    lease.send_channel_frame(relay_token, kind, payload).await
}

async fn started_generic_scope(
    state: &Arc<RuntimeState>,
    peer_id: &str,
    session_id: SessionId,
    connection: GenericConnection,
) -> GenericRouteScope {
    OutboundGenericConnector::supervise_generic_route(
        Arc::clone(state),
        peer_id,
        session_id,
        prepare_generic_route(connection),
    )
    .await
    .expect("generic route tasks should start")
}

async fn started_session(state: &RuntimeState, peer_id: &str) -> SessionId {
    match state
        .begin_connect(peer_id, crate::connect::DEFAULT_CONNECTION_CAPABILITY)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    }
}

struct CancellationSignal {
    started: Option<oneshot::Sender<()>>,
    cancelled: Option<oneshot::Sender<()>>,
}

impl Drop for CancellationSignal {
    fn drop(&mut self) {
        if let Some(sender) = self.cancelled.take() {
            let _ = sender.send(());
        }
    }
}

async fn wait_for_active_task_count(
    supervisor: &crate::task_supervisor::RuntimeTaskSupervisor,
    expected: usize,
) {
    timeout(Duration::from_secs(1), async {
        loop {
            if supervisor.active_count() == expected {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("supervisor did not reach {expected} active tasks"));
}

#[tokio::test]
async fn session_close_stops_and_joins_generic_route_tasks() {
    let state = new_test_state().await;
    state.allow_routes_for_test("generic-close-peer").await;
    let session_id = started_session(&state, "generic-close-peer").await;
    let (connection, mut server) = generic_connection_pair().await;
    let mut scope =
        started_generic_scope(&state, "generic-close-peer", session_id, connection).await;
    assert_eq!(state.task_supervisor.active_count(), 2);
    state
        .attach_generic_route_for_session("generic-close-peer", Some(session_id), &mut scope)
        .await
        .expect("attach GenericRoute");

    state
        .close_transport_path("generic-close-peer")
        .await
        .expect("Session close should detach GenericRoute owner");
    wait_for_active_task_count(&state.task_supervisor, 0).await;
    assert_eq!(state.task_supervisor.active_count(), 0);

    let mut buffer = [0u8; 1];
    let read = tokio::time::timeout(Duration::from_secs(1), server.read(&mut buffer))
        .await
        .expect("underlying TCP socket should close")
        .expect("read server-side socket");
    assert_eq!(read, 0);
}

#[tokio::test]
async fn generic_route_supervision_rejects_registration_after_runtime_shutdown() {
    let state = new_test_state().await;
    state.task_supervisor.cancel_root();
    let (connection, _server) = generic_connection_pair().await;
    let result = OutboundGenericConnector::supervise_generic_route(
        Arc::clone(&state),
        "generic-shutdown-peer",
        SessionId::new(),
        prepare_generic_route(connection),
    )
    .await;
    let error = match result {
        Ok(_) => panic!("stopping supervisor must reject generic route registration"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::Cancelled as i32);
}

#[tokio::test]
async fn connected_session_rejects_a_second_route_to_enforce_one_to_one() {
    // §18 1:1：Session 已 Connected 且持有 route 时，拒绝再挂第二条 route。
    let state = new_test_state().await;
    let peer_id = "generic-one-to-one-peer";
    state.allow_routes_for_test(peer_id).await;
    let session_id = started_session(&state, peer_id).await;
    let (first_connection, _server) = generic_connection_pair().await;
    let mut first_scope =
        started_generic_scope(&state, peer_id, session_id, first_connection).await;
    state
        .attach_generic_route_for_session(peer_id, Some(session_id), &mut first_scope)
        .await
        .expect("attach first GenericRoute");

    let (second_connection, _second_server) = generic_connection_pair().await;
    let mut second_scope =
        started_generic_scope(&state, peer_id, session_id, second_connection).await;
    assert!(state
        .attach_generic_route_for_session(peer_id, Some(session_id), &mut second_scope)
        .await
        .is_err());
    second_scope.close().await;

    state
        .close_transport_path(peer_id)
        .await
        .expect("close Session");
    wait_for_active_task_count(&state.task_supervisor, 0).await;
    assert_eq!(state.task_supervisor.active_count(), 0);
}

#[tokio::test]
async fn outbound_generic_peer_restart_replaces_session_and_cancels_old_tasks() {
    // §18：peer restart（新 remote binding）会让新连接整体替换旧 Session（新
    // SessionId + 新 root），并且旧 Session 的 task group 在 admission 时立即取消。
    let state = new_test_state().await;
    let peer_id = "generic-outbound-restart-peer";
    state.allow_routes_for_test(peer_id).await;
    let local_peer_id = "generic-outbound-local";
    let old_session_id = started_session(&state, peer_id).await;
    let old_remote_binding = "11".repeat(16);
    let new_remote_binding = "22".repeat(16);
    state
        .connection_sessions
        .admit_authenticated_session(peer_id, Some(old_session_id), &old_remote_binding)
        .await
        .expect("seed the old remote Session binding");
    state
        .connection_sessions
        .finalize_authenticated_session(peer_id, old_session_id, &old_remote_binding)
        .await
        .expect("finalize the old remote Session binding");

    // 在握手前把哨兵放进旧 Session 组，验证被替换后立即取消。
    let (sentinel_started_tx, sentinel_started_rx) = oneshot::channel();
    let (sentinel_cancelled_tx, sentinel_cancelled_rx) = oneshot::channel();
    let sentinel_task = state.task_supervisor.spawn_session(
        old_session_id.wire_key(),
        "old-session-sentinel",
        async move {
            let mut signal = CancellationSignal {
                started: Some(sentinel_started_tx),
                cancelled: Some(sentinel_cancelled_tx),
            };
            if let Some(sender) = signal.started.take() {
                let _ = sender.send(());
            }
            std::future::pending::<()>().await;
        },
    );
    assert!(sentinel_task.is_some(), "old Session sentinel should start");
    timeout(Duration::from_secs(1), sentinel_started_rx)
        .await
        .expect("old Session sentinel did not start")
        .expect("old Session sentinel start signal was dropped");

    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        local_peer_id.to_string(),
        [201u8; 32],
        [211u8; 32],
    ));
    let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
        peer_id.to_string(),
        [202u8; 32],
        [212u8; 32],
    ));
    let local_public_key = local_identity.public_identity_key().to_bytes();
    let remote_public_key = remote_identity.public_identity_key().to_bytes();
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind outbound GenericRoute test listener");
    let endpoint = listener
        .local_addr()
        .expect("outbound GenericRoute test endpoint");
    let (release_tx, release_rx) = oneshot::channel();
    let (received_frame_tx, received_frame_rx) = oneshot::channel();
    let expected_old_binding = old_session_id.wire_key();
    let expected_local_peer_id = local_peer_id.to_string();
    let responder_task = tokio::spawn(async move {
        let (stream, _) = listener
            .accept()
            .await
            .expect("accept outbound GenericRoute test connection");
        let mut connection =
            GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(stream)));
        let trusted_peer_keys = tokio::sync::RwLock::new(HashMap::from([(
            expected_local_peer_id.clone(),
            local_public_key,
        )]));
        let authenticated = authenticate_responder(
            &mut connection,
            remote_identity,
            &trusted_peer_keys,
            move |authenticated_peer_id, remote_session_binding| {
                assert_eq!(authenticated_peer_id, expected_local_peer_id);
                assert_eq!(remote_session_binding, expected_old_binding);
                async move { Ok((new_remote_binding, ())) }
            },
        )
        .await
        .expect("complete outbound GenericRoute authentication");
        assert_eq!(authenticated.peer_id, local_peer_id);
        let received_frame = timeout(Duration::from_secs(1), connection.recv())
            .await
            .expect("outbound GenericRoute frame was not received")
            .expect("read outbound GenericRoute frame");
        received_frame_tx
            .send(received_frame)
            .expect("send received GenericRoute frame to test");
        release_rx.await.expect("release responder connection");
    });

    let route = OutboundGenericConnector::connect_tcp_route(
        endpoint,
        local_identity,
        remote_public_key,
        peer_id.to_string(),
        old_session_id.wire_key(),
        Arc::clone(&state),
        old_session_id,
        DEFAULT_CONNECTION_CAPABILITY,
    )
    .await
    .expect("outbound TCP GenericRoute should authenticate");
    // 握手期间 admission 已经取消了旧 Session 组（含哨兵）。
    timeout(Duration::from_secs(1), sentinel_cancelled_rx)
        .await
        .expect("old Session cancellation did not complete during admission")
        .expect("old Session sentinel signal was dropped");

    let AuthenticatedGenericRoute {
        mut scope,
        admission,
        ..
    } = route;
    let new_session_id = admission.session_id;
    assert_ne!(new_session_id, old_session_id);

    state
        .attach_generic_route_for_session(peer_id, Some(new_session_id), &mut scope)
        .await
        .expect("attach outbound GenericRoute to replacement Session");

    wait_for_active_task_count(&state.task_supervisor, 2).await;
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        Some(new_session_id)
    );

    let payload = b"replacement-route-still-alive";
    timeout(
        Duration::from_secs(1),
        send_channel_frame_for_test(&state, peer_id, "", GenericFrameKind::DataMessage, payload),
    )
    .await
    .expect("sending through replacement GenericRoute timed out")
    .expect("replacement GenericRoute should still send frames");
    let received_frame = timeout(Duration::from_secs(1), received_frame_rx)
        .await
        .expect("replacement GenericRoute frame confirmation timed out")
        .expect("replacement GenericRoute frame confirmation was dropped");
    let mut expected_frame = b"SMGF".to_vec();
    expected_frame.extend_from_slice(&network_protocol::NETWORK_PROTOCOL_VERSION.to_be_bytes());
    expected_frame.push(GenericFrameKind::DataMessage as u8);
    expected_frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    expected_frame.extend_from_slice(payload);
    assert_eq!(received_frame, expected_frame);

    state
        .close_transport_path(peer_id)
        .await
        .expect("close replacement GenericRoute");
    let _ = release_tx.send(());
    responder_task
        .await
        .expect("outbound GenericRoute responder should exit");
    wait_for_active_task_count(&state.task_supervisor, 0).await;
    assert_eq!(state.task_supervisor.active_count(), 0);
}

#[tokio::test]
async fn inbound_authenticated_generic_route_commits_a_fresh_session() {
    let state = new_test_state().await;
    let peer_id = "generic-inbound-success-peer";
    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        "generic-inbound-local".into(),
        [231u8; 32],
        [241u8; 32],
    ));
    let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
        peer_id.into(),
        [232u8; 32],
        [242u8; 32],
    ));
    *state.lifecycle.identity.write().await = Some(Arc::clone(&local_identity));
    state.peers.write().await.insert(
        peer_id.into(),
        PeerConfig {
            endpoint: None,
            identity_public_key: remote_identity.public_identity_key().to_bytes(),
            e2e_public_key: remote_identity.public_e2e_key().to_bytes(),
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test(peer_id.into()).await;
    state.trusted_peer_keys.write().await.insert(
        peer_id.into(),
        remote_identity.public_identity_key().to_bytes(),
    );

    let (mut client, server_stream) = generic_connection_pair().await;
    let server =
        GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(server_stream)));
    let session_binding = "33".repeat(16);
    let callback_binding = session_binding.clone();
    let client_identity = Arc::clone(&remote_identity);
    let expected_local_key = local_identity.public_identity_key().to_bytes();
    let (release_tx, release_rx) = oneshot::channel();
    let client_task = tokio::spawn(async move {
        let result = authenticate_initiator_with_policy(
            &mut client,
            client_identity,
            "generic-inbound-local",
            expected_local_key,
            &session_binding,
            crate::crypto_handshake::path_handshake::E2eePolicy::Required,
            move |_peer_id, _remote_binding| {
                let callback_binding = callback_binding.clone();
                async move { Ok((callback_binding, ())) }
            },
        )
        .await;
        release_rx.await.expect("hold authenticated client route");
        result
    });
    let server_result = InboundConnectionAcceptor::accept_authenticated_generic(
        Arc::clone(&state),
        server,
        "127.0.0.1:39001".parse().expect("peer address"),
    )
    .await;
    server_result.expect("authenticated inbound GenericRoute should be admitted");
    assert!(state.path_is_connected(peer_id).await);
    let session_id = state
        .connection_sessions
        .current_session_id(peer_id)
        .await
        .expect("inbound route session");
    assert!(state
        .crypto_context(peer_id, &session_id.wire_key())
        .await
        .is_ok());

    state
        .close_transport_path(peer_id)
        .await
        .expect("close inbound GenericRoute");
    state.task_supervisor.cancel_root();
    state.task_supervisor.shutdown().await;
    let _ = release_tx.send(());
    client_task
        .await
        .expect("client auth task")
        .expect("outbound side should authenticate");
}

#[tokio::test]
async fn failed_generic_attach_drops_staged_scope_without_orphan_tasks() {
    let state = new_test_state().await;
    let session_id = started_session(&state, "generic-failed-attach-peer").await;
    let (connection, mut server) = generic_connection_pair().await;
    let mut scope =
        started_generic_scope(&state, "generic-failed-attach-peer", session_id, connection).await;
    state
        .close_transport_path("generic-failed-attach-peer")
        .await;
    let _ = state
        .connection_sessions
        .retire_session("generic-failed-attach-peer", session_id)
        .await;
    assert!(state
        .attach_generic_route_for_session(
            "generic-failed-attach-peer",
            Some(session_id),
            &mut scope,
        )
        .await
        .is_err());
    scope.close().await;
    assert_eq!(state.task_supervisor.active_count(), 0);

    let mut buffer = [0u8; 1];
    let read = tokio::time::timeout(Duration::from_secs(2), server.read(&mut buffer))
        .await
        .expect("failed attach should close staged socket")
        .expect("read failed attach socket");
    assert_eq!(read, 0);
}

#[test]
fn runtime_stop_joins_generic_route_tasks() {
    let runtime = crate::runtime::NetworkRuntime::new().expect("create runtime");
    runtime.start().expect("start runtime");
    let state = runtime
        .state
        .lock()
        .expect("runtime state lock")
        .clone()
        .expect("runtime state");
    let (server, scope) = runtime.handle().block_on(async {
        state
            .allow_routes_for_test("generic-runtime-stop-peer")
            .await;
        let session_id = started_session(&state, "generic-runtime-stop-peer").await;
        let (connection, server) = generic_connection_pair().await;
        let mut scope =
            started_generic_scope(&state, "generic-runtime-stop-peer", session_id, connection)
                .await;
        state
            .attach_generic_route_for_session(
                "generic-runtime-stop-peer",
                Some(session_id),
                &mut scope,
            )
            .await
            .expect("attach runtime GenericRoute");
        (server, scope)
    });
    drop(scope);
    runtime.stop().expect("stop runtime");
    assert_eq!(state.task_supervisor.active_count(), 0);
    runtime.handle().block_on(async {
        let mut server = server;
        let mut buffer = [0u8; 1];
        let read = tokio::time::timeout(Duration::from_secs(1), server.read(&mut buffer))
            .await
            .expect("runtime stop should close GenericRoute socket")
            .expect("read runtime-stop socket");
        assert_eq!(read, 0);
    });
}

#[tokio::test]
async fn losing_candidate_admit_never_replaces_attached_winner_session() {
    // §18/§40：race 两个 candidate 时，winner 已 attach route（Session Connected）后，
    // loser 迟到的 admit 不得触发 ReplaceWithNew——否则拆掉刚挂载的 winning route，
    // 双方都掉线。
    let state = new_test_state().await;
    let peer_id = "candidate-race-peer";
    state.allow_routes_for_test(peer_id).await;
    let session_id = started_session(&state, peer_id).await;
    let binding = "11".repeat(16);

    // winner：第一次 admit 成功，保持 in-flight Session（Initialize）。
    let winner = admit_single_winner(&state, peer_id, Some(session_id), &binding)
        .await
        .expect("winner admission should succeed");
    assert_eq!(winner.session_id, session_id);

    // winner 挂载一条 generic route（Session → Connected）。
    let (connection, _server) = generic_connection_pair().await;
    let mut scope = started_generic_scope(&state, peer_id, session_id, connection).await;
    state
        .attach_generic_route_for_session(peer_id, Some(session_id), &mut scope)
        .await
        .expect("attach winner generic route");
    assert!(state.path_is_connected(peer_id).await);

    // loser：同 (peer, expected_session_id) 的迟到 admit 必须被拒绝，绝不替换。
    assert!(
        admit_single_winner(&state, peer_id, Some(session_id), &binding)
            .await
            .is_err(),
        "losing candidate must not trigger a Session replacement"
    );

    // winner 的 Session 与 route 仍然存活（无 disconnect）。
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        Some(session_id)
    );
    assert!(state.path_is_connected(peer_id).await);

    state
        .close_transport_path(peer_id)
        .await
        .expect("close Session");
    wait_for_active_task_count(&state.task_supervisor, 0).await;
    assert_eq!(state.task_supervisor.active_count(), 0);
}

#[tokio::test]
async fn tcp_fallback_accept_loop_survives_transient_accept_errors() {
    // §40：瞬态 accept 错误（EMFILE/aborted/reset 等）只退避重试，不得终止 inbound
    // TCP/WS 回退；后续真实连接仍被接受。
    let state = new_test_state().await;
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind accept listener");
    let address = listener.local_addr().expect("accept listener address");
    let loop_task = tokio::spawn(InboundConnectionAcceptor::accept_tcp_loop(
        listener,
        Arc::clone(&state),
        Box::new(InjectOnceTransientAcceptError { injected: true }),
    ));
    // 等循环处理注入的错误 + 退避。
    tokio::time::sleep(Duration::from_millis(150)).await;

    // 建立一条真实连接：循环必须继续 accept 并派生 handshake 任务。
    let _client = TcpStream::connect(address)
        .await
        .expect("connect after transient accept error");
    timeout(Duration::from_secs(2), async {
        loop {
            if state.task_supervisor.active_count() >= 1 {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("accept loop did not process the connection after the transient error");
    loop_task.abort();
}

#[tokio::test]
async fn tcp_fallback_accept_loop_exits_on_fatal_listener_error() {
    // §40：只有致命错误（listener 已关闭 / fd 失效）才终止 accept 循环。
    let state = new_test_state().await;
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind accept listener");
    let outcome = tokio::time::timeout(
        Duration::from_secs(1),
        InboundConnectionAcceptor::accept_tcp_loop(
            listener,
            Arc::clone(&state),
            Box::new(FatalAcceptError),
        ),
    )
    .await;
    assert!(
        outcome.is_ok(),
        "fatal accept errors must terminate the TCP fallback accept loop"
    );
}

/// 注入一次瞬态 accept 错误，之后委托真实 `TcpListener::accept` 的测试 accept 步骤。
struct InjectOnceTransientAcceptError {
    injected: bool,
}

impl TcpAcceptStep for InjectOnceTransientAcceptError {
    fn accept<'a>(
        &'a mut self,
        listener: &'a TcpListener,
    ) -> Pin<
        Box<dyn Future<Output = std::io::Result<(tokio::net::TcpStream, SocketAddr)>> + Send + 'a>,
    > {
        if self.injected {
            self.injected = false;
            Box::pin(async {
                Err(std::io::Error::new(
                    std::io::ErrorKind::ConnectionAborted,
                    "injected transient accept error",
                ))
            })
        } else {
            Box::pin(listener.accept())
        }
    }
}

/// 始终返回致命 accept 错误的测试 accept 步骤（listener 已关闭）。
struct FatalAcceptError;

impl TcpAcceptStep for FatalAcceptError {
    fn accept<'a>(
        &'a mut self,
        _listener: &'a TcpListener,
    ) -> Pin<
        Box<dyn Future<Output = std::io::Result<(tokio::net::TcpStream, SocketAddr)>> + Send + 'a>,
    > {
        Box::pin(async {
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "listener closed",
            ))
        })
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn generic_candidate_races_tcp_and_websocket_concurrently() {
    let state = new_test_state().await;
    let peer_id = "generic-race-peer";
    let local_peer_id = "generic-race-local";
    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        local_peer_id.to_string(),
        [81u8; 32],
        [91u8; 32],
    ));
    let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
        peer_id.to_string(),
        [82u8; 32],
        [92u8; 32],
    ));
    let remote_public_key = remote_identity.public_identity_key().to_bytes();
    let session_id = match state
        .begin_connect(peer_id, crate::connect::CAPABILITY_RELIABLE_MESSAGE)
        .await
    {
        ConnectDecision::Started(session_id) => session_id,
        decision => panic!("unexpected Session decision: {decision:?}"),
    };
    let (endpoint, release_tx, responder_task) =
        spawn_mixed_generic_responder(peer_id, local_peer_id).await;
    let route = tokio::time::timeout(
        Duration::from_secs(3),
        OutboundGenericConnector::connect_generic_candidate(
            endpoint,
            local_identity,
            remote_public_key,
            peer_id.to_string(),
            session_id.wire_key(),
            Arc::clone(&state),
            session_id,
            CAPABILITY_RELIABLE_MESSAGE,
            true,
            Duration::from_secs(1),
        ),
    )
    .await
    .expect("TCP/WS candidate race should finish within the candidate window")
    .expect("WebSocket should win while TCP is blackholed");

    let AuthenticatedGenericRoute { scope, .. } = route;
    assert_eq!(
        scope
            .profile()
            .expect("staged generic route profile")
            .transport(),
        RouteTransport::WebSocket,
        "WebSocket must race TCP instead of waiting for TCP to fail"
    );
    scope.close().await;
    state.cancel_session_tasks(peer_id, session_id).await;
    let _ = release_tx.send(());
    responder_task
        .await
        .expect("mixed generic responder should exit");
    state.task_supervisor.cancel_root();
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn generic_candidate_authentication_failure_is_typed_and_cleans_session() {
    let state = new_test_state().await;
    let peer_id = "generic-auth-peer";
    let local_peer_id = "generic-auth-local";
    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        local_peer_id.to_string(),
        [101u8; 32],
        [111u8; 32],
    ));
    let expected_remote =
        DeviceIdentity::from_private_keys(peer_id.to_string(), [102u8; 32], [112u8; 32]);
    let wrong_remote = Arc::new(DeviceIdentity::from_private_keys(
        "not-the-configured-peer".into(),
        [103u8; 32],
        [113u8; 32],
    ));
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind authentication failure responder");
    let endpoint = listener
        .local_addr()
        .expect("authentication failure responder address");
    let local_public_key = local_identity.public_identity_key().to_bytes();
    let responder_task = tokio::spawn(async move {
        let (stream, _) = listener
            .accept()
            .await
            .expect("accept authentication failure connection");
        let mut connection =
            GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(stream)));
        let trusted_peer_keys = tokio::sync::RwLock::new(HashMap::from([(
            local_peer_id.to_string(),
            local_public_key,
        )]));
        let _ =
            authenticate_responder(
                &mut connection,
                wrong_remote,
                &trusted_peer_keys,
                |_authenticated_peer_id, _remote_session_binding| async move {
                    Ok(("44".repeat(16), ()))
                },
            )
            .await;
    });
    let session_id = started_session(&state, peer_id).await;
    let result = tokio::time::timeout(
        Duration::from_secs(2),
        OutboundGenericConnector::connect_generic_candidate(
            endpoint,
            local_identity,
            expected_remote.public_identity_key().to_bytes(),
            peer_id.to_string(),
            session_id.wire_key(),
            Arc::clone(&state),
            session_id,
            CAPABILITY_RELIABLE_MESSAGE,
            false,
            Duration::from_secs(1),
        ),
    )
    .await
    .expect("generic authentication failure should finish within the window");
    let error = match result {
        Ok(_) => panic!("a mismatched generic identity unexpectedly authenticated"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::AuthenticationFailed as i32);
    responder_task
        .await
        .expect("authentication failure responder should exit");
    state.cancel_session_tasks(peer_id, session_id).await;
}

#[tokio::test]
async fn generic_candidate_timeout_closes_unauthenticated_socket() {
    let state = new_test_state().await;
    let peer_id = "generic-timeout-peer";
    let local_peer_id = "generic-timeout-local";
    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        local_peer_id.to_string(),
        [121u8; 32],
        [131u8; 32],
    ));
    let expected_remote =
        DeviceIdentity::from_private_keys(peer_id.to_string(), [122u8; 32], [132u8; 32]);
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind generic timeout responder");
    let endpoint = listener
        .local_addr()
        .expect("generic timeout responder address");
    let (release_tx, release_rx) = oneshot::channel();
    let responder_task = tokio::spawn(async move {
        let (_stream, _) = listener
            .accept()
            .await
            .expect("accept generic timeout connection");
        let _ = release_rx.await;
    });
    let session_id = started_session(&state, peer_id).await;
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        OutboundGenericConnector::connect_generic_candidate(
            endpoint,
            local_identity,
            expected_remote.public_identity_key().to_bytes(),
            peer_id.to_string(),
            session_id.wire_key(),
            Arc::clone(&state),
            session_id,
            CAPABILITY_RELIABLE_MESSAGE,
            false,
            Duration::from_millis(20),
        ),
    )
    .await
    .expect("generic timeout should finish within the test bound");
    let error = match result {
        Ok(_) => panic!("an unauthenticated generic socket unexpectedly succeeded"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::Timeout as i32);
    let _ = release_tx.send(());
    responder_task
        .await
        .expect("generic timeout responder should exit");
    state.cancel_session_tasks(peer_id, session_id).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn websocket_candidate_without_stream_capability_does_not_admit_route() {
    let state = new_test_state().await;
    let peer_id = "generic-capability-peer";
    let local_peer_id = "generic-capability-local";
    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        local_peer_id.to_string(),
        [81u8; 32],
        [91u8; 32],
    ));
    let remote_identity =
        DeviceIdentity::from_private_keys(peer_id.to_string(), [82u8; 32], [92u8; 32]);
    let (endpoint, release_tx, responder_task) =
        spawn_mixed_generic_responder(peer_id, local_peer_id).await;
    let session_id = started_session(&state, peer_id).await;
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        OutboundGenericConnector::connect_generic_candidate(
            endpoint,
            local_identity,
            remote_identity.public_identity_key().to_bytes(),
            peer_id.to_string(),
            session_id.wire_key(),
            Arc::clone(&state),
            session_id,
            CAPABILITY_RELIABLE_STREAM,
            true,
            Duration::from_millis(100),
        ),
    )
    .await
    .expect("capability rejection should finish within the candidate window");
    let error = match result {
        Ok(_) => panic!("WebSocket must not be admitted as a stream-capable route"),
        Err(error) => error,
    };
    // WebSocket is connected and then dropped before Noise authentication,
    // because its profile cannot carry ReliableStream. The companion TCP
    // attempt stays open, so the bounded race reports Timeout and no stream
    // route is admitted.
    assert_eq!(error.code, NetworkErrorCode::Timeout as i32);
    let _ = release_tx.send(());
    responder_task
        .await
        .expect("capability rejection responder should exit");
    state.cancel_session_tasks(peer_id, session_id).await;
}

fn unconnected_relay_data_client() -> Arc<RelayDataClient> {
    Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("valid unconnected Relay data client"),
    )
}

#[tokio::test]
async fn relay_crypto_step_receiver_rejects_out_of_order_and_closed_channels() {
    let (sender, mut receiver) = mpsc::channel(1);
    sender
        .send((crate::crypto_handshake::RELAY_CRYPTO_FINAL, vec![1, 2, 3]))
        .await
        .expect("queue out-of-order Relay crypto step");
    let out_of_order = receive_relay_crypto_step(
        &mut receiver,
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
        "relay-step-peer",
    )
    .await
    .expect_err("out-of-order Relay crypto step must fail closed");
    assert_eq!(
        out_of_order.code,
        NetworkErrorCode::AuthenticationFailed as i32
    );

    let (sender, mut receiver) = mpsc::channel(1);
    drop(sender);
    let closed = receive_relay_crypto_step(
        &mut receiver,
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
        "relay-step-peer",
    )
    .await
    .expect_err("closed Relay crypto waiter must map to timeout");
    assert_eq!(closed.code, NetworkErrorCode::Timeout as i32);

    let (sender, mut receiver) = mpsc::channel(1);
    sender
        .send((crate::crypto_handshake::RELAY_CRYPTO_RESPONSE, vec![4, 5]))
        .await
        .expect("queue expected Relay crypto step");
    let payload = receive_relay_crypto_step(
        &mut receiver,
        crate::crypto_handshake::RELAY_CRYPTO_RESPONSE,
        "relay-step-peer",
    )
    .await
    .expect("expected Relay crypto step should be returned");
    assert_eq!(payload, vec![4, 5]);
}

#[tokio::test]
async fn relay_crypto_rejects_disabled_policy_and_cleans_session() {
    let state = new_test_state().await;
    let peer_id = "relay-disabled-peer";
    state.peers.write().await.insert(
        peer_id.into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [141u8; 32],
            e2e_public_key: [151u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Disabled,
        },
    );
    state.allow_routes_for_test(peer_id.into()).await;
    let session_id = started_session(&state, peer_id).await;
    let identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-a".into(),
        [142u8; 32],
        [152u8; 32],
    ));
    let result = establish_relay_crypto(
        &state,
        unconnected_relay_data_client(),
        peer_id,
        session_id,
        identity,
        [153u8; 32],
    )
    .await;
    let error = match result {
        Ok(_) => panic!("Relay E2EE unexpectedly started for a disabled policy"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::AuthenticationFailed as i32);
    assert!(state.relay.crypto_waiters.read().await.is_empty());
    assert!(state
        .connection_sessions
        .current_session_id(peer_id)
        .await
        .is_none());
}

#[tokio::test]
async fn relay_crypto_send_failure_removes_waiter_without_leaking_state() {
    let state = new_test_state().await;
    let peer_id = "relay-send-failure-peer";
    state.peers.write().await.insert(
        peer_id.into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [161u8; 32],
            e2e_public_key: [171u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test(peer_id.into()).await;
    let session_id = started_session(&state, peer_id).await;
    let identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-a".into(),
        [162u8; 32],
        [172u8; 32],
    ));
    let result = establish_relay_crypto(
        &state,
        unconnected_relay_data_client(),
        peer_id,
        session_id,
        identity,
        [173u8; 32],
    )
    .await;
    let error = match result {
        Ok(_) => panic!("an unconnected Relay data client unexpectedly sent a hello"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::RelayError as i32);
    assert!(state.relay.crypto_waiters.read().await.is_empty());
    assert_eq!(
        state.connection_sessions.current_session_id(peer_id).await,
        Some(session_id)
    );
    state.cancel_session_tasks(peer_id, session_id).await;
}

#[tokio::test]
async fn inbound_admission_requires_configured_peer_and_marks_supervisor_online() {
    let state = new_test_state().await;
    let missing = InboundConnectionAcceptor::admit_authenticated_inbound(
        &state,
        "unknown-peer",
        DEFAULT_CONNECTION_CAPABILITY,
    )
    .await
    .expect_err("inbound authentication must require peer configuration");
    assert!(missing.to_string().contains("not configured"));

    let peer_id = "inbound-configured-peer";
    state.peers.write().await.insert(
        peer_id.into(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [181u8; 32],
            e2e_public_key: [191u8; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test(peer_id.into()).await;
    InboundConnectionAcceptor::admit_authenticated_inbound(
        &state,
        peer_id,
        CAPABILITY_RELIABLE_MESSAGE,
    )
    .await
    .expect("configured inbound peer should be admitted");
    assert_eq!(
        state
            .peer_supervisors
            .get_or_create(peer_id)
            .expect("peer supervisor")
            .state(),
        crate::connect::PeerState::Online
    );

    state.peer_route_authorizations.write().await.insert(
        peer_id.into(),
        crate::runtime::PeerRouteAuthorization {
            direct: false,
            relay: true,
        },
    );
    let revoked = InboundConnectionAcceptor::admit_authenticated_inbound(
        &state,
        peer_id,
        CAPABILITY_RELIABLE_MESSAGE,
    )
    .await
    .expect_err("inbound Direct admission must honor a revoked route");
    assert!(revoked.to_string().contains("not authorized"));
}

#[test]
fn candidate_snapshot_requeues_changed_endpoint_and_drops_deleted_pending() {
    let mut old = Candidate::new(
        "192.0.2.10:41000".parse().expect("old endpoint"),
        CandidateKind::Lan,
        "same-interface".into(),
    )
    .with_generation(1);
    old.candidate_id = "same-candidate".into();
    let mut deleted = Candidate::new(
        "192.0.2.11:41001".parse().expect("deleted endpoint"),
        CandidateKind::Lan,
        "deleted-interface".into(),
    );
    deleted.candidate_id = "deleted-candidate".into();

    let mut pending = VecDeque::new();
    let mut started = HashSet::new();
    enqueue_candidates(&mut pending, &mut started, vec![old, deleted]);
    let launched = pending.pop_front().expect("old candidate should be queued");
    started.insert(candidate_attempt_key(&launched));

    let mut updated = Candidate::new(
        "198.51.100.10:42000".parse().expect("updated endpoint"),
        CandidateKind::Lan,
        "same-interface".into(),
    )
    .with_generation(2);
    updated.candidate_id = "same-candidate".into();
    enqueue_candidates(&mut pending, &mut started, vec![updated.clone()]);

    assert_eq!(pending.len(), 1, "the updated candidate should be requeued");
    let queued = pending
        .front()
        .expect("updated candidate should remain pending");
    assert_eq!(queued.candidate_id, updated.candidate_id);
    assert_eq!(queued.endpoint, updated.endpoint);
    assert_eq!(queued.generation, updated.generation);
    assert!(!started.contains(&candidate_attempt_key(&updated)));

    enqueue_candidates(&mut pending, &mut started, vec![updated]);
    assert_eq!(
        pending.len(),
        1,
        "the same snapshot must not duplicate a pending candidate"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn late_quic_candidate_arriving_before_direct_deadline_can_win() {
    let client_state = new_test_state().await;
    let server_state = new_test_state().await;
    let local_peer_id = "late-candidate-local";
    let peer_id = "late-candidate-peer";

    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        local_peer_id.to_string(),
        [61u8; 32],
        [71u8; 32],
    ));
    let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
        peer_id.to_string(),
        [62u8; 32],
        [72u8; 32],
    ));
    let remote_public_key = remote_identity.public_identity_key().to_bytes();
    *client_state.lifecycle.identity.write().await = Some(Arc::clone(&local_identity));
    *server_state.lifecycle.identity.write().await = Some(remote_identity);
    server_state.peers.write().await.insert(
        local_peer_id.to_string(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: local_identity.public_identity_key().to_bytes(),
            e2e_public_key: local_identity.public_e2e_key().to_bytes(),
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    server_state.allow_routes_for_test(local_peer_id).await;
    server_state.trusted_peer_keys.write().await.insert(
        local_peer_id.to_string(),
        local_identity.public_identity_key().to_bytes(),
    );

    let server_endpoint = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("server bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create server QUIC endpoint")
    .endpoint;
    let server_address = server_endpoint
        .local_addr()
        .expect("server endpoint address");
    server_state
        .task_supervisor
        .spawn_runtime(
            "late-candidate-quic-accept",
            InboundConnectionAcceptor::accept_connections(
                server_endpoint.clone(),
                Arc::clone(&server_state),
            ),
        )
        .expect("start server QUIC accept loop");

    let client_endpoint = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("client bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create client QUIC endpoint")
    .endpoint;
    let session_id = started_session(&client_state, peer_id).await;

    // C1 fails immediately. The Direct phase must still keep its coordination
    // receiver alive long enough for the authenticated ConnectivityAnswer to add C2.
    let first_candidate = Candidate::new(
        "127.0.0.1:0".parse().expect("invalid direct endpoint"),
        CandidateKind::Lan,
        "late-candidate-c1".into(),
    );
    let reachable_candidate = Candidate::new(
        server_address,
        CandidateKind::Lan,
        "late-candidate-c2".into(),
    );
    let (candidate_update_tx, candidate_updates) = watch::channel(None);
    let update_task = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        candidate_update_tx
            .send(Some(vec![reachable_candidate]))
            .expect("late candidate update receiver should remain alive");
    });

    let attempt = DirectRouteAttempt {
        state: Arc::clone(&client_state),
        endpoint: client_endpoint.clone(),
        candidates: vec![first_candidate],
        identity: local_identity,
        expected_peer_public_key: remote_public_key,
        peer_id: peer_id.to_string(),
        session_binding: session_id.wire_key(),
        session_id,
        attempt_id: "late-quic-candidate-test".into(),
        // Exercise the production Direct window so a busy test runner does not
        // turn the candidate-update assertion into a scheduler race.
        connect_window: crate::connect::DIRECT_CONNECT_WINDOW,
        required_capabilities: DEFAULT_CONNECTION_CAPABILITY | CAPABILITY_UNRELIABLE_DATAGRAM,
        allow_websocket: true,
        candidate_updates,
    };
    let route = tokio::time::timeout(
        crate::connect::DIRECT_CONNECT_WINDOW + Duration::from_secs(2),
        connect_direct_or_generic(attempt),
    )
    .await
    .expect("late QUIC candidate should finish within Direct window")
    .expect("late reachable QUIC candidate should win Direct race");
    update_task
        .await
        .expect("candidate update task should finish");

    let ConnectedRoute::Quic { connection, .. } = route else {
        panic!("expected the late candidate to produce a QUIC route");
    };
    connection.close(quinn::VarInt::from_u32(0), b"test complete");

    client_state.cancel_session_tasks(peer_id, session_id).await;
    if let Some(server_session_id) = server_state
        .connection_sessions
        .current_session_id(local_peer_id)
        .await
    {
        server_state
            .cancel_session_tasks(local_peer_id, server_session_id)
            .await;
    }
    client_endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
    server_endpoint.close(quinn::VarInt::from_u32(0), b"test complete");
    client_state.task_supervisor.cancel_root();
    server_state.task_supervisor.cancel_root();
    client_state.task_supervisor.shutdown().await;
    server_state.task_supervisor.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn generic_direct_route_gets_budget_when_quic_candidates_are_blackholed() {
    // §15/§37：QUIC 候选被黑洞（UDP socket 收包但不响应）时不得耗尽整个 Direct 窗口——
    // generic（TCP/WebSocket）候选应拿到自己的时间片；仅 TCP 可达的 peer 在窗口内走
    // generic 成功，而不是直接超时回退 Relay。
    let state = new_test_state().await;
    let peer_id = "generic-budget-peer";
    let local_peer_id = "generic-budget-local";

    // QUIC 黑洞：绑定 UDP socket 但从不读取/响应 → QUIC candidate 挂到子预算超时。
    let blackhole = std::net::UdpSocket::bind("127.0.0.1:0").expect("bind UDP blackhole");
    let blackhole_address = blackhole.local_addr().expect("blackhole address");

    // 可用的 generic（TCP）路由。
    let (responder_address, release_tx, responder_task) =
        spawn_tcp_generic_responder(peer_id, local_peer_id).await;

    // 发起方 QUIC endpoint（仅用于发起 candidate 连接）。
    let endpoint_manager = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("wildcard address"),
        Arc::new(PathManager::new()),
    )
    .expect("create QUIC endpoint");
    let endpoint = endpoint_manager.endpoint;
    let endpoint_for_cleanup = endpoint.clone();

    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        local_peer_id.to_string(),
        [41u8; 32],
        [51u8; 32],
    ));
    let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
        peer_id.to_string(),
        [42u8; 32],
        [52u8; 32],
    ));
    let remote_public_key = remote_identity.public_identity_key().to_bytes();
    let session_id = started_session(&state, peer_id).await;

    let candidates = vec![
        Candidate::new(
            blackhole_address,
            CandidateKind::Lan,
            "test-blackhole".into(),
        ),
        Candidate::new(responder_address, CandidateKind::Lan, "test-tcp".into()),
    ];
    let (candidate_update_tx, candidate_updates) = watch::channel(None);
    drop(candidate_update_tx);

    let attempt = DirectRouteAttempt {
        state: Arc::clone(&state),
        endpoint,
        candidates,
        identity: local_identity,
        expected_peer_public_key: remote_public_key,
        peer_id: peer_id.to_string(),
        session_binding: session_id.wire_key(),
        session_id,
        attempt_id: "generic-budget-test".into(),
        connect_window: crate::connect::DIRECT_CONNECT_WINDOW,
        // This fixture intentionally exposes only TCP; transport racing has
        // a separate regression test below.
        required_capabilities: CAPABILITY_RELIABLE_STREAM,
        allow_websocket: false,
        candidate_updates,
    };

    // QUIC 被黑洞耗掉自己的子预算后，generic 用窗口剩余预算走 TCP 成功。
    let route = tokio::time::timeout(Duration::from_secs(5), connect_direct_or_generic(attempt))
        .await
        .expect("direct phase must finish within the window")
        .expect("peer reachable only via TCP must succeed via the generic path within the window");

    let ConnectedRoute::Generic(generic) = route else {
        panic!("expected a generic route for a TCP-only reachable peer");
    };
    generic.scope.close().await;

    let _ = release_tx.send(());
    responder_task.await.expect("generic responder should exit");
    endpoint_for_cleanup.close(quinn::VarInt::from_u32(0), b"test complete");
}

/// 在同一个 endpoint 上把 TCP 连接保持为黑洞，并为 WebSocket 连接完成认证。
/// 这样可以验证同一个 candidate 内两种 generic transport 会并发 race。
async fn spawn_mixed_generic_responder(
    peer_id: &str,
    local_peer_id: &str,
) -> (SocketAddr, oneshot::Sender<()>, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind mixed generic responder");
    let address = listener.local_addr().expect("mixed responder address");
    let peer_id = peer_id.to_string();
    let local_peer_id = local_peer_id.to_string();
    let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
        peer_id, [82u8; 32], [92u8; 32],
    ));
    let local_public_key =
        DeviceIdentity::from_private_keys(local_peer_id.clone(), [81u8; 32], [91u8; 32])
            .public_identity_key()
            .to_bytes();
    let (release_tx, release_rx) = oneshot::channel();
    let responder_task = tokio::spawn(async move {
        let trusted_peer_keys =
            tokio::sync::RwLock::new(HashMap::from([(local_peer_id, local_public_key)]));
        let mut release_rx = release_rx;
        let mut raw_connections = Vec::new();
        let mut websocket_seen = false;
        loop {
            tokio::select! {
                _ = &mut release_rx => break,
                accepted = listener.accept() => {
                    let (stream, _) = accepted.expect("accept mixed generic connection");
                    let mut probe = [0u8; 4];
                    let looks_like_websocket = tokio::time::timeout(
                        Duration::from_secs(1),
                        stream.peek(&mut probe),
                    )
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .is_some_and(|length| length == probe.len() && &probe == b"GET ");
                    if looks_like_websocket {
                        let socket = WebSocketTransport::accept(stream)
                            .await
                            .expect("accept WebSocket transport");
                        let mut connection = GenericConnection::from_transport(
                            Transport::WebSocket(Box::new(socket)),
                        );
                        websocket_seen = true;
                        // The client drops a WebSocket whose profile cannot carry
                        // the requested capability before the Noise handshake.
                        let _ = authenticate_responder(
                            &mut connection,
                            Arc::clone(&remote_identity),
                            &trusted_peer_keys,
                            |_authenticated_peer_id, _remote_session_binding| async move {
                                Ok(("33".repeat(16), ()))
                            },
                        )
                        .await;
                    } else {
                        // TCP has connected but the responder never sends the generic
                        // handshake, so the TCP race remains a blackhole.
                        raw_connections.push(stream);
                    }
                }
            }
        }
        assert!(
            websocket_seen,
            "the mixed responder should observe a WebSocket attempt"
        );
        drop(raw_connections);
    });
    (address, release_tx, responder_task)
}

/// 启动一个接受单条 TCP 连接并完成 generic responder 握手的测试对端。
async fn spawn_tcp_generic_responder(
    peer_id: &str,
    local_peer_id: &str,
) -> (SocketAddr, oneshot::Sender<()>, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind generic responder");
    let address = listener.local_addr().expect("responder address");
    let peer_id = peer_id.to_string();
    let local_peer_id = local_peer_id.to_string();
    let remote_identity = Arc::new(DeviceIdentity::from_private_keys(
        peer_id, [42u8; 32], [52u8; 32],
    ));
    let local_public_key =
        DeviceIdentity::from_private_keys(local_peer_id.clone(), [41u8; 32], [51u8; 32])
            .public_identity_key()
            .to_bytes();
    let (release_tx, release_rx) = oneshot::channel();
    let responder_task = tokio::spawn(async move {
        let (stream, _) = listener
            .accept()
            .await
            .expect("accept generic responder connection");
        let mut connection =
            GenericConnection::from_transport(Transport::Tcp(TcpTransport::from_stream(stream)));
        let trusted_peer_keys =
            tokio::sync::RwLock::new(HashMap::from([(local_peer_id, local_public_key)]));
        let _ = authenticate_responder(
            &mut connection,
            remote_identity,
            &trusted_peer_keys,
            move |_authenticated_peer_id, _remote_session_binding| async move {
                Ok(("33".repeat(16), ()))
            },
        )
        .await;
        // 保持连接存活直到测试释放。
        let _ = release_rx.await;
    });
    (address, release_tx, responder_task)
}

#[test]
fn candidate_fixture_classification_covers_lan_ipv6_and_reflexive_paths() {
    assert_eq!(
        candidate_kind_for("192.168.1.20:41020".parse().unwrap()),
        CandidateKind::Lan
    );
    assert_eq!(
        candidate_kind_for("[2001:db8::20]:41021".parse().unwrap()),
        CandidateKind::PublicIpv6
    );
    assert_eq!(
        candidate_kind_for("198.51.100.20:41022".parse().unwrap()),
        CandidateKind::ServerReflexive
    );
}

#[test]
fn stun_server_parser_ignores_invalid_entries_and_caps_configuration() {
    let mut entries = vec![
        " 192.168.1.10:3478 ".to_string(),
        "not-an-address".to_string(),
        String::new(),
        "[2001:db8::10]:3479".to_string(),
    ];
    entries.extend((0..10).map(|index| format!("192.0.2.{index}:3478")));
    let servers = parse_stun_servers(&entries.join(","));
    assert_eq!(servers.len(), 8);
    assert_eq!(
        servers[0],
        "192.168.1.10:3478".parse::<SocketAddr>().unwrap()
    );
    assert_eq!(
        servers[1],
        "[2001:db8::10]:3479".parse::<SocketAddr>().unwrap()
    );
    assert!(parse_stun_servers(" , invalid ").is_empty());
}

#[test]
fn direct_candidate_queue_never_starts_a_relay_candidate() {
    let relay = Candidate::new(
        "203.0.113.20:41023".parse().unwrap(),
        CandidateKind::Relay,
        "relay".into(),
    );
    let lan = Candidate::new(
        "192.168.1.20:41024".parse().unwrap(),
        CandidateKind::Lan,
        "wifi".into(),
    );
    let mut pending = std::collections::VecDeque::new();
    let mut started = std::collections::HashSet::new();
    enqueue_candidates(&mut pending, &mut started, vec![relay, lan.clone()]);
    assert_eq!(pending.len(), 1);
    assert_eq!(
        pending.front().map(|candidate| candidate.kind),
        Some(lan.kind)
    );
}

#[test]
fn peer_candidate_keys_include_endpoint_and_generation() {
    let candidate = Candidate::new(
        "192.168.1.20:41024".parse().unwrap(),
        CandidateKind::Lan,
        "wifi".into(),
    )
    .with_generation(3);
    let key = candidate_attempt_key(&candidate);
    assert_eq!(key.candidate_id, candidate.candidate_id);
    assert_eq!(key.endpoint, candidate.endpoint);
    assert_eq!(key.generation, 3);
    let changed = Candidate {
        generation: 4,
        ..candidate.clone()
    };
    assert_ne!(key, candidate_attempt_key(&changed));
}

#[test]
fn accept_error_policy_retries_transient_listener_failures() {
    for kind in [
        std::io::ErrorKind::Interrupted,
        std::io::ErrorKind::WouldBlock,
        std::io::ErrorKind::ConnectionReset,
        std::io::ErrorKind::AddrInUse,
    ] {
        assert!(!InboundConnectionAcceptor::accept_error_is_fatal(
            &std::io::Error::from(kind)
        ));
    }
    assert!(InboundConnectionAcceptor::accept_error_is_fatal(
        &std::io::Error::from(std::io::ErrorKind::InvalidInput,)
    ));
    assert!(InboundConnectionAcceptor::accept_error_is_fatal(
        &std::io::Error::from(std::io::ErrorKind::Unsupported,)
    ));
}

#[test]
fn generic_receiver_stop_guard_only_cancels_when_route_is_not_stopping() {
    let token = crate::task_supervisor::CancellationToken::default();
    let stopping = Arc::new(AtomicBool::new(false));
    {
        let _guard = GenericReceiverStopGuard {
            route_stop: token.clone(),
            stopping: Arc::clone(&stopping),
        };
    }
    assert!(token.is_cancelled());

    let token = crate::task_supervisor::CancellationToken::default();
    stopping.store(true, Ordering::Release);
    {
        let _guard = GenericReceiverStopGuard {
            route_stop: token.clone(),
            stopping: Arc::clone(&stopping),
        };
    }
    assert!(!token.is_cancelled());
}

#[test]
fn monotonic_candidate_generation_never_moves_backward() {
    let first = monotonic_candidate_generation();
    let second = monotonic_candidate_generation();
    assert!(first >= 1);
    assert!(second >= first);
}

#[tokio::test]
async fn peer_configuration_boundaries_fail_closed_before_binding_resources() {
    let state = new_test_state().await;

    let invalid_device = configure_runtime(
        Arc::clone(&state),
        network_protocol::ConfigureRuntimeCommand::default(),
    )
    .await
    .expect_err("empty runtime device id must fail");
    assert_eq!(
        invalid_device.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let invalid_identity = configure_runtime(
        Arc::clone(&state),
        network_protocol::ConfigureRuntimeCommand {
            device_id: "device-a".into(),
            identity_private_key: vec![0; 31],
            e2e_private_key: vec![0; 32],
            listen_address: "127.0.0.1:0".into(),
            receive_directory: "/tmp/receive".into(),
        },
    )
    .await
    .expect_err("identity key length must be checked");
    assert_eq!(
        invalid_identity.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let invalid_e2e = configure_runtime(
        Arc::clone(&state),
        network_protocol::ConfigureRuntimeCommand {
            device_id: "device-a".into(),
            identity_private_key: vec![0; 32],
            e2e_private_key: vec![0; 31],
            listen_address: "127.0.0.1:0".into(),
            receive_directory: "/tmp/receive".into(),
        },
    )
    .await
    .expect_err("E2E key length must be checked");
    assert_eq!(invalid_e2e.code, NetworkErrorCode::InvalidArgument as i32);

    let invalid_address = configure_runtime(
        Arc::clone(&state),
        network_protocol::ConfigureRuntimeCommand {
            device_id: "device-a".into(),
            identity_private_key: vec![0; 32],
            e2e_private_key: vec![0; 32],
            listen_address: "not-an-address".into(),
            receive_directory: "/tmp/receive".into(),
        },
    )
    .await
    .expect_err("listen address must be parsed before binding");
    assert_eq!(
        invalid_address.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let relative_directory = configure_runtime(
        Arc::clone(&state),
        network_protocol::ConfigureRuntimeCommand {
            device_id: "device-a".into(),
            identity_private_key: vec![0; 32],
            e2e_private_key: vec![0; 32],
            listen_address: "127.0.0.1:0".into(),
            receive_directory: "relative".into(),
        },
    )
    .await
    .expect_err("receive directory must be absolute");
    assert_eq!(
        relative_directory.code,
        NetworkErrorCode::InvalidArgument as i32
    );
}

#[tokio::test]
async fn valid_runtime_configuration_binds_native_and_fallback_listeners_once() {
    let state = new_test_state().await;
    let receive_directory =
        std::env::temp_dir().join(format!("ssh-mobile-runtime-config-{}", std::process::id()));
    let command = network_protocol::ConfigureRuntimeCommand {
        device_id: "device-a".into(),
        identity_private_key: vec![1; 32],
        e2e_private_key: vec![2; 32],
        listen_address: "127.0.0.1:0".into(),
        receive_directory: receive_directory.to_string_lossy().into_owned(),
    };
    configure_runtime(Arc::clone(&state), command.clone())
        .await
        .expect("valid runtime configuration");
    assert!(state.lifecycle.bound_port.load(Ordering::Acquire) > 0);
    assert_eq!(
        state
            .lifecycle
            .identity
            .read()
            .await
            .as_ref()
            .map(|identity| identity.device_id.as_str()),
        Some("device-a")
    );
    assert!(state.local_discovery.read().await.is_some());

    let duplicate = configure_runtime(state.clone(), command)
        .await
        .expect_err("runtime can only be configured once");
    assert_eq!(duplicate.code, NetworkErrorCode::InvalidArgument as i32);
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn stale_quic_path_admission_is_rejected_before_publication() {
    let state = new_test_state().await;
    let current = started_session(&state, "stale-path-peer").await;
    let (endpoint, connection) = quic_connection_pair().await;
    assert!(state
        .attach_connection_for_session(
            "stale-path-peer",
            Some(SessionId::new()),
            connection,
            RouteType::QuicDirect,
        )
        .await
        .is_err());
    assert_eq!(
        state
            .connection_sessions
            .current_session_id("stale-path-peer")
            .await,
        Some(current)
    );
    endpoint.close(VarInt::from_u32(0), b"stale expected session complete");

    let state_without_session = new_test_state().await;
    let (endpoint, connection) = quic_connection_pair().await;
    assert!(state_without_session
        .attach_connection_for_session(
            "missing-session-peer",
            Some(SessionId::new()),
            connection,
            RouteType::QuicDirect,
        )
        .await
        .is_err());
    endpoint.close(VarInt::from_u32(0), b"stale missing session complete");
}

#[tokio::test]
async fn peer_upsert_and_disconnect_preserve_identity_and_route_boundaries() {
    let state = new_test_state().await;
    let invalid_peer = upsert_peer(
        &state,
        UpsertPeerCommand {
            peer_id: String::new(),
            ..Default::default()
        },
    )
    .await
    .expect_err("empty peer id must fail");
    assert_eq!(invalid_peer.code, NetworkErrorCode::InvalidArgument as i32);

    let invalid_endpoint = upsert_peer(
        &state,
        UpsertPeerCommand {
            peer_id: "peer-a".into(),
            endpoint_address: "invalid".into(),
            ..Default::default()
        },
    )
    .await
    .expect_err("peer endpoint must be a socket address");
    assert_eq!(
        invalid_endpoint.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let invalid_identity = upsert_peer(
        &state,
        UpsertPeerCommand {
            peer_id: "peer-a".into(),
            endpoint_address: "127.0.0.1:22".into(),
            identity_public_key: vec![0; 31],
            e2e_public_key: vec![0; 32],
        },
    )
    .await
    .expect_err("peer identity key must be 32 bytes");
    assert_eq!(
        invalid_identity.code,
        NetworkErrorCode::InvalidArgument as i32
    );

    let invalid_e2e = upsert_peer(
        &state,
        UpsertPeerCommand {
            peer_id: "peer-a".into(),
            endpoint_address: "127.0.0.1:22".into(),
            identity_public_key: vec![0; 32],
            e2e_public_key: vec![0; 31],
        },
    )
    .await
    .expect_err("peer E2E key must be 32 bytes");
    assert_eq!(invalid_e2e.code, NetworkErrorCode::InvalidArgument as i32);

    upsert_peer_with_policy(
        &state,
        UpsertPeerCommand {
            peer_id: "peer-a".into(),
            endpoint_address: "127.0.0.1:22".into(),
            identity_public_key: vec![1; 32],
            e2e_public_key: vec![2; 32],
        },
        network_protocol::E2eePolicy::Disabled,
    )
    .await
    .expect("valid peer configuration");
    let config = state.peers.read().await.get("peer-a").cloned().unwrap();
    assert_eq!(config.endpoint.unwrap().port(), 22);
    assert_eq!(config.e2ee_policy, network_protocol::E2eePolicy::Disabled);
    assert_eq!(state.trusted_peer_keys.read().await["peer-a"], [1; 32]);

    upsert_peer(
        &state,
        UpsertPeerCommand {
            peer_id: "peer-without-endpoint".into(),
            identity_public_key: vec![3; 32],
            e2e_public_key: vec![4; 32],
            ..Default::default()
        },
    )
    .await
    .expect("peer without a configured endpoint is valid");
    assert!(state
        .peers
        .read()
        .await
        .get("peer-without-endpoint")
        .is_some_and(|peer| peer.endpoint.is_none()));

    let empty_disconnect = disconnect_peer(&state, String::new())
        .await
        .expect_err("empty disconnect peer must fail");
    assert_eq!(
        empty_disconnect.code,
        NetworkErrorCode::InvalidArgument as i32
    );
    disconnect_peer(&state, "peer-a".into())
        .await
        .expect("configured peer can be explicitly disconnected");
}

#[tokio::test]
async fn direct_quic_connection_failures_map_to_typed_errors() {
    let endpoint = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("client bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create client endpoint")
    .endpoint;
    let identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-a".into(),
        [31; 32],
        [32; 32],
    ));
    let error = connect_direct(
        endpoint.clone(),
        "127.0.0.1:9".parse().unwrap(),
        identity,
        [33; 32],
        "peer-a".into(),
        "attempt".into(),
        Duration::from_millis(20),
    )
    .await
    .expect_err("unreachable QUIC candidate must fail");
    assert!(matches!(
        error.code,
        code if code == NetworkErrorCode::QuicError as i32
            || code == NetworkErrorCode::Timeout as i32
    ));
    endpoint.close(VarInt::from_u32(0), b"test complete");
}

#[tokio::test]
async fn direct_quic_authentication_failures_map_to_authentication_error() {
    let server = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("server bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create server endpoint");
    let server_address = server.endpoint.local_addr().expect("server address");
    let server_endpoint = server.endpoint;
    let server_identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-server".into(),
        [51; 32],
        [52; 32],
    ));
    let client_identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-client".into(),
        [53; 32],
        [54; 32],
    ));
    let expected_client_key = client_identity.public_identity_key().to_bytes();
    let server_task = tokio::spawn(async move {
        let connection = server_endpoint
            .accept()
            .await
            .expect("incoming QUIC connection")
            .await
            .expect("server QUIC connection");
        QuicPeerSession::new(connection, "device-client".into())
            .accept_handshake(&server_identity, expected_client_key)
            .await
    });
    let client = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("client bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create client endpoint");
    let error = connect_direct(
        client.endpoint.clone(),
        server_address,
        client_identity,
        [55; 32],
        "device-server".into(),
        "auth-failure".into(),
        Duration::from_secs(2),
    )
    .await
    .expect_err("a wrong pinned server key must fail authentication");
    assert_eq!(error.code, NetworkErrorCode::AuthenticationFailed as i32);
    server_task
        .await
        .expect("server task join")
        .expect("server should complete the challenge");
    client
        .endpoint
        .close(VarInt::from_u32(0), b"auth failure test complete");
}

#[tokio::test]
async fn stale_admissions_reject_direct_and_generic_route_attachment() {
    let state = new_test_state().await;
    let direct_admission = state
        .admit_authenticated_session("peer-direct", None, "remote-direct")
        .await
        .expect("direct admission");
    let direct_session = direct_admission.session_id;
    assert!(
        state
            .connection_sessions
            .retire_session("peer-direct", direct_session)
            .await
    );
    let (direct_endpoint, direct_connection) = quic_connection_pair().await;
    let direct_error = crate::connect::ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .attach_direct_route(
            "peer-direct",
            ConnectedRoute::Quic {
                connection: direct_connection,
                crypto: SessionCryptoMaterial {
                    root_key: [1; 32],
                    local_session_binding: direct_session.wire_key(),
                    remote_session_binding: "remote-direct".into(),
                    initiator: true,
                    e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Required,
                    path_security: crate::crypto_handshake::path_handshake::PathSecurity::E2ee,
                },
                admission: direct_admission,
            },
        )
        .await
        .expect_err("retired direct admission must not publish a route");
    assert_eq!(direct_error.code, NetworkErrorCode::NoRoute as i32);
    direct_endpoint.close(VarInt::from_u32(0), b"stale direct route test complete");

    let generic_admission = state
        .admit_authenticated_session("peer-generic", None, "remote-generic")
        .await
        .expect("generic admission");
    let generic_session = generic_admission.session_id;
    let (generic_connection, _server) = generic_connection_pair().await;
    let scope =
        started_generic_scope(&state, "peer-generic", generic_session, generic_connection).await;
    assert!(
        state
            .connection_sessions
            .retire_session("peer-generic", generic_session)
            .await
    );
    let generic_error = crate::connect::ConnectivityAttemptCoordinator::new(Arc::clone(&state))
        .attach_direct_route(
            "peer-generic",
            ConnectedRoute::Generic(AuthenticatedGenericRoute {
                scope,
                endpoint: "127.0.0.1:1".parse().expect("generic route endpoint"),
                crypto: SessionCryptoMaterial {
                    root_key: [2; 32],
                    local_session_binding: generic_session.wire_key(),
                    remote_session_binding: "remote-generic".into(),
                    initiator: true,
                    e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Required,
                    path_security: crate::crypto_handshake::path_handshake::PathSecurity::E2ee,
                },
                admission: generic_admission,
            }),
        )
        .await
        .expect_err("retired generic admission must not publish a route");
    assert_eq!(generic_error.code, NetworkErrorCode::NoRoute as i32);
    state.task_supervisor.shutdown().await;
}

#[tokio::test]
async fn admitted_crypto_install_skips_identity_only_and_installs_fresh_e2ee() {
    let state = new_test_state().await;
    let identity_only_admission = state
        .admit_authenticated_session("peer-a", None, "identity-only")
        .await
        .expect("identity-only admission");
    let identity_only = SessionCryptoMaterial {
        root_key: [0; 32],
        local_session_binding: identity_only_admission.session_id.wire_key(),
        remote_session_binding: "identity-only".into(),
        initiator: true,
        e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Disabled,
        path_security: crate::crypto_handshake::path_handshake::PathSecurity::IdentityOnly,
    };
    install_admitted_crypto(&state, "peer-a", &identity_only_admission, &identity_only)
        .await
        .expect("identity-only admission must not install application keys");

    let e2ee_admission = state
        .admit_authenticated_session("peer-b", None, "stale")
        .await
        .expect("E2EE admission");
    let e2ee = SessionCryptoMaterial {
        root_key: [56; 32],
        local_session_binding: e2ee_admission.session_id.wire_key(),
        remote_session_binding: "stale".into(),
        initiator: true,
        e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Required,
        path_security: crate::crypto_handshake::path_handshake::PathSecurity::E2ee,
    };
    install_admitted_crypto(&state, "peer-b", &e2ee_admission, &e2ee)
        .await
        .expect("fresh E2EE material should be installed for the admitted session");
}

#[tokio::test]
async fn admitted_crypto_install_failure_retires_the_stale_session() {
    let state = new_test_state().await;
    let admission = state
        .admit_authenticated_session("peer-install-failure", None, "remote")
        .await
        .expect("admit session before invalidating it");
    assert!(
        state
            .connection_sessions
            .retire_session("peer-install-failure", admission.session_id)
            .await
    );
    let material = SessionCryptoMaterial {
        root_key: [57; 32],
        local_session_binding: admission.session_id.wire_key(),
        remote_session_binding: "remote".into(),
        initiator: true,
        e2ee_policy: crate::crypto_handshake::path_handshake::E2eePolicy::Required,
        path_security: crate::crypto_handshake::path_handshake::PathSecurity::E2ee,
    };
    let error = install_admitted_crypto(&state, "peer-install-failure", &admission, &material)
        .await
        .expect_err("stale admission must not install application crypto");
    assert!(error.to_string().contains("admission is stale"));
    assert!(state
        .connection_sessions
        .current_session_id("peer-install-failure")
        .await
        .is_none());
}

#[tokio::test]
async fn direct_and_generic_candidate_races_fail_closed_on_empty_snapshots() {
    let endpoint = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("client bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create client endpoint")
    .endpoint;
    let identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-a".into(),
        [41; 32],
        [42; 32],
    ));
    let state = new_test_state().await;
    let (updates_tx, updates) = watch::channel(None);
    drop(updates_tx);
    let direct_error = match connect_direct_candidates_with_crypto(
        endpoint.clone(),
        Vec::new(),
        Arc::clone(&identity),
        [43; 32],
        "peer-a".into(),
        "attempt".into(),
        Instant::now() + Duration::from_secs(1),
        "session".into(),
        Arc::clone(&state),
        None,
        DEFAULT_CONNECTION_CAPABILITY,
        updates,
    )
    .await
    {
        Ok(_) => panic!("empty QUIC candidate snapshot unexpectedly succeeded"),
        Err(error) => error,
    };
    assert_eq!(direct_error.code, NetworkErrorCode::NoRoute as i32);

    let (updates_tx, updates) = watch::channel(None);
    drop(updates_tx);
    let generic_error = match OutboundGenericConnector::connect_generic_candidates(
        Vec::new(),
        identity,
        [44; 32],
        "peer-a".into(),
        "session".into(),
        state,
        SessionId::new(),
        DEFAULT_CONNECTION_CAPABILITY,
        true,
        Instant::now(),
        updates,
    )
    .await
    {
        Ok(_) => panic!("empty generic candidate snapshot unexpectedly succeeded"),
        Err(error) => error,
    };
    assert_eq!(generic_error.code, NetworkErrorCode::NoRoute as i32);
    endpoint.close(VarInt::from_u32(0), b"test complete");
}

#[tokio::test]
async fn direct_route_zero_window_skips_probe_before_expiry() {
    // A cancelled/expired Direct budget must not start either QUIC or generic
    // probing; the empty candidate result remains a typed NoRoute failure.
    let endpoint = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("client bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create client endpoint")
    .endpoint;
    let state = new_test_state().await;
    let identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-a".into(),
        [45; 32],
        [46; 32],
    ));
    let (candidate_update_tx, candidate_updates) = watch::channel(None);
    drop(candidate_update_tx);
    let result = connect_direct_or_generic(DirectRouteAttempt {
        state,
        endpoint: endpoint.clone(),
        candidates: Vec::new(),
        identity,
        expected_peer_public_key: [47; 32],
        peer_id: "peer-a".into(),
        session_binding: "session".into(),
        session_id: SessionId::new(),
        attempt_id: "zero-window".into(),
        connect_window: Duration::ZERO,
        required_capabilities: DEFAULT_CONNECTION_CAPABILITY,
        allow_websocket: true,
        candidate_updates,
    })
    .await;
    let error = match result {
        Ok(_) => panic!("an expired Direct budget unexpectedly produced a route"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    endpoint.close(VarInt::from_u32(0), b"test complete");
}

#[tokio::test]
async fn responder_direct_rejects_empty_advertised_candidates() {
    // An inbound ConnectivityOffer with no usable candidates must fail closed
    // before a responder route or Session admission is created.
    let endpoint = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("responder bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create responder endpoint")
    .endpoint;
    let state = new_test_state().await;
    let identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-responder".into(),
        [48; 32],
        [49; 32],
    ));
    let result = connect_responder_direct(
        endpoint.clone(),
        Vec::new(),
        identity,
        [50; 32],
        "peer-a".into(),
        "empty-offer".into(),
        "session".into(),
        state,
        Duration::ZERO,
    )
    .await;
    let error = match result {
        Ok(_) => panic!("empty responder offer unexpectedly produced a route"),
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    endpoint.close(VarInt::from_u32(0), b"test complete");
}

#[tokio::test]
async fn candidate_race_empty_and_expired_windows_fail_before_network_work() {
    let state = new_test_state().await;
    let identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-a".into(),
        [51; 32],
        [52; 32],
    ));
    let endpoint = QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("client bind address"),
        Arc::new(PathManager::new()),
    )
    .expect("create client endpoint")
    .endpoint;
    let (direct_tx, direct_updates) = watch::channel(None);
    drop(direct_tx);
    let direct_result = connect_direct_candidates_with_crypto(
        endpoint.clone(),
        Vec::new(),
        Arc::clone(&identity),
        [0u8; 32],
        "peer-a".into(),
        "empty-direct".into(),
        Instant::now() + Duration::from_secs(1),
        "session".into(),
        Arc::clone(&state),
        None,
        DEFAULT_CONNECTION_CAPABILITY,
        direct_updates,
    )
    .await;
    let direct_error = match direct_result {
        Ok(_) => panic!("empty candidate set unexpectedly connected"),
        Err(error) => error,
    };
    assert_eq!(direct_error.code, NetworkErrorCode::NoRoute as i32);

    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "expired-candidate".into(),
    );
    let (expired_tx, expired_updates) = watch::channel(None);
    drop(expired_tx);
    let expired_result = connect_direct_candidates_with_crypto(
        endpoint.clone(),
        vec![candidate],
        identity,
        [0u8; 32],
        "peer-a".into(),
        "expired-direct".into(),
        Instant::now(),
        "session".into(),
        state,
        None,
        DEFAULT_CONNECTION_CAPABILITY,
        expired_updates,
    )
    .await;
    let expired_error = match expired_result {
        Ok(_) => panic!("expired candidate window unexpectedly connected"),
        Err(error) => error,
    };
    assert_eq!(expired_error.code, NetworkErrorCode::NoRoute as i32);
    endpoint.close(VarInt::from_u32(0), b"candidate race test complete");
}

#[tokio::test]
async fn generic_candidate_race_empty_and_expired_windows_fail_closed() {
    let state = new_test_state().await;
    let identity = Arc::new(DeviceIdentity::from_private_keys(
        "device-a".into(),
        [53; 32],
        [54; 32],
    ));
    let (empty_tx, empty_updates) = watch::channel(None);
    drop(empty_tx);
    let empty_result = OutboundGenericConnector::connect_generic_candidates(
        Vec::new(),
        Arc::clone(&identity),
        [0u8; 32],
        "peer-a".into(),
        "session".into(),
        Arc::clone(&state),
        SessionId::new(),
        DEFAULT_CONNECTION_CAPABILITY,
        false,
        Instant::now() + Duration::from_secs(1),
        empty_updates,
    )
    .await;
    let empty_error = match empty_result {
        Ok(_) => panic!("empty generic candidates unexpectedly connected"),
        Err(error) => error,
    };
    assert_eq!(empty_error.code, NetworkErrorCode::NoRoute as i32);

    let candidate = Candidate::new(
        "127.0.0.1:9".parse().expect("candidate endpoint"),
        CandidateKind::Lan,
        "expired-generic".into(),
    );
    let (expired_tx, expired_updates) = watch::channel(None);
    drop(expired_tx);
    let expired_result = OutboundGenericConnector::connect_generic_candidates(
        vec![candidate],
        identity,
        [0u8; 32],
        "peer-a".into(),
        "session".into(),
        state,
        SessionId::new(),
        DEFAULT_CONNECTION_CAPABILITY,
        false,
        Instant::now(),
        expired_updates,
    )
    .await;
    let expired_error = match expired_result {
        Ok(_) => panic!("expired generic window unexpectedly connected"),
        Err(error) => error,
    };
    assert_eq!(expired_error.code, NetworkErrorCode::NoRoute as i32);
}

#[tokio::test]
async fn generic_tcp_candidate_releases_a_route_that_lacks_requested_datagrams() {
    let state = new_test_state().await;
    let peer_id = "generic-capability-peer";
    let local_peer_id = "generic-capability-local";
    let local_identity = Arc::new(DeviceIdentity::from_private_keys(
        local_peer_id.into(),
        [41u8; 32],
        [51u8; 32],
    ));
    let expected_remote = DeviceIdentity::from_private_keys(peer_id.into(), [42u8; 32], [52u8; 32]);
    let session_id = started_session(&state, peer_id).await;
    let (endpoint, release_tx, responder_task) =
        spawn_tcp_generic_responder(peer_id, local_peer_id).await;
    let result = tokio::time::timeout(
        Duration::from_secs(2),
        OutboundGenericConnector::connect_generic_candidate(
            endpoint,
            local_identity,
            expected_remote.public_identity_key().to_bytes(),
            peer_id.into(),
            session_id.wire_key(),
            Arc::clone(&state),
            session_id,
            crate::connect::CAPABILITY_UNRELIABLE_DATAGRAM,
            false,
            Duration::from_secs(1),
        ),
    )
    .await
    .expect("capability mismatch should finish within the candidate window");
    let error = match result {
        Ok(route) => {
            route.scope.close().await;
            panic!("TCP must not claim an unreliable datagram capability")
        }
        Err(error) => error,
    };
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    let _ = release_tx.send(());
    responder_task
        .await
        .expect("capability responder should exit");
    state.cancel_session_tasks(peer_id, session_id).await;
}

#[tokio::test]
async fn explicit_runtime_port_conflict_fails_before_claiming_runtime_state() {
    let state = new_test_state().await;
    let blocker = std::net::TcpListener::bind("127.0.0.1:0").expect("bind TCP blocker");
    let address = blocker.local_addr().expect("TCP blocker address");
    let error = configure_runtime(
        Arc::clone(&state),
        network_protocol::ConfigureRuntimeCommand {
            device_id: "device-conflict".into(),
            identity_private_key: vec![1; 32],
            e2e_private_key: vec![2; 32],
            listen_address: address.to_string(),
            receive_directory: std::env::temp_dir()
                .join("ssh-mobile-conflict-receive")
                .to_string_lossy()
                .into_owned(),
        },
    )
    .await
    .expect_err("an occupied TCP fallback port must fail closed");
    assert_eq!(error.code, NetworkErrorCode::IoError as i32);
    assert!(state.lifecycle.endpoint.read().await.is_none());
}
