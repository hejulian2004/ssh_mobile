use network_nat::{CandidateTransport, PathManager};
use quinn::{
    crypto::rustls::QuicClientConfig, ClientConfig, Endpoint, EndpointConfig, ServerConfig,
    TokioRuntime,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tracing::info;

pub const QUIC_ALPN_V2: &[&[u8]] = &[b"ssh-mobile/2"];

// Media may flow on WebRTC while this authenticated signaling carrier is quiet.
// Keep the finite idle timeout and let the business PathLease owner retire it.
const QUIC_KEEP_ALIVE_INTERVAL: Duration = Duration::from_secs(10);

/// A QUIC-bound UDP socket can advertise its QUIC and unreliable datagram
/// capabilities. It must not be inferred to support TCP or WebSocket merely
/// because it has a socket address.
pub const QUIC_CANDIDATE_TRANSPORTS: [CandidateTransport; 2] =
    [CandidateTransport::Quic, CandidateTransport::UdpDatagram];

pub struct QuicEndpointManager {
    pub endpoint: Endpoint,
    pub path_manager: Arc<PathManager>,
}

impl QuicEndpointManager {
    pub fn new(
        bind_addr: SocketAddr,
        path_manager: Arc<PathManager>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let socket = std::net::UdpSocket::bind(bind_addr)?;
        socket.set_nonblocking(true)?;
        Self::from_bound_socket(socket, path_manager)
    }

    /// Creates QUIC on a UDP socket that can first be used for STUN and
    /// candidate discovery, preserving the externally observed source port.
    pub fn from_bound_socket(
        socket: std::net::UdpSocket,
        path_manager: Arc<PathManager>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        // Tokio's `UdpSocket::from_std` requires a nonblocking descriptor. The
        // native runtime already supplies one after STUN/candidate gathering,
        // but this public constructor also accepts caller-owned sockets (and
        // tests commonly pass a freshly bound blocking socket).
        socket.set_nonblocking(true)?;
        let cert = rcgen::generate_simple_self_signed(vec!["ssh-mobile".to_string()])?;
        let cert_der = cert.cert.der().to_vec();
        let key_der = cert.key_pair.serialize_der();

        let mut server_crypto = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(cert_der)],
                PrivateKeyDer::Pkcs8(key_der.into()),
            )?;
        server_crypto.alpn_protocols = QUIC_ALPN_V2.iter().map(|s| s.to_vec()).collect();

        let mut transport = quinn::TransportConfig::default();
        transport.keep_alive_interval(Some(QUIC_KEEP_ALIVE_INTERVAL));
        let transport = Arc::new(transport);
        let mut server_config = ServerConfig::with_crypto(Arc::new(
            quinn::crypto::rustls::QuicServerConfig::try_from(server_crypto)?,
        ));
        server_config.transport_config(Arc::clone(&transport));
        let local_addr = socket.local_addr()?;
        let mut endpoint = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config),
            socket,
            Arc::new(TokioRuntime),
        )?;
        let mut client_crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(ApplicationIdentityVerifier::new())
            .with_no_client_auth();
        client_crypto.alpn_protocols = QUIC_ALPN_V2.iter().map(|s| s.to_vec()).collect();
        let mut client_config =
            ClientConfig::new(Arc::new(QuicClientConfig::try_from(client_crypto)?));
        client_config.transport_config(transport);
        endpoint.set_default_client_config(client_config);

        info!("QuicEndpointManager bound on {}", local_addr);

        Ok(Self {
            endpoint,
            path_manager,
        })
    }
}

/// QUIC uses ephemeral self-signed transport certificates. The certificate is
/// intentionally only a transport-encryption credential: authorization is
/// performed immediately afterwards by the pinned Ed25519 application
/// handshake, whose signatures are bound to this connection's TLS exporter.
/// No application stream is exposed before that handshake succeeds.
#[derive(Debug)]
struct ApplicationIdentityVerifier(Arc<rustls::crypto::CryptoProvider>);

impl ApplicationIdentityVerifier {
    fn new() -> Arc<Self> {
        Arc::new(Self(Arc::new(rustls::crypto::ring::default_provider())))
    }
}

impl rustls::client::danger::ServerCertVerifier for ApplicationIdentityVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            signature,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
#[path = "tests/endpoint.rs"]
mod tests;
