use super::{v2_relay_data_endpoint, FakeRelayV2Server};
use crate::connect::{ActiveRoute, PathRegistry, PeerId, PeerPathManager};
use crate::crypto_handshake::{path_handshake, SessionCryptoMaterial};
use crate::relay::{send_file_over_relay, test_handle_relay_data_payload};
use crate::runtime::{PeerConfig, RuntimeState};
use network_identity::DeviceIdentity;
use network_protocol::{E2eePolicy, NetworkEvent};
use network_relay::v2::{DataEvent, RelayDataClient};
use network_transfer::{build_file_manifest, ResumableTransfer};
use std::collections::HashMap;
use std::sync::atomic::AtomicU16;
use std::sync::Arc;
use tokio::sync::mpsc;

use crate::connect::CAPABILITY_RELIABLE_STREAM;

const DATA_ENV_FILE_OFFER: u8 = 0x02;
const DATA_ENV_FILE_ACCEPT: u8 = 0x03;
const DATA_ENV_FILE_COMPLETE: u8 = 0x04;
const DATA_ENV_FILE_COMPLETE_ACK: u8 = 0x05;

async fn state_with_identity(
    identity: &DeviceIdentity,
    peer: &DeviceIdentity,
) -> Arc<RuntimeState> {
    let (event_tx, _event_rx) = mpsc::unbounded_channel::<NetworkEvent>();
    let state = Arc::new(RuntimeState::new(event_tx, Arc::new(AtomicU16::new(0))));
    let identity = DeviceIdentity::from_private_keys(
        identity.device_id.clone(),
        identity.identity_key.to_bytes(),
        identity.e2e_key.to_bytes(),
    );
    *state.lifecycle.identity.write().await = Some(Arc::new(identity));
    state.peers.write().await.insert(
        peer.device_id.clone(),
        PeerConfig {
            endpoint: None,
            identity_public_key: peer.public_identity_key().to_bytes(),
            e2e_public_key: peer.public_e2e_key().to_bytes(),
            e2ee_policy: E2eePolicy::Required,
        },
    );
    state.allow_routes_for_test(&peer.device_id).await;
    state
}

async fn install_relay_path(state: &Arc<RuntimeState>, peer_id: &str, data: Arc<RelayDataClient>) {
    let registry = Arc::new(PathRegistry::new());
    let mut manager = PeerPathManager::new(
        PeerId::new(peer_id).expect("valid peer"),
        Arc::clone(&registry),
    );
    manager
        .publish_ready_with_route(ActiveRoute::relay(Some(data)))
        .expect("relay path");
    state
        .peer_path_managers
        .write()
        .await
        .insert(peer_id.into(), Arc::new(std::sync::Mutex::new(manager)));
    state.allow_routes_for_test(peer_id.into()).await;
}

fn install_crypto(state: &RuntimeState, peer_id: &str, session_id: &str, initiator: bool) {
    state
        .install_crypto_material(
            peer_id,
            session_id,
            &SessionCryptoMaterial {
                root_key: [0x42; 32],
                local_session_binding: session_id.into(),
                remote_session_binding: session_id.into(),
                initiator,
                e2ee_policy: path_handshake::E2eePolicy::Required,
                path_security: path_handshake::PathSecurity::E2ee,
            },
        )
        .expect("install application crypto");
}

#[tokio::test]
async fn relay_file_transfer_round_trip_exercises_offer_chunk_and_completion() {
    let sender_identity = DeviceIdentity::from_private_keys("sender".into(), [11; 32], [21; 32]);
    let receiver_identity =
        DeviceIdentity::from_private_keys("receiver".into(), [12; 32], [22; 32]);
    let reservation_id = "9a8b7c6d5e4f3a2b1c9d8e7f6a5b4c3d";
    let sender_token = vec![0x11; 32];
    let receiver_token = vec![0x22; 32];
    let mut reservations = HashMap::new();
    reservations.insert(
        reservation_id.to_string(),
        (sender_token.clone(), receiver_token.clone()),
    );
    let relay_server = FakeRelayV2Server::start(reservations).await;
    let endpoint = v2_relay_data_endpoint(relay_server.address, reservation_id);

    let mut sender_data = RelayDataClient::new(
        endpoint.clone(),
        reservation_id.into(),
        sender_token,
        "credential".into(),
        [31; 32],
    )
    .expect("sender data client");
    let mut receiver_data = RelayDataClient::new(
        endpoint,
        reservation_id.into(),
        receiver_token,
        "credential".into(),
        [32; 32],
    )
    .expect("receiver data client");
    let (sender_connect, receiver_connect) = tokio::join!(
        sender_data.connect_reservation(),
        receiver_data.connect_reservation()
    );
    sender_connect.expect("sender reservation pairing");
    receiver_connect.expect("receiver reservation pairing");
    let sender_events = sender_data.take_events().expect("sender events");
    let receiver_events = receiver_data.take_events().expect("receiver events");
    let sender_data = Arc::new(sender_data);
    let receiver_data = Arc::new(receiver_data);

    let sender_state = state_with_identity(&sender_identity, &receiver_identity).await;
    let receiver_state = state_with_identity(&receiver_identity, &sender_identity).await;
    install_relay_path(&sender_state, "receiver", Arc::clone(&sender_data)).await;
    install_relay_path(&receiver_state, "sender", Arc::clone(&receiver_data)).await;
    sender_state
        .relay
        .relay_path_ready
        .write()
        .await
        .insert("receiver".into());
    receiver_state
        .relay
        .relay_path_ready
        .write()
        .await
        .insert("sender".into());
    let session_id = "00000000000000aa";
    install_crypto(&sender_state, "receiver", session_id, true);
    install_crypto(&receiver_state, "sender", session_id, false);

    let sender_root = std::env::temp_dir().join(format!(
        "ssh-mobile-relay-round-trip-{}",
        std::process::id()
    ));
    let receiver_root = sender_root.with_extension("receiver");
    tokio::fs::create_dir_all(&sender_root).await.unwrap();
    tokio::fs::create_dir_all(&receiver_root).await.unwrap();
    *receiver_state.lifecycle.receive_directory.write().await = Some(receiver_root.clone());
    let source = sender_root.join("source.bin");
    let payload = b"relay-round-trip-payload";
    tokio::fs::write(&source, payload).await.unwrap();
    let transfer_id = "relay-round-trip";
    let manifest = build_file_manifest(transfer_id.into(), &source)
        .await
        .expect("source manifest");
    assert!(
        sender_state
            .transfer
            .manager
            .register_outgoing(manifest.clone(), source.clone(), "receiver".into())
            .await
    );

    let receiver_loop = {
        let state = Arc::clone(&receiver_state);
        let data = Arc::clone(&receiver_data);
        tokio::spawn(async move {
            let mut events = receiver_events;
            while let Some(DataEvent::Payload {
                encrypted_payload, ..
            }) = events.recv().await
            {
                let kind = encrypted_payload.first().copied();
                test_handle_relay_data_payload(&state, &data, "sender", &encrypted_payload)
                    .await
                    .unwrap_or_else(|error| {
                        panic!("receiver relay envelope kind {kind:?}: {error}")
                    });
                if kind == Some(DATA_ENV_FILE_OFFER) {
                    crate::relay::respond_to_relay_incoming(&state, transfer_id, true)
                        .await
                        .expect("approve Relay offer");
                }
                if kind == Some(DATA_ENV_FILE_COMPLETE) {
                    break;
                }
            }
        })
    };
    let sender_loop = {
        let state = Arc::clone(&sender_state);
        let data = Arc::clone(&sender_data);
        tokio::spawn(async move {
            let mut events = sender_events;
            while let Some(DataEvent::Payload {
                encrypted_payload, ..
            }) = events.recv().await
            {
                let kind = encrypted_payload.first().copied();
                test_handle_relay_data_payload(&state, &data, "receiver", &encrypted_payload)
                    .await
                    .expect("sender relay envelope");
                if kind == Some(DATA_ENV_FILE_COMPLETE_ACK) {
                    break;
                }
                assert!(
                    kind == Some(DATA_ENV_FILE_ACCEPT),
                    "unexpected sender envelope kind: {kind:?}"
                );
            }
        })
    };

    let peer = PeerConfig {
        endpoint: None,
        identity_public_key: receiver_identity.public_identity_key().to_bytes(),
        e2e_public_key: receiver_identity.public_e2e_key().to_bytes(),
        e2ee_policy: E2eePolicy::Required,
    };
    send_file_over_relay(
        peer,
        ResumableTransfer {
            transfer_id: transfer_id.into(),
            peer_id: "receiver".into(),
            session_id: session_id.into(),
            source_path: source.clone(),
            manifest,
            offset: 0,
        },
        Arc::clone(&sender_state),
        sender_state
            .acquire_relay_path_lease("receiver", CAPABILITY_RELIABLE_STREAM)
            .await
            .expect("sender Relay lease"),
    )
    .await;

    tokio::time::timeout(std::time::Duration::from_secs(3), sender_loop)
        .await
        .expect("sender event loop did not finish")
        .expect("sender event loop panicked");
    tokio::time::timeout(std::time::Duration::from_secs(3), receiver_loop)
        .await
        .expect("receiver event loop did not finish")
        .expect("receiver event loop panicked");
    assert_eq!(
        tokio::fs::read(receiver_root.join("source.bin"))
            .await
            .expect("completed Relay file"),
        payload
    );
    assert!(sender_state
        .transfer
        .manager
        .snapshot(transfer_id)
        .await
        .is_none());
    assert!(receiver_state
        .transfer
        .manager
        .snapshot(transfer_id)
        .await
        .is_none());
    sender_data.request_disconnect().await;
    receiver_data.request_disconnect().await;
    tokio::fs::remove_dir_all(sender_root).await.unwrap();
    tokio::fs::remove_dir_all(receiver_root).await.unwrap();
    drop(relay_server);
}
