use network_identity::DeviceIdentity;
use network_protocol::{NetworkError as ProtocolError, NetworkErrorCode};
use std::net::SocketAddr;
use std::sync::Arc;

use crate::connection::{prepare_generic_route, GenericConnection, RouteTopology};
use crate::events::protocol_error_with_peer;
use crate::generic_auth::authenticate_initiator_with_policy;
use crate::runtime::RuntimeState;
use crate::session::SessionId;

use super::direct_quic::admit_single_winner;
use super::generic_race::OutboundGenericConnector;
use super::{AuthenticatedGenericRoute, GENERIC_ROUTE_CONNECT_TIMEOUT};

#[derive(Clone, Copy)]
pub(crate) enum GenericDial {
    Tcp,
    WebSocket,
}

impl GenericDial {
    fn label(self) -> &'static str {
        match self {
            Self::Tcp => "TCP",
            Self::WebSocket => "WebSocket",
        }
    }
}

impl OutboundGenericConnector {
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn connect_generic_route(
        dial: GenericDial,
        endpoint: SocketAddr,
        identity: Arc<DeviceIdentity>,
        expected_peer_public_key: [u8; 32],
        peer_id: String,
        session_binding: String,
        state: Arc<RuntimeState>,
        expected_session_id: SessionId,
        required_capabilities: u8,
    ) -> Result<AuthenticatedGenericRoute, ProtocolError> {
        let timeout_peer_id = peer_id.clone();
        let label = dial.label();
        let result = tokio::time::timeout(GENERIC_ROUTE_CONNECT_TIMEOUT, async move {
            let mut connection = match dial {
                GenericDial::Tcp => GenericConnection::connect_tcp(
                    "0.0.0.0:0".parse().expect("wildcard address"),
                    endpoint,
                )
                .await
                .map_err(|error| {
                    protocol_error_with_peer(
                        NetworkErrorCode::IoError,
                        format!("TCP route connection failed: {error}"),
                        "connect",
                        &peer_id,
                    )
                })?,
                GenericDial::WebSocket => {
                    let url = format!("ws://{endpoint}/V2/transport");
                    GenericConnection::connect_websocket(&url)
                        .await
                        .map_err(|error| {
                            protocol_error_with_peer(
                                NetworkErrorCode::IoError,
                                format!("WebSocket route connection failed: {error}"),
                                "connect",
                                &peer_id,
                            )
                        })?
                        .with_topology(RouteTopology::Direct)
                }
            };
            if !crate::connect::profile_satisfies(connection.profile(), required_capabilities) {
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    format!("{label} candidate does not satisfy the requested capability"),
                    "connect",
                    &peer_id,
                ));
            }
            let e2ee_policy = state.e2ee_policy(&peer_id).await;
            let resolver_state = Arc::clone(&state);
            let resolver_peer_id = peer_id.clone();
            let (crypto, admission) = authenticate_initiator_with_policy(
                &mut connection,
                identity,
                &peer_id,
                expected_peer_public_key,
                &session_binding,
                e2ee_policy,
                move |authenticated_peer_id, remote_session_binding| {
                    let resolver_state = Arc::clone(&resolver_state);
                    let resolver_peer_id = resolver_peer_id.clone();
                    let remote_session_binding = remote_session_binding.to_string();
                    let authenticated_peer_id = authenticated_peer_id.to_string();
                    async move {
                        if authenticated_peer_id != resolver_peer_id {
                            return Err(crate::crypto_handshake::CryptoHandshakeError::Failed);
                        }
                        let admission = admit_single_winner(
                            &resolver_state,
                            &resolver_peer_id,
                            Some(expected_session_id),
                            &remote_session_binding,
                        )
                        .await
                        .map_err(|_| crate::crypto_handshake::CryptoHandshakeError::Failed)?;
                        Ok((admission.session_id.wire_key(), admission))
                    }
                },
            )
            .await
            .map_err(|error| {
                protocol_error_with_peer(
                    NetworkErrorCode::AuthenticationFailed,
                    format!("{label} route authentication failed: {error}"),
                    "connect",
                    &peer_id,
                )
            })?;
            let scope = match Self::supervise_generic_route(
                Arc::clone(&state),
                &peer_id,
                admission.session_id,
                prepare_generic_route(connection),
            )
            .await
            {
                Ok(scope) => scope,
                Err(error) => {
                    state
                        .release_claimed_session(
                            &peer_id,
                            admission.session_id,
                            &crypto.remote_session_binding,
                        )
                        .await;
                    return Err(error);
                }
            };
            if state.connection_sessions.current_session_id(&peer_id).await
                != Some(admission.session_id)
            {
                scope.close().await;
                state
                    .release_claimed_session(
                        &peer_id,
                        admission.session_id,
                        &crypto.remote_session_binding,
                    )
                    .await;
                return Err(protocol_error_with_peer(
                    NetworkErrorCode::NoRoute,
                    format!("{label} candidate Session was replaced before route publication"),
                    "connect",
                    &peer_id,
                ));
            }
            Ok(AuthenticatedGenericRoute {
                scope,
                endpoint,
                crypto,
                admission,
            })
        })
        .await;
        match result {
            Ok(result) => result,
            Err(_) => Err(protocol_error_with_peer(
                NetworkErrorCode::Timeout,
                format!("{label} route connection timed out"),
                "connect",
                &timeout_peer_id,
            )),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn connect_tcp_route(
        endpoint: SocketAddr,
        identity: Arc<DeviceIdentity>,
        expected_peer_public_key: [u8; 32],
        peer_id: String,
        session_binding: String,
        state: Arc<RuntimeState>,
        expected_session_id: SessionId,
        required_capabilities: u8,
    ) -> Result<AuthenticatedGenericRoute, ProtocolError> {
        Self::connect_generic_route(
            GenericDial::Tcp,
            endpoint,
            identity,
            expected_peer_public_key,
            peer_id,
            session_binding,
            state,
            expected_session_id,
            required_capabilities,
        )
        .await
    }
}
