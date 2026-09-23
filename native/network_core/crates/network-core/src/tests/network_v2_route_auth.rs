use super::*;

fn peer_config(
    peer_id: &str,
    allow_direct: bool,
    allow_relay: bool,
) -> network_protocol::PeerConfig {
    network_protocol::PeerConfig {
        peer_id: peer_id.to_string(),
        endpoint_address: String::new(),
        identity_public_key: vec![0x11; 32],
        e2e_public_key: vec![0x22; 32],
        e2ee_policy: network_protocol::E2eePolicy::Required as i32,
        allow_direct,
        allow_relay,
    }
}

fn state() -> Arc<crate::runtime::RuntimeState> {
    Arc::new(crate::runtime::RuntimeState::new(
        tokio::sync::mpsc::unbounded_channel().0,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ))
}

async fn dispatch_peer(
    state: Arc<crate::runtime::RuntimeState>,
    command_id: &str,
    config: network_protocol::PeerConfig,
) -> Result<(), network_protocol::NetworkError> {
    crate::commands::dispatch_command(
        NetworkCommand {
            command_id: command_id.to_string(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::UpsertPeerV2(
                network_protocol::UpsertPeerV2Command {
                    config: Some(config),
                },
            )),
        },
        state,
    )
    .await
}

async fn configured_connect_state(
    peer_id: &str,
    authorization: crate::runtime::PeerRouteAuthorization,
) -> Arc<crate::runtime::RuntimeState> {
    let runtime = state();
    let endpoint = network_quic::QuicEndpointManager::new(
        "127.0.0.1:0".parse().expect("endpoint address"),
        Arc::new(network_nat::PathManager::new()),
    )
    .expect("test endpoint");
    *runtime.lifecycle.endpoint.write().await = Some(endpoint.endpoint);
    *runtime.lifecycle.identity.write().await = Some(Arc::new(
        network_identity::DeviceIdentity::from_private_keys(
            "device-a".to_string(),
            [0x31; 32],
            [0x32; 32],
        ),
    ));
    runtime.peers.write().await.insert(
        peer_id.to_string(),
        crate::runtime::PeerConfig {
            endpoint: None,
            identity_public_key: [0x41; 32],
            e2e_public_key: [0x42; 32],
            e2ee_policy: network_protocol::E2eePolicy::Required,
        },
    );
    runtime.allow_routes_for_test(peer_id).await;
    runtime
        .peer_route_authorizations
        .write()
        .await
        .insert(peer_id.to_string(), authorization);
    runtime
}

#[tokio::test]
async fn upsert_v2_requires_a_direct_route_and_records_authorization() {
    let runtime = state();

    let relay_only = dispatch_peer(
        Arc::clone(&runtime),
        "relay-only",
        peer_config("relay-only", false, true),
    )
    .await
    .expect_err("relay-only peers must be rejected");
    assert_eq!(relay_only.code, NetworkErrorCode::InvalidArgument as i32);

    let no_route = dispatch_peer(
        Arc::clone(&runtime),
        "no-route",
        peer_config("no-route", false, false),
    )
    .await
    .expect_err("peers without an authorized route must be rejected");
    assert_eq!(no_route.code, NetworkErrorCode::InvalidArgument as i32);

    dispatch_peer(
        Arc::clone(&runtime),
        "direct-only",
        peer_config("direct-only", true, false),
    )
    .await
    .expect("direct route should be accepted");

    let authorization = runtime
        .peer_route_authorizations
        .read()
        .await
        .get("direct-only")
        .copied()
        .expect("authorization record");
    assert!(authorization.direct);
    assert!(!authorization.relay);
}

#[tokio::test]
async fn relay_authorization_can_be_granted_then_revoked_without_changing_identity() {
    let runtime = state();
    dispatch_peer(
        Arc::clone(&runtime),
        "grant-relay",
        peer_config("grant-relay", true, false),
    )
    .await
    .expect("initial direct registration");

    dispatch_peer(
        Arc::clone(&runtime),
        "grant-relay-update",
        peer_config("grant-relay", true, true),
    )
    .await
    .expect("relay authorization grant");
    assert_eq!(
        runtime
            .peers
            .read()
            .await
            .get("grant-relay")
            .expect("peer config")
            .identity_public_key,
        [0x11; 32]
    );
    assert!(
        runtime
            .peer_route_authorizations
            .read()
            .await
            .get("grant-relay")
            .expect("authorization")
            .relay
    );

    dispatch_peer(
        Arc::clone(&runtime),
        "revoke-relay",
        peer_config("grant-relay", true, false),
    )
    .await
    .expect("relay authorization revoke");
    let authorization = runtime
        .peer_route_authorizations
        .read()
        .await
        .get("grant-relay")
        .copied()
        .expect("authorization record");
    assert!(authorization.direct);
    assert!(!authorization.relay);
}

#[tokio::test]
async fn legacy_upsert_and_remove_peer_clear_the_v2_registration_boundary() {
    let runtime = state();
    let legacy = crate::commands::dispatch_command(
        NetworkCommand {
            command_id: "legacy-upsert".to_string(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::UpsertPeer(
                network_protocol::UpsertPeerCommand {
                    peer_id: "legacy-peer".to_string(),
                    ..Default::default()
                },
            )),
        },
        Arc::clone(&runtime),
    )
    .await
    .expect_err("legacy peer registration must be rejected");
    assert_eq!(legacy.code, NetworkErrorCode::InvalidArgument as i32);

    dispatch_peer(
        Arc::clone(&runtime),
        "register-for-remove",
        peer_config("remove-me", true, true),
    )
    .await
    .expect("peer registration");
    crate::commands::dispatch_command(
        NetworkCommand {
            command_id: "remove-v2".to_string(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::RemovePeer(
                network_protocol::RemovePeerCommand {
                    peer_id: "remove-me".to_string(),
                },
            )),
        },
        Arc::clone(&runtime),
    )
    .await
    .expect("remove peer");

    assert!(!runtime.peers.read().await.contains_key("remove-me"));
    assert!(!runtime
        .peer_route_authorizations
        .read()
        .await
        .contains_key("remove-me"));
    assert!(!runtime
        .trusted_peer_keys
        .read()
        .await
        .contains_key("remove-me"));
}

#[tokio::test]
async fn connect_rejects_a_revoked_direct_route_before_control_plane_work() {
    let runtime = configured_connect_state(
        "direct-revoked",
        crate::runtime::PeerRouteAuthorization {
            direct: false,
            relay: true,
        },
    )
    .await;

    let error = crate::connect::ConnectivityAttemptCoordinator::new(runtime)
        .connect_with_class(
            "direct-revoked",
            network_protocol::CommunicationClass::ReliableMessage,
        )
        .await
        .expect_err("revoked Direct route must not start a connectivity attempt");
    assert_eq!(error.code, NetworkErrorCode::NoRoute as i32);
    assert!(error.message.contains("direct route is not authorized"));
}

#[test]
fn path_manager_filters_unauthorized_topologies_before_lease() {
    let peer = crate::connect::PeerId::new("path-policy-peer").expect("peer id");
    let registry = Arc::new(crate::connect::PathRegistry::new());
    let mut manager = crate::connect::PeerPathManager::new(peer, Arc::clone(&registry));
    manager
        .publish_ready(crate::connection::ConnectionProfile::new(
            crate::connection::Route::direct(crate::connection::RouteTransport::Tcp),
        ))
        .expect("Direct path");
    manager
        .publish_ready(crate::connection::ConnectionProfile::new(
            crate::connection::Route::relay(crate::connection::RouteTransport::WebSocket),
        ))
        .expect("Relay path");

    assert_eq!(
        manager
            .select_with_authorization(crate::connect::CAPABILITY_RELIABLE_MESSAGE, false, true,),
        Some(crate::connect::PathSelection::Relay)
    );
    let (selection, lease) = manager
        .acquire_with_authorization(crate::connect::CAPABILITY_RELIABLE_MESSAGE, false, true)
        .expect("authorized Relay lease");
    assert_eq!(selection, crate::connect::PathSelection::Relay);
    lease.release();
    assert!(manager
        .acquire_with_authorization(crate::connect::CAPABILITY_RELIABLE_MESSAGE, false, false)
        .is_err());
}
