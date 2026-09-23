//! 对端注册表、路由选择与异步连接任务（transport-network v2）。

mod configure;
mod direct_quic;
mod direct_race;
mod generic_dial;
mod generic_race;
mod inbound;
mod inbound_admission;
mod receiver;
mod registry;
mod relay_handshake;

use network_identity::DeviceIdentity;
use network_nat::Candidate;
use quinn::{Connection, Endpoint};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;

use crate::connect::GenericRouteScope;
use crate::crypto_handshake::SessionCryptoMaterial;
use crate::runtime::{ConnectionAdmissionLease, RuntimeState};
use crate::session::SessionId;

const GENERIC_ROUTE_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
/// Delay between launching successive candidate groups. Every attempt still
/// shares the parent Direct deadline; this only prevents a blackhole from
/// monopolizing the first probe slot while keeping the race bounded.
const CANDIDATE_STAGGER: Duration = Duration::from_millis(150);

pub(crate) struct AuthenticatedGenericRoute {
    pub(crate) scope: GenericRouteScope,
    pub(crate) endpoint: SocketAddr,
    pub(crate) crypto: SessionCryptoMaterial,
    pub(crate) admission: ConnectionAdmissionLease,
}

pub(crate) enum ConnectedRoute {
    Quic {
        connection: Connection,
        crypto: SessionCryptoMaterial,
        admission: ConnectionAdmissionLease,
    },
    Generic(AuthenticatedGenericRoute),
}

pub(crate) struct DirectRouteAttempt {
    pub(crate) state: Arc<RuntimeState>,
    pub(crate) endpoint: Endpoint,
    pub(crate) candidates: Vec<Candidate>,
    pub(crate) identity: Arc<DeviceIdentity>,
    pub(crate) expected_peer_public_key: [u8; 32],
    pub(crate) peer_id: String,
    pub(crate) session_binding: String,
    pub(crate) session_id: SessionId,
    pub(crate) attempt_id: String,
    pub(crate) connect_window: Duration,
    /// Exact capability demand carried by this attempt.  A supervisor may
    /// merge concurrent business requests, so route admission must validate
    /// this mask instead of relying on the legacy class projection.
    pub(crate) required_capabilities: u8,
    pub(crate) allow_websocket: bool,
    /// Candidate snapshots arriving from the authenticated ConnectivityAnswer
    /// while the bounded Direct race is still running.
    pub(crate) candidate_updates: watch::Receiver<Option<Vec<Candidate>>>,
}

pub(crate) use configure::configure_runtime;
#[cfg(test)]
pub(crate) use configure::parse_stun_servers;
#[cfg(test)]
#[allow(unused_imports)]
pub(crate) use direct_quic::admit_single_winner;
pub(crate) use direct_quic::connect_responder_direct;
#[allow(unused_imports)]
pub(crate) use direct_quic::{connect_direct, connect_direct_with_crypto};
#[cfg(test)]
#[allow(unused_imports)]
pub(crate) use direct_race::{
    candidate_attempt_key, connect_direct_candidates_with_crypto, enqueue_candidates,
    monotonic_candidate_generation, CandidateAttemptKey,
};
pub(crate) use direct_race::{candidate_kind_for, connect_direct_or_generic};
#[cfg(test)]
pub(crate) use generic_race::OutboundGenericConnector;
#[cfg(test)]
pub(crate) use inbound::InboundConnectionAcceptor;
#[cfg(test)]
#[allow(unused_imports)]
pub(crate) use inbound::{AcceptFuture, TcpAcceptStep};
pub(crate) use receiver::ConnectionReceiverSupervisor;
#[cfg(test)]
pub(crate) use receiver::GenericReceiverStopGuard;
#[cfg(test)]
pub(crate) use registry::upsert_peer;
pub(crate) use registry::{disconnect_peer, install_admitted_crypto, upsert_peer_with_policy};
pub(crate) use relay_handshake::establish_relay_crypto;
#[cfg(test)]
pub(crate) use relay_handshake::receive_relay_crypto_step;

#[cfg(test)]
use crate::connect::{
    CAPABILITY_RELIABLE_MESSAGE, CAPABILITY_RELIABLE_STREAM, CAPABILITY_UNRELIABLE_DATAGRAM,
    DEFAULT_CONNECTION_CAPABILITY,
};
#[cfg(test)]
use crate::connection::{
    prepare_generic_route, GenericConnection, GenericFrameKind, RouteTransport,
};
#[cfg(test)]
use crate::generic_auth::authenticate_initiator_with_policy;
#[cfg(test)]
use crate::runtime::PeerConfig;
#[cfg(test)]
use network_nat::{CandidateKind, PathManager};
#[cfg(test)]
use network_protocol::{NetworkErrorCode, RouteType, UpsertPeerCommand};
#[cfg(test)]
use network_quic::{QuicEndpointManager, QuicPeerSession};
#[cfg(test)]
use network_relay::RelayDataClient;
#[cfg(test)]
use quinn::VarInt;
#[cfg(test)]
use std::collections::{HashSet, VecDeque};
#[cfg(test)]
use std::future::Future;
#[cfg(test)]
use std::pin::Pin;
#[cfg(test)]
use std::time::Instant;
#[cfg(test)]
use tokio::sync::{mpsc, oneshot};
#[cfg(test)]
use tokio::time::timeout;

#[cfg(test)]
#[path = "../tests/peer.rs"]
mod tests;
