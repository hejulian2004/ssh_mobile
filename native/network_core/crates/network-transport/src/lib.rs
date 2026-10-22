//! Generic native transport primitives.
//!
//! The crate deliberately stops at transport semantics: TCP provides bounded
//! framed streams, UDP provides connected datagrams, and WebSocket provides
//! binary messages. Session identity, Delivery/Recovery, application E2EE, and
//! route selection remain owned by higher layers.
//!
//! [`Transport::into_split`] is available for every transport, including UDP.
//! UDP remains a datagram primitive only: it is not eligible for acknowledged,
//! ordered, or file-delivery (reliable-message) generic routes.

mod tcp;
mod udp;
mod websocket;

#[cfg(feature = "testkit")]
pub mod testkit;

pub use tcp::{TcpTransport, MAX_STREAM_FRAME_BYTES};
pub use udp::{UdpTransport, MAX_DATAGRAM_BYTES};
pub use websocket::{WebSocketTransport, MAX_WEBSOCKET_MESSAGE_BYTES};

use tcp::{TcpReader, TcpWriter};
use udp::{UdpReader, UdpWriter};
use websocket::{WebSocketReader, WebSocketWriter};

use std::net::SocketAddr;

/// Stable transport kind for diagnostics and route policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportKind {
    Tcp,
    Udp,
    WebSocket,
}

/// Errors shared by all generic transport implementations.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("transport is closed")]
    Closed,
    #[error("transport frame is too large")]
    FrameTooLarge,
    #[error("transport frame is invalid")]
    InvalidFrame,
    #[error("transport URL is invalid")]
    InvalidUrl,
    #[error("transport I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("transport WebSocket operation failed: {0}")]
    WebSocket(String),
}

/// A common native send/receive surface with per-transport framing semantics.
pub enum Transport {
    Tcp(TcpTransport),
    Udp(UdpTransport),
    WebSocket(Box<WebSocketTransport>),
    /// Test-only deterministic write gate. Compiled only with `testkit`.
    #[cfg(feature = "testkit")]
    Gated(Box<testkit::GatedTransport>),
}

enum TransportReaderKind {
    Tcp(TcpReader),
    Udp(UdpReader),
    WebSocket(WebSocketReader),
}

/// Read half of a generic transport. It owns no write-side state, so a
/// blocked writer cannot prevent the carrier from receiving ACK/Data frames.
pub struct TransportReader {
    inner: TransportReaderKind,
}

enum TransportWriterKind {
    Tcp(TcpWriter),
    Udp(UdpWriter),
    WebSocket(WebSocketWriter),
    #[cfg(feature = "testkit")]
    Gated(testkit::GatedWriter),
}

/// Write half of a generic transport. Dropping it cancels an in-flight write
/// by dropping the underlying Tokio/Futures I/O future and socket half.
pub struct TransportWriter {
    inner: TransportWriterKind,
}

impl Transport {
    /// Physical address metadata for IP transports; never creates a route.
    pub fn peer_address(&self) -> Option<SocketAddr> {
        match self {
            Self::Tcp(transport) => transport.peer_addr().ok(),
            Self::Udp(transport) => Some(transport.peer_addr()),
            Self::WebSocket(_) => None,
            #[cfg(feature = "testkit")]
            Self::Gated(_) => None,
        }
    }

    pub async fn connect_tcp(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        Ok(Self::Tcp(TcpTransport::connect(local, peer).await?))
    }

    pub async fn bind_udp(local: SocketAddr, peer: SocketAddr) -> Result<Self, TransportError> {
        Ok(Self::Udp(UdpTransport::bind(local, peer).await?))
    }

    pub async fn connect_websocket(url: &str) -> Result<Self, TransportError> {
        Ok(Self::WebSocket(Box::new(
            WebSocketTransport::connect(url).await?,
        )))
    }

    pub fn kind(&self) -> TransportKind {
        match self {
            Self::Tcp(_) => TransportKind::Tcp,
            Self::Udp(_) => TransportKind::Udp,
            Self::WebSocket(_) => TransportKind::WebSocket,
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.kind(),
        }
    }

    /// Wraps any transport writer with a deterministic write gate for tests.
    ///
    /// Compiled only with the `testkit` feature and never used in production.
    /// The returned transport keeps a real reader half and parks the first
    /// `send` on the supplied gate, so a test can prove an in-flight write does
    /// not stall the read half and that cancellation preempts it.
    #[cfg(feature = "testkit")]
    pub fn with_gated_writer(self, gate: testkit::WriterGate) -> Self {
        let kind = self.kind();
        let (reader, writer) = self.into_split();
        Self::Gated(Box::new(testkit::GatedTransport {
            kind,
            reader,
            writer: testkit::GatedWriter {
                inner: Box::new(writer.inner),
                gate,
            },
        }))
    }

    /// Splits the carrier into independently polled read and write halves.
    /// Framing and size limits remain identical to the unsplit surface.
    ///
    /// For UDP the two halves share the connected socket, so closing one half
    /// releases only that half's reference; the other half keeps delivering
    /// datagrams until it is dropped. UDP is a datagram primitive only and is
    /// not eligible for reliable-message generic routes.
    pub fn into_split(self) -> (TransportReader, TransportWriter) {
        match self {
            Self::Tcp(transport) => {
                let (reader, writer) = transport.into_split();
                (
                    TransportReader {
                        inner: TransportReaderKind::Tcp(reader),
                    },
                    TransportWriter {
                        inner: TransportWriterKind::Tcp(writer),
                    },
                )
            }
            Self::Udp(transport) => {
                let (reader, writer) = transport.into_split();
                (
                    TransportReader {
                        inner: TransportReaderKind::Udp(reader),
                    },
                    TransportWriter {
                        inner: TransportWriterKind::Udp(writer),
                    },
                )
            }
            Self::WebSocket(transport) => {
                let (reader, writer) = transport.into_split();
                (
                    TransportReader {
                        inner: TransportReaderKind::WebSocket(reader),
                    },
                    TransportWriter {
                        inner: TransportWriterKind::WebSocket(writer),
                    },
                )
            }
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.into_split(),
        }
    }

    /// Sends one logical payload using the selected transport's bounded frame.
    pub async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        match self {
            Self::Tcp(transport) => transport.send_frame(payload).await,
            Self::Udp(transport) => transport.send_datagram(payload).await,
            Self::WebSocket(transport) => transport.send_binary(payload).await,
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.send(payload).await,
        }
    }

    /// Receives one logical payload; UDP preserves datagram boundaries.
    pub async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        match self {
            Self::Tcp(transport) => transport.recv_frame().await,
            Self::Udp(transport) => transport.recv_datagram().await,
            Self::WebSocket(transport) => transport.recv_binary().await,
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.recv().await,
        }
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        match self {
            Self::Tcp(transport) => transport.close().await,
            Self::Udp(transport) => transport.close().await,
            Self::WebSocket(transport) => transport.close().await,
            #[cfg(feature = "testkit")]
            Self::Gated(transport) => transport.close().await,
        }
    }
}

impl TransportReader {
    pub async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        match &mut self.inner {
            TransportReaderKind::Tcp(reader) => reader.recv_frame().await,
            TransportReaderKind::Udp(reader) => reader.recv_datagram().await,
            TransportReaderKind::WebSocket(reader) => websocket::recv_binary(reader).await,
        }
    }
}

impl TransportWriter {
    pub async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        match &mut self.inner {
            TransportWriterKind::Tcp(writer) => writer.send_frame(payload).await,
            TransportWriterKind::Udp(writer) => writer.send_datagram(payload).await,
            TransportWriterKind::WebSocket(writer) => websocket::send_binary(writer, payload).await,
            #[cfg(feature = "testkit")]
            TransportWriterKind::Gated(writer) => writer.send(payload).await,
        }
    }

    pub async fn close(&mut self) -> Result<(), TransportError> {
        match &mut self.inner {
            TransportWriterKind::Tcp(writer) => writer.close().await,
            TransportWriterKind::Udp(writer) => writer.close().await,
            TransportWriterKind::WebSocket(writer) => websocket::close(writer).await,
            #[cfg(feature = "testkit")]
            TransportWriterKind::Gated(writer) => writer.close().await,
        }
    }
}

#[cfg(test)]
#[path = "tests/mod.rs"]
mod tests;
