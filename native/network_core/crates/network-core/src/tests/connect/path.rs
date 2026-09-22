use super::*;
use crate::connect::{
    CAPABILITY_RELIABLE_MESSAGE, CAPABILITY_RELIABLE_STREAM, CAPABILITY_UNRELIABLE_DATAGRAM,
};
use crate::connection::{Route, RouteTransport};

fn test_peer() -> PeerId {
    PeerId::new("peer-a").expect("peer id")
}

fn profile(topology: PathKind, transport: RouteTransport) -> ConnectionProfile {
    let route = match topology {
        PathKind::Direct => Route::direct(transport),
        PathKind::Relay => Route::relay(transport),
    };
    ConnectionProfile::new(route)
}

fn recording_carrier(closes: &Arc<Mutex<Vec<PathCloseReason>>>) -> Box<dyn PathCarrier> {
    let closes = Arc::clone(closes);
    callback_path_carrier(move |reason| {
        closes.lock().expect("close log lock").push(reason);
    })
}

#[test]
fn physical_path_is_sole_carrier_owner() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    assert_eq!(manager.peer_id(), &test_peer());
    let handle = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&closes),
        )
        .expect("direct path");
    let copied_handle = handle.clone();
    let lease = registry.acquire(&copied_handle).expect("path lease");

    assert_eq!(lease.handle(), &handle);
    assert_eq!(lease.lease_count(), 1);
    assert!(lease.path.has_carrier());
    assert!(registry.acquire(&handle).is_ok());

    manager.normal_drain();
    assert!(lease.is_active(), "normal drain waits for existing leases");
    assert!(closes.lock().expect("close log lock").is_empty());
    assert!(matches!(
        registry.acquire(&handle),
        Err(CoreNetworkError::StaleAttempt)
    ));

    lease.release();
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[tokio::test]
async fn metadata_only_path_exposes_no_transport_io() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::Tcp))
        .expect("metadata-only path");
    let lease = registry.acquire(&handle).expect("path lease");

    assert!(lease.connection().is_none());
    assert!(lease.stream_carrier().is_none());
    assert!(lease.relay_data().is_none());
    let error = lease
        .send_channel_frame("", GenericFrameKind::DataMessage, b"payload")
        .await
        .expect_err("metadata-only path cannot send");
    assert!(error.to_string().contains("physical path I/O unavailable"));

    manager.hard_close();
}

#[test]
fn path_projection_is_non_owning_and_upgrades_only_to_a_lease() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&closes),
        )
        .expect("direct path");
    let projection = manager.projection(&handle).expect("path projection");

    assert_eq!(projection.handle(), &handle);
    assert!(projection.is_alive());
    let lease = projection.acquire().expect("lease from projection");
    manager.normal_drain();
    assert!(
        projection.is_alive(),
        "active lease keeps the carrier alive"
    );
    drop(lease);
    assert!(
        !projection.is_alive(),
        "weak projection cannot keep the path alive"
    );
    assert!(matches!(
        projection.acquire(),
        Err(CoreNetworkError::StaleAttempt)
    ));
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[tokio::test]
async fn path_lease_exposes_owner_io_without_a_route_owner_clone() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_route(ActiveRoute::relay(None))
        .expect("relay path");
    let projection = manager.projection(&handle).expect("path projection");
    let lease = projection.acquire().expect("path lease");

    assert!(lease.connection().is_none());
    assert!(matches!(
        lease.stream_carrier(),
        Some(StreamCarrier::Relay(None))
    ));
    assert!(lease.relay_data().is_none());
    assert!(lease
        .send_channel_frame("", GenericFrameKind::DataMessage, b"payload")
        .await
        .is_err());
}

#[tokio::test]
async fn relay_path_routes_all_business_frame_kinds_through_its_data_client() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let data = Arc::new(
        RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("valid Relay data client"),
    );
    let handle = manager
        .publish_ready_with_route(ActiveRoute::relay(Some(Arc::clone(&data))))
        .expect("Relay path");
    let lease = manager
        .projection(&handle)
        .expect("path projection")
        .acquire()
        .expect("path lease");

    for kind in [
        GenericFrameKind::DataMessage,
        GenericFrameKind::DeliveryAck,
        GenericFrameKind::StreamOpen,
    ] {
        assert!(lease
            .send_channel_frame("token", kind, b"payload")
            .await
            .is_err());
    }
    assert!(lease
        .relay_data()
        .is_some_and(|current| Arc::ptr_eq(&current, &data)));
    drop(lease);
    manager.hard_close();
}

#[test]
fn direct_and_relay_can_coexist() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let relay = manager
        .publish_ready(profile(PathKind::Relay, RouteTransport::WebSocket))
        .expect("relay path");
    let direct = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::Quic))
        .expect("direct path");

    assert_eq!(manager.direct_state(), DirectPathState::Ready);
    assert_eq!(manager.relay_state(), RelayPathState::Ready);
    assert_eq!(manager.direct_ready(), Some(&direct));
    assert_eq!(manager.relay_ready(), Some(&relay));
    assert_eq!(
        manager.select(CAPABILITY_RELIABLE_MESSAGE),
        Some(PathSelection::Direct)
    );

    let (selection, direct_lease) = manager
        .acquire(CAPABILITY_RELIABLE_STREAM)
        .expect("direct stream lease");
    assert_eq!(selection, PathSelection::Direct);
    assert_eq!(direct_lease.handle(), &direct);
    drop(direct_lease);
    assert!(registry.acquire(&relay).is_ok());
}

#[test]
fn ready_direct_and_probe_can_coexist() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let direct = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::WebSocket))
        .expect("direct path");

    manager
        .ensure_direct_probe(7, CAPABILITY_RELIABLE_STREAM, Duration::from_secs(4))
        .expect("direct probe");
    assert_eq!(manager.direct_state(), DirectPathState::Ready);
    assert!(manager.direct_probe().is_some());
    assert_eq!(
        manager.select(CAPABILITY_RELIABLE_MESSAGE),
        Some(PathSelection::Direct)
    );

    let (selection, lease) = manager
        .acquire(CAPABILITY_RELIABLE_MESSAGE)
        .expect("ready direct remains usable during probe");
    assert_eq!(selection, PathSelection::Direct);
    assert_eq!(lease.handle(), &direct);
    drop(lease);
    assert!(manager.finish_direct_probe(7));
    assert_eq!(manager.direct_state(), DirectPathState::Ready);
}

#[test]
fn normal_retire_waits_for_active_lease() {
    let registry = Arc::new(PathRegistry::new());
    let direct_closes = Arc::new(Mutex::new(Vec::new()));
    let relay_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let direct = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&direct_closes),
        )
        .expect("direct path");
    let relay = manager
        .publish_ready_with_carrier(
            profile(PathKind::Relay, RouteTransport::WebSocket),
            recording_carrier(&relay_closes),
        )
        .expect("relay path");
    let direct_lease = registry.acquire(&direct).expect("direct lease");

    manager.normal_drain();
    assert_eq!(manager.direct_state(), DirectPathState::None);
    assert_eq!(manager.relay_state(), RelayPathState::None);
    assert!(direct_lease.is_active());
    assert!(direct_closes.lock().expect("close log lock").is_empty());
    assert_eq!(
        relay_closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
    assert!(matches!(
        registry.acquire(&relay),
        Err(CoreNetworkError::StaleAttempt)
    ));

    drop(direct_lease);
    assert_eq!(
        direct_closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[test]
fn hard_close_revokes_active_lease() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&closes),
        )
        .expect("direct path");
    let lease = registry.acquire(&handle).expect("lease");

    manager.security_failure();
    assert!(!lease.is_active());
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::SecurityFailure]
    );
    assert!(matches!(
        registry.acquire(&handle),
        Err(CoreNetworkError::StaleAttempt)
    ));
    drop(lease);

    let second_closes = Arc::new(Mutex::new(Vec::new()));
    let mut second_manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let second = second_manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&second_closes),
        )
        .expect("second direct path");
    let second_lease = registry.acquire(&second).expect("second lease");
    second_manager.hard_close();
    assert!(!second_lease.is_active());
    assert_eq!(
        second_closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::HardClose]
    );

    let drained_closes = Arc::new(Mutex::new(Vec::new()));
    let mut drained_manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let drained = drained_manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&drained_closes),
        )
        .expect("draining path");
    let drained_lease = registry.acquire(&drained).expect("draining lease");
    drained_manager.normal_drain();
    assert!(drained_lease.is_active());
    drained_manager.hard_close();
    assert!(!drained_lease.is_active());
    assert_eq!(
        drained_closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::HardClose]
    );
}

#[test]
fn ephemeral_paths_retire_after_sixty_seconds_without_sleeping() {
    let registry = Arc::new(PathRegistry::new());
    let direct_closes = Arc::new(Mutex::new(Vec::new()));
    let relay_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let now = Instant::now();
    let direct = manager
        .publish_ready_with_carrier_at(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&direct_closes),
            now - super::super::EPHEMERAL_PATH_IDLE_TIMEOUT - Duration::from_secs(1),
        )
        .expect("ephemeral direct path");
    let relay = manager
        .publish_ready_with_carrier_at(
            profile(PathKind::Relay, RouteTransport::WebSocket),
            recording_carrier(&relay_closes),
            now - super::super::EPHEMERAL_PATH_IDLE_TIMEOUT - Duration::from_secs(1),
        )
        .expect("ephemeral relay path");

    assert!(manager.ephemeral_idle(now));
    assert_eq!(manager.retire_ephemeral(now), 2);
    assert!(matches!(
        registry.acquire(&direct),
        Err(CoreNetworkError::StaleAttempt)
    ));
    assert!(matches!(
        registry.acquire(&relay),
        Err(CoreNetworkError::StaleAttempt)
    ));
    assert_eq!(
        direct_closes.lock().expect("direct close log").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
    assert_eq!(
        relay_closes.lock().expect("relay close log").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[test]
fn registry_peer_revoke_hard_closes_manager_owned_paths() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let handle = manager
        .publish_ready_with_carrier(
            profile(PathKind::Relay, RouteTransport::WebSocket),
            recording_carrier(&closes),
        )
        .expect("relay path");
    let lease = registry.acquire(&handle).expect("lease");

    assert_eq!(registry.revoke_peer(&test_peer()), 1);
    assert!(!lease.is_active());
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::HardClose]
    );
    assert_eq!(manager.relay_state(), RelayPathState::None);
}

#[test]
fn registry_selection_skips_incompatible_paths_and_prefers_direct() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let direct_message = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::WebSocket))
        .expect("message-only path");
    let relay = manager
        .publish_ready(profile(PathKind::Relay, RouteTransport::WebSocket))
        .expect("relay stream fallback");

    let relay_lease = registry
        .select_compatible_ready_path(&test_peer(), CAPABILITY_RELIABLE_STREAM)
        .expect("relay stream path");
    assert_eq!(relay_lease.handle(), &relay);
    assert_ne!(relay_lease.handle(), &direct_message);
    drop(relay_lease);
    assert!(matches!(
        registry.select_compatible_ready_path(&test_peer(), CAPABILITY_UNRELIABLE_DATAGRAM),
        Err(CoreNetworkError::NoRoute)
    ));
    let missing_peer = PeerId::new("missing-peer").expect("peer id");
    assert!(matches!(
        registry.select_compatible_ready_path(&missing_peer, CAPABILITY_RELIABLE_MESSAGE),
        Err(CoreNetworkError::NoRoute)
    ));

    manager
        .ensure_direct_probe(7, CAPABILITY_RELIABLE_STREAM, Duration::from_secs(4))
        .expect("stream demand");
    let direct = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::Quic))
        .expect("quic path");
    let direct_lease = registry
        .select_compatible_ready_path(&test_peer(), CAPABILITY_RELIABLE_STREAM)
        .expect("direct stream path");
    assert_eq!(direct_lease.handle(), &direct);
    assert_eq!(direct_lease.profile().transport(), RouteTransport::Quic);
    drop(direct_lease);

    let message_lease = registry
        .select_compatible_ready_path(&test_peer(), CAPABILITY_RELIABLE_MESSAGE)
        .expect("direct message path");
    assert_eq!(message_lease.profile().topology(), RouteTopology::Direct);
    drop(message_lease);
}

#[test]
fn registry_selection_orders_tcp_and_handles_datagram_only_routes() {
    let registry = PathRegistry::new();
    let tcp = registry
        .create_path(
            &test_peer(),
            profile(PathKind::Direct, RouteTransport::Tcp),
            Box::new(NoopPathCarrier),
            Instant::now(),
        )
        .expect("TCP path");
    let udp = registry
        .create_path(
            &test_peer(),
            profile(PathKind::Direct, RouteTransport::Udp),
            Box::new(NoopPathCarrier),
            Instant::now(),
        )
        .expect("UDP path");

    let stream = registry
        .select_compatible_ready_path(&test_peer(), CAPABILITY_RELIABLE_STREAM)
        .expect("TCP stream path");
    assert_eq!(stream.handle(), tcp.handle());
    drop(stream);
    let datagram = registry
        .select_compatible_ready_path(&test_peer(), CAPABILITY_UNRELIABLE_DATAGRAM)
        .expect("UDP datagram path");
    assert_eq!(datagram.handle(), udp.handle());
}

#[test]
fn equivalent_late_direct_loses() {
    let registry = Arc::new(PathRegistry::new());
    let first_closes = Arc::new(Mutex::new(Vec::new()));
    let late_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let first = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&first_closes),
        )
        .expect("first direct path");

    let result = manager.publish_ready_with_carrier(
        profile(PathKind::Direct, RouteTransport::Tcp),
        recording_carrier(&late_closes),
    );

    assert_eq!(result, Err(CoreNetworkError::StaleAttempt));
    assert_eq!(manager.direct_ready(), Some(&first));
    assert!(first_closes.lock().expect("first close log").is_empty());
    assert_eq!(
        late_closes.lock().expect("late close log").as_slice(),
        &[PathCloseReason::HardClose]
    );
    assert!(registry.acquire(&first).is_ok());
}

#[test]
fn weaker_late_direct_loses() {
    let registry = Arc::new(PathRegistry::new());
    let first_closes = Arc::new(Mutex::new(Vec::new()));
    let late_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let first = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&first_closes),
        )
        .expect("first direct stream path");

    let result = manager.publish_ready_with_carrier(
        profile(PathKind::Direct, RouteTransport::WebSocket),
        recording_carrier(&late_closes),
    );

    assert_eq!(result, Err(CoreNetworkError::StaleAttempt));
    assert_eq!(manager.direct_ready(), Some(&first));
    assert!(first_closes.lock().expect("first close log").is_empty());
    assert_eq!(
        late_closes.lock().expect("late close log").as_slice(),
        &[PathCloseReason::HardClose]
    );
}

#[test]
fn needed_strict_superset_can_promote() {
    let registry = Arc::new(PathRegistry::new());
    let old_closes = Arc::new(Mutex::new(Vec::new()));
    let new_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let old = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::WebSocket),
            recording_carrier(&old_closes),
        )
        .expect("message-only direct path");
    manager
        .ensure_direct_probe(8, CAPABILITY_RELIABLE_STREAM, Duration::from_secs(4))
        .expect("stream demand");

    let promoted = manager
        .publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&new_closes),
        )
        .expect("needed stream-capable direct path");

    assert_ne!(promoted, old);
    assert_eq!(manager.direct_ready(), Some(&promoted));
    assert!(manager.direct_probe().is_none());
    assert_eq!(
        old_closes.lock().expect("old close log").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
    assert!(new_closes.lock().expect("new close log").is_empty());
    assert!(matches!(
        registry.acquire(&old),
        Err(CoreNetworkError::StaleAttempt)
    ));
}

#[test]
fn direct_probe_merges_demands_and_rejects_stale_generations() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));

    let first = manager
        .ensure_direct_probe(7, CAPABILITY_RELIABLE_MESSAGE, Duration::from_millis(1))
        .expect("initial direct probe")
        .clone();
    assert_eq!(manager.direct_state(), DirectPathState::Probe);
    assert_eq!(first.generation, 7);
    assert_eq!(first.required_capabilities, CAPABILITY_RELIABLE_MESSAGE);
    assert!(!first.is_expired(Instant::now()));

    let extended = manager
        .ensure_direct_probe(7, CAPABILITY_RELIABLE_STREAM, Duration::from_secs(10))
        .expect("stronger direct probe")
        .clone();
    assert_eq!(
        extended.required_capabilities,
        CAPABILITY_RELIABLE_MESSAGE | CAPABILITY_RELIABLE_STREAM
    );
    assert!(extended.deadline >= first.deadline);
    assert!(extended.is_expired(extended.deadline));
    assert_eq!(
        manager.ensure_direct_probe(8, CAPABILITY_RELIABLE_MESSAGE, Duration::from_secs(1)),
        Err(CoreNetworkError::StaleAttempt)
    );
    assert!(!manager.finish_direct_probe(8));
    assert!(manager.finish_direct_probe(7));
    assert_eq!(manager.direct_state(), DirectPathState::None);

    manager.normal_drain();
    assert_eq!(
        manager.ensure_direct_probe(9, CAPABILITY_RELIABLE_MESSAGE, Duration::from_secs(1)),
        Err(CoreNetworkError::Cancelled)
    );
}

#[test]
fn path_registry_enforces_capacity_and_reclaims_stale_weak_entries() {
    let registry = Arc::new(PathRegistry::new());
    let mut paths = Vec::new();
    for _ in 0..MAX_READY_PATHS_PER_PEER {
        paths.push(
            registry
                .create_path(
                    &test_peer(),
                    profile(PathKind::Direct, RouteTransport::Tcp),
                    Box::new(NoopPathCarrier),
                    Instant::now(),
                )
                .expect("path within registry limit"),
        );
    }
    let overflow_closes = Arc::new(Mutex::new(Vec::new()));
    assert!(matches!(
        registry.create_path(
            &test_peer(),
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&overflow_closes),
            Instant::now(),
        ),
        Err(CoreNetworkError::ResourceLimit("ready paths"))
    ));
    assert_eq!(
        overflow_closes
            .lock()
            .expect("overflow close log")
            .as_slice(),
        &[PathCloseReason::HardClose]
    );

    let first_handle = paths[0].handle().clone();
    assert!(registry.lookup(&first_handle).is_some());
    assert!(registry.is_acquirable(&first_handle));
    drop(paths.remove(0));
    let replacement = registry
        .create_path(
            &test_peer(),
            profile(PathKind::Direct, RouteTransport::Tcp),
            Box::new(NoopPathCarrier),
            Instant::now(),
        )
        .expect("stale weak entry is reclaimed");
    paths.push(replacement);

    let existing = paths[0].handle().clone();
    let missing = PathHandle {
        id: existing.id() + 1000,
        peer_id: existing.peer_id().clone(),
        profile: existing.profile(),
        capability_mask: existing.capability_mask(),
    };
    assert!(!registry.revoke(&missing));
    assert!(!registry.drain(&missing));
    assert!(!registry.security_failure(&missing));
    assert_eq!(registry.lease_count(&missing), None);
    assert_eq!(registry.revoke_peer(&test_peer()), MAX_READY_PATHS_PER_PEER);
}

#[test]
fn path_leases_enforce_borrower_limit_and_projection_identity() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let direct = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::Tcp))
        .expect("direct path");
    let relay = manager
        .publish_ready(profile(PathKind::Relay, RouteTransport::WebSocket))
        .expect("relay path");
    let projection = manager.projection(&direct).expect("direct projection");

    let mut leases = Vec::new();
    for _ in 0..MAX_PATH_LEASES {
        leases.push(projection.acquire().expect("lease within limit"));
    }
    assert_eq!(registry.lease_count(&direct), Some(MAX_PATH_LEASES));
    assert!(matches!(
        projection.acquire(),
        Err(CoreNetworkError::ResourceLimit("path leases"))
    ));
    drop(leases.pop());
    let replacement_lease = projection.acquire().expect("released lease slot");
    assert_eq!(replacement_lease.handle(), &direct);

    let mut mismatched = projection.clone();
    mismatched.handle = manager.relay_ready().expect("relay handle").clone();
    assert!(matches!(
        mismatched.acquire(),
        Err(CoreNetworkError::StaleAttempt)
    ));
    projection
        .path
        .upgrade()
        .expect("physical path")
        .release_lease();
    drop(replacement_lease);
    drop(leases);
    manager.hard_close();
    assert!(matches!(
        registry.acquire(&relay),
        Err(CoreNetworkError::StaleAttempt)
    ));
}

#[test]
fn manager_rejects_incompatible_or_stopped_publication() {
    let registry = Arc::new(PathRegistry::new());
    let rejected_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    manager
        .ensure_direct_probe(1, CAPABILITY_RELIABLE_STREAM, Duration::from_secs(4))
        .expect("stream probe");
    assert_eq!(
        manager.publish_ready_with_carrier(
            profile(PathKind::Direct, RouteTransport::WebSocket),
            recording_carrier(&rejected_closes),
        ),
        Err(CoreNetworkError::CapabilityUnavailable)
    );
    assert_eq!(
        rejected_closes
            .lock()
            .expect("rejected close log")
            .as_slice(),
        &[PathCloseReason::HardClose]
    );
    assert!(manager.direct_probe().is_some());

    manager.normal_drain();
    assert_eq!(manager.retire_ephemeral(Instant::now()), 0);
    assert_eq!(
        manager.publish_ready(profile(PathKind::Relay, RouteTransport::WebSocket)),
        Err(CoreNetworkError::Cancelled)
    );

    let mut hard_closed = PeerPathManager::new(test_peer(), registry);
    hard_closed.hard_close();
    assert_eq!(hard_closed.retire_ephemeral(Instant::now()), 0);
    assert_eq!(
        hard_closed.publish_ready(profile(PathKind::Direct, RouteTransport::Tcp)),
        Err(CoreNetworkError::Cancelled)
    );
}

#[test]
fn manager_retires_stale_and_ephemeral_paths_by_topology() {
    let registry = Arc::new(PathRegistry::new());
    let direct_closes = Arc::new(Mutex::new(Vec::new()));
    let relay_closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let now = Instant::now();
    let direct = manager
        .publish_ready_with_carrier_at(
            profile(PathKind::Direct, RouteTransport::Tcp),
            recording_carrier(&direct_closes),
            now - super::super::EPHEMERAL_PATH_IDLE_TIMEOUT - Duration::from_secs(1),
        )
        .expect("direct path");
    let relay = manager
        .publish_ready_with_carrier_at(
            profile(PathKind::Relay, RouteTransport::WebSocket),
            recording_carrier(&relay_closes),
            now - super::super::EPHEMERAL_PATH_IDLE_TIMEOUT - Duration::from_secs(1),
        )
        .expect("relay path");
    assert!(manager.ephemeral_idle(now));
    manager.record_activity();
    assert!(!manager.ephemeral_idle(now));
    assert_eq!(manager.retire_ephemeral(now), 0);

    assert!(registry.revoke(&direct));
    assert_eq!(
        manager
            .publish_ready_with_carrier(
                profile(PathKind::Direct, RouteTransport::Tcp),
                recording_carrier(&direct_closes),
            )
            .expect("replace externally closed direct path")
            .kind(),
        PathKind::Direct
    );
    manager.hard_close_direct();
    assert_eq!(manager.direct_state(), DirectPathState::None);
    manager.hard_close_relay();
    assert_eq!(manager.relay_state(), RelayPathState::None);
    assert!(matches!(
        registry.acquire(&relay),
        Err(CoreNetworkError::StaleAttempt)
    ));
    assert_eq!(
        direct_closes.lock().expect("direct close log").as_slice(),
        &[PathCloseReason::HardClose, PathCloseReason::HardClose]
    );
    assert_eq!(
        relay_closes.lock().expect("relay close log").as_slice(),
        &[PathCloseReason::HardClose]
    );
}

#[tokio::test]
async fn generic_route_loss_uses_carrier_id_rather_than_path_id() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let route = crate::connection::test_blocking_generic_route();
    let generic_id = route.handle.id();
    loop {
        let handle = manager
            .publish_ready(profile(PathKind::Direct, RouteTransport::Tcp))
            .expect("burn a path id");
        manager.hard_close_direct();
        if handle.id() >= generic_id.raw() {
            break;
        }
    }
    let published = manager
        .publish_ready_with_route(ActiveRoute::generic_test(route.handle.clone()))
        .expect("publish generic carrier");
    assert_ne!(
        published.id(),
        generic_id.raw(),
        "path registry ids and generic route ids are different counters"
    );
    assert_eq!(
        manager.close_ready_direct(Some(generic_id)).as_ref(),
        Some(&published)
    );
    assert!(manager.direct_ready().is_none());
    let _ = route.release.send(());
    route.worker.abort();
}

#[test]
fn saturated_relay_leases_still_close_by_client_identity() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let data = Arc::new(
        network_relay::RelayDataClient::new(
            "ws://127.0.0.1:9/v2/relay/9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d".into(),
            vec![0u8; 32],
            "credential".into(),
            [0u8; 32],
        )
        .expect("relay data client"),
    );
    let handle = manager
        .publish_ready_with_route(ActiveRoute::relay(Some(Arc::clone(&data))))
        .expect("publish relay path");
    let projection = manager.projection(&handle).expect("projection");
    let mut leases = Vec::new();
    for _ in 0..MAX_PATH_LEASES {
        leases.push(projection.acquire().expect("lease within the borrower cap"));
    }
    assert!(projection.acquire().is_err());
    assert_eq!(
        manager.close_ready_relay(Some(&data)).as_ref(),
        Some(&handle)
    );
    assert!(manager.current_relay_data().is_none());
    drop(leases);
}

#[test]
fn conditional_hard_close_never_retires_a_replacement_path() {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(test_peer(), Arc::clone(&registry));
    let direct_a = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::Tcp))
        .expect("direct A");
    assert!(registry.revoke(&direct_a));
    let direct_b = manager
        .publish_ready(profile(PathKind::Direct, RouteTransport::Tcp))
        .expect("direct B");

    assert!(manager.hard_close_direct_if_handle(&direct_a).is_none());
    assert_eq!(manager.direct_ready(), Some(&direct_b));
    assert!(registry.acquire(&direct_b).is_ok());

    let relay_a = manager
        .publish_ready(profile(PathKind::Relay, RouteTransport::WebSocket))
        .expect("relay A");
    assert!(registry.revoke(&relay_a));
    let relay_b = manager
        .publish_ready(profile(PathKind::Relay, RouteTransport::WebSocket))
        .expect("relay B");

    assert!(manager.hard_close_relay_if_handle(&relay_a).is_none());
    assert_eq!(manager.relay_ready(), Some(&relay_b));
    assert!(registry.acquire(&relay_b).is_ok());
}

#[test]
fn relay_only_lease_drains_existing_io_and_rejects_new_work() {
    let registry = Arc::new(PathRegistry::new());
    let closes = Arc::new(Mutex::new(Vec::new()));
    let mut manager = PeerPathManager::new(test_peer(), registry);
    manager
        .publish_ready_with_carrier(
            profile(PathKind::Relay, RouteTransport::WebSocket),
            recording_carrier(&closes),
        )
        .expect("relay path");
    let lease = manager
        .acquire_relay(CAPABILITY_RELIABLE_MESSAGE)
        .expect("relay lease");

    manager.normal_drain();
    assert!(
        lease.is_active(),
        "normal retirement preserves existing I/O"
    );
    assert!(manager.acquire_relay(CAPABILITY_RELIABLE_MESSAGE).is_err());
    assert!(closes.lock().expect("close log lock").is_empty());

    drop(lease);
    assert_eq!(
        closes.lock().expect("close log lock").as_slice(),
        &[PathCloseReason::NormalRetire]
    );
}

#[tokio::test]
async fn route_view_rejects_stream_frames_without_stream_capability() {
    let view = RouteView {
        profile: profile(PathKind::Direct, RouteTransport::WebSocket),
        carrier: RouteViewCarrier::Relay(None),
    };
    let error = send_route_view(view, "", GenericFrameKind::StreamOpen, b"payload")
        .await
        .expect_err("message-only path must reject stream frames");
    assert!(error.to_string().contains("lacks requested capability"));
}

#[tokio::test]
async fn detached_active_routes_report_unavailable_io_and_close_safely() {
    let carrier = ActiveRouteCarrier { route: None };
    let error = carrier
        .send_channel_frame("", GenericFrameKind::DataMessage, b"payload")
        .await
        .expect_err("detached route cannot send");
    assert!(error.to_string().contains("physical path unavailable"));
    Box::new(carrier).close(PathCloseReason::HardClose);

    ActiveRoute::relay(None).close().await;
}
