use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc,
};
use tokio::sync::{mpsc, oneshot};

use network_transport::{
    Transport, TransportError, TransportKind, TransportReader, TransportWriter,
};

use crate::task_supervisor::CancellationToken;

use super::profile::{ConnectionProfile, Route, RouteTopology};
use super::GenericRouteId;

const GENERIC_FRAME_MAGIC: &[u8; 4] = b"SMGF";
pub(crate) const GENERIC_FRAME_HEADER_BYTES: usize = 4 + 4 + 1 + 4;
pub(crate) const GENERIC_ROUTE_CHANNEL_CAPACITY: usize = 32;
static NEXT_GENERIC_ROUTE_ID: AtomicU64 = AtomicU64::new(1);

/// Owns one generic primitive connection until identity authentication has
/// completed. After authentication, [`prepare_generic_route`] moves the
/// primitive into a staged I/O driver. The driver is intentionally returned as
/// a Future; the Session/Runtime owner decides when and where it is spawned.
pub struct GenericConnection {
    transport: Transport,
    profile: ConnectionProfile,
}

impl GenericConnection {
    pub fn from_transport(transport: Transport) -> Self {
        let profile = ConnectionProfile::for_generic(transport.kind());
        Self { transport, profile }
    }

    pub async fn connect_tcp(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        Ok(Self::from_transport(
            Transport::connect_tcp(local, peer).await?,
        ))
    }

    pub async fn bind_udp(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        Ok(Self::from_transport(
            Transport::bind_udp(local, peer).await?,
        ))
    }

    pub async fn connect_websocket(url: &str) -> Result<Self, TransportError> {
        Ok(Self::from_transport(
            Transport::connect_websocket(url).await?,
        ))
    }

    pub fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    pub fn route(&self) -> Route {
        self.profile.route()
    }

    pub fn with_topology(mut self, topology: RouteTopology) -> Self {
        self.profile =
            ConnectionProfile::for_generic_with_topology(self.transport.kind(), topology);
        self
    }

    pub async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        self.transport.send(payload).await
    }

    pub async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        self.transport.recv().await
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        self.transport.close().await
    }

    pub(crate) fn into_route_parts(self) -> (TransportReader, TransportWriter) {
        self.transport.into_split()
    }
}

/// The application frames supported by reliable generic routes.
/// UDP deliberately has no conversion into this type, so it cannot silently
/// acquire Delivery semantics.
///
/// The byte-stream frames (`StreamOpen`/`StreamBytes`/`StreamClose`) are the
/// ReliableStream carrier (§17): multiple byte streams multiplex over one
/// framed ConnectionSession. Each stream payload starts with
/// `opener_len(u8) + opener_peer_id(UTF-8) + stream_id(u16)`; `StreamBytes`
/// then carries `stream_seq(u64) + len(u32) + data`, while `StreamOpen` adds
/// the service hint and `StreamClose` ends at the stream id. Their inner
/// parsing lives in `crate::stream` so a malformed stream frame only fails
/// that stream, never the route.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum GenericFrameKind {
    DataMessage = 1,
    DeliveryAck = 2,
    StreamBytes = 3,
    StreamOpen = 4,
    StreamClose = 5,
}

impl TryFrom<u8> for GenericFrameKind {
    type Error = ConnectionError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::DataMessage),
            2 => Ok(Self::DeliveryAck),
            3 => Ok(Self::StreamBytes),
            4 => Ok(Self::StreamOpen),
            5 => Ok(Self::StreamClose),
            _ => Err(ConnectionError::InvalidFrame),
        }
    }
}

#[derive(Debug)]
pub(crate) struct GenericInboundFrame {
    pub(crate) kind: GenericFrameKind,
    pub(crate) payload: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum ConnectionError {
    #[error("generic route is closed")]
    Closed,
    #[error("generic route frame is invalid")]
    InvalidFrame,
    #[error("generic route frame is too large")]
    FrameTooLarge,
    #[error("generic route transport failed: {0}")]
    Transport(#[from] TransportError),
    #[error("generic route command was cancelled")]
    Cancelled,
}

enum GenericRouteCommand {
    Send {
        kind: GenericFrameKind,
        payload: Vec<u8>,
        result: oneshot::Sender<Result<(), ConnectionError>>,
    },
    Close {
        result: oneshot::Sender<Result<(), ConnectionError>>,
    },
}

/// A bounded, authenticated generic transport carrier owned by one Session.
/// The I/O task owns the underlying socket, allowing receive and send to make
/// progress concurrently without holding a mutex across a blocking read.
#[derive(Clone)]
pub(crate) struct GenericRouteHandle {
    id: u64,
    profile: ConnectionProfile,
    commands: mpsc::Sender<GenericRouteCommand>,
    stop: CancellationToken,
}

impl GenericRouteHandle {
    pub(crate) fn id(&self) -> GenericRouteId {
        GenericRouteId::new(self.id)
    }

    pub(crate) fn profile(&self) -> ConnectionProfile {
        self.profile
    }

    pub(crate) async fn send(
        &self,
        kind: GenericFrameKind,
        payload: &[u8],
    ) -> Result<(), ConnectionError> {
        let (result_tx, result_rx) = oneshot::channel();
        tokio::select! {
            _ = self.stop.cancelled() => Err(ConnectionError::Cancelled),
            result = self.commands.send(GenericRouteCommand::Send {
                kind,
                payload: payload.to_vec(),
                result: result_tx,
            }) => {
                result.map_err(|_| ConnectionError::Closed)?;
                tokio::select! {
                    _ = self.stop.cancelled() => Err(ConnectionError::Cancelled),
                    result = result_rx => result.map_err(|_| ConnectionError::Cancelled)?,
                }
            }
        }
    }

    pub(crate) async fn close(&self) -> Result<(), ConnectionError> {
        let (result_tx, result_rx) = oneshot::channel();
        tokio::select! {
            _ = self.stop.cancelled() => Err(ConnectionError::Cancelled),
            result = self.commands.send(GenericRouteCommand::Close { result: result_tx }) => {
                result.map_err(|_| ConnectionError::Closed)?;
                tokio::select! {
                    _ = self.stop.cancelled() => Err(ConnectionError::Cancelled),
                    result = result_rx => result.map_err(|_| ConnectionError::Cancelled)?,
                }
            }
        }
    }
}

/// A prepared GenericRoute whose driver has not been started by the runtime
/// owner yet. The driver reports readiness before waiting for `commit`, which
/// lets the Session attach atomically without a pre-attach socket race.
pub(crate) struct GenericRouteRuntime {
    pub(crate) handle: GenericRouteHandle,
    pub(crate) inbound: mpsc::Receiver<GenericInboundFrame>,
    pub(crate) driver: Pin<Box<dyn Future<Output = ()> + Send>>,
    pub(crate) ready: oneshot::Receiver<()>,
    pub(crate) commit: oneshot::Sender<()>,
    pub(crate) stop: CancellationToken,
    pub(crate) stopping: Arc<AtomicBool>,
}

struct GenericRouteStopGuard {
    stop: CancellationToken,
    stopping: Arc<AtomicBool>,
}

impl Drop for GenericRouteStopGuard {
    fn drop(&mut self) {
        if !self.stopping.load(Ordering::Acquire) {
            self.stop.cancel();
        }
    }
}

#[cfg(test)]
pub(crate) struct TestBlockingGenericRoute {
    pub(crate) handle: GenericRouteHandle,
    pub(crate) started: oneshot::Receiver<()>,
    pub(crate) release: oneshot::Sender<()>,
    pub(crate) worker: tokio::task::JoinHandle<()>,
}

#[cfg(test)]
pub(crate) fn test_blocking_generic_route() -> TestBlockingGenericRoute {
    let (command_tx, mut command_rx) = mpsc::channel(GENERIC_ROUTE_CHANNEL_CAPACITY);
    let (started_tx, started_rx) = oneshot::channel();
    let (release_tx, release_rx) = oneshot::channel();
    let handle = GenericRouteHandle {
        id: NEXT_GENERIC_ROUTE_ID.fetch_add(1, Ordering::Relaxed),
        profile: ConnectionProfile::for_generic(TransportKind::Tcp),
        commands: command_tx,
        stop: CancellationToken::default(),
    };
    let worker = tokio::spawn(async move {
        let mut started_tx = Some(started_tx);
        let mut release_rx = Some(release_rx);
        while let Some(command) = command_rx.recv().await {
            match command {
                GenericRouteCommand::Send { result, .. } => {
                    // The blocking test carrier is shared by message and ACK
                    // boundary tests; keep the frame kind opaque here and
                    // only model the transport completion barrier.
                    if let Some(sender) = started_tx.take() {
                        let _ = sender.send(());
                    }
                    if let Some(release) = release_rx.take() {
                        let _ = release.await;
                    }
                    let _ = result.send(Ok(()));
                }
                GenericRouteCommand::Close { result } => {
                    let _ = result.send(Ok(()));
                    return;
                }
            }
        }
    });

    TestBlockingGenericRoute {
        handle,
        started: started_rx,
        release: release_tx,
        worker,
    }
}

/// Moves an authenticated primitive into one staged, bounded I/O driver.
///
/// This function constructs channels and the driver only. It never starts a
/// long-lived task; the caller must register `driver` with the
/// `RuntimeTaskSupervisor` before handing the route to a Session.
pub(crate) fn prepare_generic_route(connection: GenericConnection) -> GenericRouteRuntime {
    let (command_tx, command_rx) = mpsc::channel(GENERIC_ROUTE_CHANNEL_CAPACITY);
    let (inbound_tx, inbound_rx) = mpsc::channel(GENERIC_ROUTE_CHANNEL_CAPACITY);
    let (ready_tx, ready_rx) = oneshot::channel();
    let (commit_tx, mut commit_rx) = oneshot::channel();
    let stop = CancellationToken::default();
    let stopping = Arc::new(AtomicBool::new(false));
    let profile = connection.profile;
    let handle = GenericRouteHandle {
        id: NEXT_GENERIC_ROUTE_ID.fetch_add(1, Ordering::Relaxed),
        profile,
        commands: command_tx,
        stop: stop.clone(),
    };

    let stop_for_driver = stop.clone();
    let stopping_for_driver = Arc::clone(&stopping);
    let driver = Box::pin(async move {
        let mut connection = connection;
        let _stop_guard = GenericRouteStopGuard {
            stop: stop_for_driver.clone(),
            stopping: stopping_for_driver,
        };
        if ready_tx.send(()).is_err() {
            let _ = connection.close().await;
            return;
        }
        let committed = tokio::select! {
            _ = stop_for_driver.cancelled() => false,
            result = &mut commit_rx => result.is_ok(),
        };
        if !committed {
            let _ = connection.close().await;
            return;
        }
        let (reader, writer) = connection.into_route_parts();
        let reader_task = generic_route_reader(reader, inbound_tx, stop_for_driver.clone());
        let writer_task = generic_route_writer(writer, command_rx, stop_for_driver.clone());
        tokio::pin!(reader_task);
        tokio::pin!(writer_task);
        tokio::select! {
            _ = stop_for_driver.cancelled() => {}
            _ = &mut reader_task => {}
            _ = &mut writer_task => {}
        }
    });
    GenericRouteRuntime {
        handle,
        inbound: inbound_rx,
        driver,
        ready: ready_rx,
        commit: commit_tx,
        stop,
        stopping,
    }
}

/// Reads independently from the route writer. Once the bounded Session-facing
/// queue is full, awaiting `send` deliberately stops reading from the socket
/// until the receiver makes room; temporary saturation is not a route error.
async fn generic_route_reader(
    mut reader: TransportReader,
    inbound_tx: mpsc::Sender<GenericInboundFrame>,
    stop: CancellationToken,
) {
    loop {
        let encoded = tokio::select! {
            _ = stop.cancelled() => return,
            result = reader.recv() => match result {
                Ok(encoded) => encoded,
                Err(_) => return,
            },
        };
        let frame = match decode_generic_frame(&encoded) {
            Ok(frame) => frame,
            Err(_) => return,
        };
        tokio::select! {
            _ = stop.cancelled() => return,
            result = inbound_tx.send(frame) => {
                if result.is_err() {
                    return;
                }
            }
        }
    }
}

/// Serializes application frames on the route's write half. The in-flight
/// transport write is itself cancellation-aware, so route replacement and
/// shutdown can preempt a blocked OS write instead of waiting for the peer.
async fn generic_route_writer(
    mut writer: TransportWriter,
    mut command_rx: mpsc::Receiver<GenericRouteCommand>,
    stop: CancellationToken,
) {
    while let Some(command) = tokio::select! {
        _ = stop.cancelled() => return,
        command = command_rx.recv() => command,
    } {
        match command {
            GenericRouteCommand::Send {
                kind,
                payload,
                result,
            } => {
                let encoded = match encode_generic_frame(kind, &payload) {
                    Ok(encoded) => encoded,
                    Err(error) => {
                        let _ = result.send(Err(error));
                        continue;
                    }
                };
                let send_result = tokio::select! {
                    _ = stop.cancelled() => Err(ConnectionError::Cancelled),
                    result = writer.send(&encoded) => result
                        .map(|_| ())
                        .map_err(ConnectionError::from),
                };
                let failed = send_result.is_err();
                let _ = result.send(send_result);
                if failed {
                    return;
                }
            }
            GenericRouteCommand::Close { result } => {
                let close_result = tokio::select! {
                    _ = stop.cancelled() => Err(ConnectionError::Cancelled),
                    result = writer.close() => result
                        .map(|_| ())
                        .map_err(ConnectionError::from),
                };
                let _ = result.send(close_result);
                return;
            }
        }
    }
}

pub(super) fn encode_generic_frame(
    kind: GenericFrameKind,
    payload: &[u8],
) -> Result<Vec<u8>, ConnectionError> {
    if payload.is_empty()
        || payload.len() + GENERIC_FRAME_HEADER_BYTES > network_quic::MAX_CHANNEL_FRAME_BYTES
    {
        return Err(ConnectionError::FrameTooLarge);
    }
    let mut encoded = Vec::with_capacity(GENERIC_FRAME_HEADER_BYTES + payload.len());
    encoded.extend_from_slice(GENERIC_FRAME_MAGIC);
    encoded.extend_from_slice(&network_protocol::NETWORK_PROTOCOL_VERSION.to_be_bytes());
    encoded.push(kind as u8);
    encoded.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    encoded.extend_from_slice(payload);
    Ok(encoded)
}

pub(crate) fn decode_generic_frame(encoded: &[u8]) -> Result<GenericInboundFrame, ConnectionError> {
    if encoded.len() < GENERIC_FRAME_HEADER_BYTES
        || &encoded[..4] != GENERIC_FRAME_MAGIC
        || u32::from_be_bytes(encoded[4..8].try_into().expect("version bytes"))
            != network_protocol::NETWORK_PROTOCOL_VERSION
    {
        return Err(ConnectionError::InvalidFrame);
    }
    let kind = GenericFrameKind::try_from(encoded[8])?;
    let payload_len = u32::from_be_bytes(encoded[9..13].try_into().expect("length bytes")) as usize;
    if payload_len == 0
        || payload_len + GENERIC_FRAME_HEADER_BYTES != encoded.len()
        || payload_len + GENERIC_FRAME_HEADER_BYTES > network_quic::MAX_CHANNEL_FRAME_BYTES
    {
        return Err(ConnectionError::FrameTooLarge);
    }
    Ok(GenericInboundFrame {
        kind,
        payload: encoded[GENERIC_FRAME_HEADER_BYTES..].to_vec(),
    })
}
