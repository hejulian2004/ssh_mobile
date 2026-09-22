use network_protocol::PeerConnectionState;
use std::net::SocketAddr;
use std::sync::Arc;

use crate::connect::profile_capability_mask;
use crate::connection::{prepare_generic_route, GenericConnection};
use crate::events::emit_peer_state_profile;
use crate::generic_auth::authenticate_responder_auto_policy;
use crate::runtime::RuntimeState;

use super::generic_race::OutboundGenericConnector;
use super::inbound::InboundConnectionAcceptor;
use super::registry::install_admitted_crypto;
use super::GENERIC_ROUTE_CONNECT_TIMEOUT;

impl InboundConnectionAcceptor {
    pub(crate) async fn admit_authenticated_inbound(
        state: &RuntimeState,
        peer_id: &str,
        capabilities: u8,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if !state.peers.read().await.contains_key(peer_id) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "authenticated inbound peer is not configured",
            )
            .into());
        }
        // A V2 registration may explicitly revoke the Direct route while
        // leaving the trust record intact for a later re-authorization.  Do
        // this check at inbound admission as well as outbound selection so a
        // peer cannot bypass route policy by dialing the native listener.
        if !state
            .route_is_authorized(peer_id, crate::connection::RouteTopology::Direct)
            .await
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "direct route is not authorized for authenticated inbound peer",
            )
            .into());
        }
        let supervisor = state
            .peer_supervisors
            .get_or_create(peer_id)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        supervisor
            .admit_inbound_with_capabilities(true, capabilities)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        Ok(())
    }
}

impl InboundConnectionAcceptor {
    pub(crate) async fn accept_authenticated_generic(
        state: Arc<RuntimeState>,
        mut connection: GenericConnection,
        peer_address: SocketAddr,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let identity = state
            .lifecycle
            .identity
            .read()
            .await
            .clone()
            .ok_or_else(|| std::io::Error::other("runtime identity is unavailable"))?;
        let inbound_profile = connection.profile();
        let binding_state = Arc::clone(&state);
        let authenticated = tokio::time::timeout(
            GENERIC_ROUTE_CONNECT_TIMEOUT,
            authenticate_responder_auto_policy(
                &mut connection,
                identity,
                &state.trusted_peer_keys,
                move |peer_id, remote_session_binding| {
                    let binding_state = Arc::clone(&binding_state);
                    let peer_id = peer_id.to_string();
                    let remote_session_binding = remote_session_binding.to_string();
                    async move {
                        if profile_capability_mask(inbound_profile) == 0
                            || !binding_state.peers.read().await.contains_key(&peer_id)
                            || !binding_state
                                .route_is_authorized(
                                    &peer_id,
                                    crate::connection::RouteTopology::Direct,
                                )
                                .await
                        {
                            return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                        }
                        let admission = binding_state
                            .admit_authenticated_session(&peer_id, None, &remote_session_binding)
                            .await
                            .map_err(|_| crate::crypto_handshake::CryptoHandshakeError::Failed)?;
                        Ok((admission.session_id.wire_key(), admission))
                    }
                },
            ),
        )
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "TCP auth timed out"))??;
        let crate::generic_auth::AuthenticatedPeer {
            peer_id,
            session_binding,
            crypto,
            admission,
        } = authenticated;
        if state.e2ee_policy(&peer_id).await != crypto.e2ee_policy {
            state
                .release_claimed_session(
                    &peer_id,
                    admission.session_id,
                    &crypto.remote_session_binding,
                )
                .await;
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "generic route E2EE policy does not match peer configuration",
            )
            .into());
        }
        tracing::debug!(%session_binding, "generic route Session binding authenticated");
        if admission.session_id.wire_key() != crypto.local_session_binding {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "generic route Session binding became stale",
            )
            .into());
        }
        let session_id = admission.session_id;
        let profile = connection.profile();
        if !state
            .candidate_supports_required(&peer_id, session_id, profile)
            .await
        {
            state
                .release_claimed_session(&peer_id, session_id, &crypto.remote_session_binding)
                .await;
            return Err(std::io::Error::other(
                "generic route no longer satisfies the requested capability",
            )
            .into());
        }
        state
            .connection_sessions
            .finalize_authenticated_session(&peer_id, session_id, &crypto.remote_session_binding)
            .await
            .map_err(|_| std::io::Error::other("Session was replaced during handshake"))?;
        install_admitted_crypto(&state, &peer_id, &admission, &crypto).await?;
        let attempted_peer_id = peer_id.clone();
        let result = async {
        let mut scope = OutboundGenericConnector::supervise_generic_route(
            Arc::clone(&state),
            &peer_id,
            session_id,
            prepare_generic_route(connection),
        )
        .await
        .map_err(|error| std::io::Error::other(error.message.clone()))?;
        let profile = scope
            .profile()
            .expect("supervised GenericRoute scope has a profile");
        let _previous_route = match state
            .attach_generic_route_for_session(&peer_id, Some(session_id), &mut scope)
            .await
        {
            Ok(previous_route) => previous_route,
            Err(_) => {
                scope.close().await;
                return Err(std::io::Error::other("TCP route lost its Session race").into());
            }
        };
        Self::admit_authenticated_inbound(&state, &peer_id, profile_capability_mask(profile))
            .await?;
        emit_peer_state_profile(
            &state.event_tx,
            &peer_id,
            PeerConnectionState::Connected,
            Some(profile),
            None,
        );
        crate::channel::recover_session(Arc::clone(&state), peer_id.clone()).await;
        crate::transfer::resume_transfers_for_peer(Arc::clone(&state), peer_id.clone()).await;
        tracing::debug!(%peer_address, session_id = %session_id.wire_key(), "authenticated TCP fallback route attached");
        Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
    }
    .await;
        if result.is_err() {
            state.fail_session(&attempted_peer_id, session_id).await;
        }
        result
    }
}
