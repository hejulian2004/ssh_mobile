/// Peer SSH Server Service (design §21 option B): a stream whose service hint
/// is `ssh` is bridged by the peer's native runtime to a local TCP socket.
/// Tested against a local echo server instead of a real sshd.
#[test]
fn ssh_gateway_bridges_stream_to_a_local_tcp_echo_server() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let test_root =
        std::env::temp_dir().join(format!("ssh-mobile-stream-gw-{}", rand::random::<u64>()));
    fs::create_dir_all(&test_root).expect("test root");
    let identity_seed_a = [61u8; 32];
    let identity_seed_b = [62u8; 32];
    let public_key_a =
        DeviceIdentity::from_private_keys("stream-gw-a".into(), identity_seed_a, [71u8; 32])
            .public_identity_key()
            .to_bytes();
    let public_key_b =
        DeviceIdentity::from_private_keys("stream-gw-b".into(), identity_seed_b, [72u8; 32])
            .public_identity_key()
            .to_bytes();
    let address_a = configure_runtime_for_test(
        &runtime_a,
        "stream-gw-a",
        identity_seed_a,
        [71u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "stream-gw-b",
        identity_seed_b,
        [72u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    connect_runtimes_for_stream_test(
        &runtime_a,
        &runtime_b,
        &StreamTestPeers {
            device_a: "stream-gw-a".into(),
            device_b: "stream-gw-b".into(),
            address_a,
            address_b,
            public_key_a,
            public_key_b,
            seed_a: [71u8; 32],
            seed_b: [72u8; 32],
        },
        RouteTransport::Quic,
    );

    // Local TCP echo server on runtime B's worker threads; the peer gateway
    // bridges to it. Tested against an echo server instead of a real sshd.
    let (echo_port, echo_task) = runtime_b.handle().block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind echo server");
        let port = listener.local_addr().expect("echo address").port();
        let task = tokio::spawn(async move {
            loop {
                let (socket, _) = match listener.accept().await {
                    Ok(connection) => connection,
                    Err(_) => break,
                };
                tokio::spawn(async move {
                    let (mut read_half, mut write_half) = socket.into_split();
                    let _ = tokio::io::copy(&mut read_half, &mut write_half).await;
                });
            }
        });
        (port, task)
    });

    // Point the peer's SSH gateway at the echo server.
    let state_b = runtime_b
        .state
        .lock()
        .expect("runtime B state lock")
        .clone()
        .expect("runtime B state");
    runtime_b.handle().block_on(async {
        state_b
            .stream_gateway_port
            .store(echo_port, std::sync::atomic::Ordering::Release);
    });

    const STREAM_ID: u16 = 4;
    send_and_expect_accepted(
        &runtime_a,
        ssh_open_command(
            "stream-gw-a",
            "stream-gw-b",
            STREAM_ID,
            crate::stream::STREAM_SERVICE_SSH,
        ),
    );

    // The bridge pumps A -> gateway -> echo server -> gateway -> A.
    let payload = b"bridge-round-trip";
    send_and_expect_accepted(
        &runtime_a,
        ssh_data_command("stream-gw-a", "stream-gw-b", STREAM_ID, payload),
    );
    let echoed = poll_until(&runtime_a, Duration::from_secs(10), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::SshStreamDataReceived(recv))
                if recv.peer_id == "stream-gw-b"
                    && stream_handle_matches(recv.handle.as_ref(), "stream-gw-a", STREAM_ID)
                    && recv.data == payload
        )
    });
    assert!(
        echoed.is_some(),
        "echoed bytes never returned to the initiator"
    );

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    echo_task.abort();
    fs::remove_dir_all(test_root).ok();
}

pub(crate) fn configure_runtime_for_test(
    runtime: &NetworkRuntime,
    device_id: &str,
    identity_seed: [u8; 32],
    e2e_seed: [u8; 32],
    address: SocketAddr,
    receive_directory: std::path::PathBuf,
) -> SocketAddr {
    // Fixture runtimes can reuse a previous test's stack address. Their event
    // backlog belongs to this configured instance, not that old address.
    TEST_EVENT_BACKLOG
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .expect("test event backlog lock")
        .remove(&(runtime as *const NetworkRuntime as usize));
    send_and_expect_accepted(
        runtime,
        NetworkCommand {
            command_id: format!("configure-{device_id}"),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConfigureRuntime(
                ConfigureRuntimeCommand {
                    device_id: device_id.into(),
                    identity_private_key: identity_seed.to_vec(),
                    e2e_private_key: e2e_seed.to_vec(),
                    listen_address: address.to_string(),
                    receive_directory: receive_directory.to_string_lossy().to_string(),
                },
            )),
        },
    );
    let port = runtime
        .bound_local_port()
        .expect("runtime bound an actual UDP port");
    SocketAddr::new(address.ip(), port)
}

#[test]
fn configuring_a_fresh_runtime_drops_backlog_from_a_previous_stack_instance() {
    let runtime = NetworkRuntime::new().unwrap();
    runtime.start().unwrap();
    let runtime_key = &runtime as *const NetworkRuntime as usize;
    TEST_EVENT_BACKLOG
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap()
        .insert(
            runtime_key,
            VecDeque::from([network_protocol::NetworkEvent {
                event_id: "previous-runtime".into(),
                ..Default::default()
            }]),
        );
    let root =
        std::env::temp_dir().join(format!("fresh-runtime-backlog-{}", rand::random::<u64>()));
    configure_runtime_for_test(
        &runtime,
        "fresh-runtime",
        [71; 32],
        [72; 32],
        "127.0.0.1:0".parse().unwrap(),
        root.clone(),
    );
    assert!(
        poll_until(&runtime, Duration::from_millis(100), |event| event.event_id
            == "previous-runtime")
        .is_none()
    );
    runtime.stop().unwrap();
    fs::remove_dir_all(root).ok();
}

/// 为当前 Network Protocol V2 契约创建显式对端注册命令。
fn upsert_command(
    command_id: &str,
    peer_id: &str,
    endpoint: SocketAddr,
    public_key: [u8; 32],
    e2e_private_key: [u8; 32],
) -> NetworkCommand {
    upsert_command_with_routes(
        command_id,
        peer_id,
        endpoint,
        public_key,
        e2e_private_key,
        true,
        true,
    )
}

pub(crate) fn upsert_command_with_routes(
    command_id: &str,
    peer_id: &str,
    endpoint: SocketAddr,
    public_key: [u8; 32],
    e2e_private_key: [u8; 32],
    allow_direct: bool,
    allow_relay: bool,
) -> NetworkCommand {
    let e2e_public_key =
        DeviceIdentity::from_private_keys(peer_id.to_string(), [1u8; 32], e2e_private_key)
            .public_e2e_key()
            .to_bytes();
    NetworkCommand {
        command_id: command_id.into(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_command::Payload::UpsertPeerV2(
            network_protocol::UpsertPeerV2Command {
                config: Some(network_protocol::PeerConfig {
                    peer_id: peer_id.into(),
                    endpoint_address: endpoint.to_string(),
                    identity_public_key: public_key.to_vec(),
                    e2e_public_key: e2e_public_key.to_vec(),
                    e2ee_policy: network_protocol::E2eePolicy::Required as i32,
                    allow_direct,
                    allow_relay,
                }),
            },
        )),
    }
}

/// 将命令入队，并等待其异步终态成功结果。
///
/// 每个 NetworkRuntime 启动一个多线程 tokio worker。全套测试并行执行真实
/// QUIC/UDP/TCP/WebSocket 网络 I/O 时可能重度超订 CPU，命令结果在加载下的
/// 真实延迟可远超 10s；用 30s 作为命令结果截止期，避免加载下偶发误报。
pub(crate) fn send_and_expect_accepted(runtime: &NetworkRuntime, command: NetworkCommand) {
    let command_id = command.command_id.clone();
    runtime.send_command(command).expect("queue command");
    let result = poll_until(runtime, Duration::from_secs(30), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::CommandResultV2(result))
                if result.command_id == command_id
        )
    })
    .unwrap_or_else(|| panic!("command {command_id} timed out waiting for command result"));
    match result.payload {
        Some(network_event::Payload::CommandResultV2(result))
            if result.state == CommandResultState::Succeeded as i32 => {}
        Some(network_event::Payload::CommandResultV2(result)) => {
            let error = result
                .error
                .expect("failed command result must carry an error");
            panic!(
                "command {command_id} rejected: code={} message={} operation={} peer_id={}",
                error.code, error.message, error.operation, error.peer_id
            )
        }
        other => panic!("command {command_id} returned unexpected result: {other:?}"),
    }
}

/// 轮询原生事件，直到匹配谓词或超时。
static TEST_EVENT_BACKLOG: OnceLock<
    Mutex<HashMap<usize, VecDeque<network_protocol::NetworkEvent>>>,
> = OnceLock::new();

fn poll_until(
    runtime: &NetworkRuntime,
    timeout: Duration,
    predicate: impl Fn(&network_protocol::NetworkEvent) -> bool,
) -> Option<network_protocol::NetworkEvent> {
    let deadline = Instant::now() + timeout;
    let runtime_key = runtime as *const NetworkRuntime as usize;
    let mut deferred = VecDeque::new();
    while Instant::now() < deadline {
        let event = TEST_EVENT_BACKLOG
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .expect("test event backlog lock")
            .get_mut(&runtime_key)
            .and_then(VecDeque::pop_front)
            .or_else(|| runtime.poll_event(100));
        let Some(event) = event else {
            continue;
        };
        if predicate(&event) {
            let mut backlog = TEST_EVENT_BACKLOG
                .get_or_init(|| Mutex::new(HashMap::new()))
                .lock()
                .expect("test event backlog lock");
            let queue = backlog.entry(runtime_key).or_default();
            while let Some(event) = deferred.pop_back() {
                queue.push_front(event);
            }
            return Some(event);
        }
        deferred.push_back(event);
    }
    let mut backlog = TEST_EVENT_BACKLOG
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .expect("test event backlog lock");
    let queue = backlog.entry(runtime_key).or_default();
    while let Some(event) = deferred.pop_back() {
        queue.push_front(event);
    }
    None
}

pub(crate) fn wait_for_session_connected(
    runtime: &NetworkRuntime,
    peer_id: &str,
    timeout: Duration,
) -> bool {
    let state = runtime
        .state
        .lock()
        .expect("runtime state lock")
        .clone()
        .expect("runtime state");
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if runtime.handle().block_on(state.path_is_connected(peer_id)) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    false
}
