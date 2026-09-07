//! Runtime-owned WebRTC network I/O.
//!
//! `rtc` is deliberately sans-I/O.  This module is the sole adapter that
//! binds a UDP socket, forwards datagrams into the peer, drives timers, and
//! exposes data-channel events to the owning runtime.  It keeps socket and
//! peer ownership together so a cancelled runtime task drops both resources.

use crate::{IceCandidate, WebRtcError, WebRtcPeer};
use bytes::BytesMut;
use rtc::data_channel::RTCDataChannelId;
use rtc::peer_connection::event::{RTCDataChannelEvent, RTCPeerConnectionEvent};
use rtc::peer_connection::message::RTCMessage;
use rtc::peer_connection::state::{RTCIceConnectionState, RTCPeerConnectionState};
use rtc::shared::{TaggedBytesMut, TransportContext, TransportProtocol};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::mpsc::Sender;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_UDP_DATAGRAM_BYTES: usize = 64 * 1024;
const HOST_CANDIDATE_PRIORITY: u32 = 2_130_706_431;
pub const REALTIME_IO_EVENT_CAPACITY: usize = 256;

/// Events emitted by the real-time I/O loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RealtimeIoEvent {
    /// The ICE connectivity check reached a usable state.
    IceConnected,
    /// ICE failed and no candidate pair is usable.
    IceFailed,
    /// The DTLS/SCTP peer connection is ready.
    PeerConnected,
    /// The DTLS/SCTP peer connection was disconnected.
    PeerDisconnected,
    /// The DTLS/SCTP peer connection failed permanently.
    PeerFailed,
    /// A data channel became writable.
    DataChannelOpened(RTCDataChannelId),
    /// A data channel closed.
    DataChannelClosed(RTCDataChannelId),
    /// A candidate discovered by STUN/TURN that must be sent through the
    /// existing signaling channel.
    LocalIceCandidate(IceCandidate),
    /// An application data-channel message.
    DataChannelMessage {
        channel_id: RTCDataChannelId,
        is_string: bool,
        payload: Vec<u8>,
    },
}

/// A WebRTC peer plus the UDP socket that carries its ICE/DTLS/SRTP/SCTP
/// packets.  The peer is never driven without this owner.
pub struct RealtimeIoDriver {
    peer: WebRtcPeer,
    socket: Arc<UdpSocket>,
    local_addr: SocketAddr,
}

/// Shared owner handle used by Runtime signal handling and the I/O task.  The
/// lock is held only while calling synchronous sans-I/O methods; no await is
/// performed while it is held.
pub type RealtimeIoDriverHandle = Arc<Mutex<RealtimeIoDriver>>;

impl RealtimeIoDriver {
    /// Bind a UDP socket and register its host candidate before SDP creation.
    /// A concrete bind address is recommended for deterministic candidate
    /// advertisement; unspecified binds advertise loopback as a safe local
    /// fallback and can be overridden with [`Self::bind_with_advertised_ip`].
    pub async fn bind(peer: WebRtcPeer, bind_addr: SocketAddr) -> Result<Self, WebRtcError> {
        Self::bind_with_advertised_ip(peer, bind_addr, None).await
    }

    /// Bind a UDP socket and advertise an explicit host IP in its ICE
    /// candidate.  This is used by the Runtime when the socket binds to
    /// `0.0.0.0` or `::` for LAN reachability.
    pub async fn bind_with_advertised_ip(
        mut peer: WebRtcPeer,
        bind_addr: SocketAddr,
        advertised_ip: Option<IpAddr>,
    ) -> Result<Self, WebRtcError> {
        let socket = UdpSocket::bind(bind_addr)
            .await
            .map_err(|error| WebRtcError::Io(error.to_string()))?;
        let local_addr = socket
            .local_addr()
            .map_err(|error| WebRtcError::Io(error.to_string()))?;
        let candidate_ip = advertised_ip
            .or_else(|| (!local_addr.ip().is_unspecified()).then_some(local_addr.ip()))
            .unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST));
        let candidate = host_candidate(candidate_ip, local_addr.port());
        peer.add_local_ice_candidate(IceCandidate::new(
            candidate,
            Some("0".to_owned()),
            Some(0),
            None,
        )?)?;
        Ok(Self {
            peer,
            socket: Arc::new(socket),
            local_addr,
        })
    }

    /// Convert this driver into the shared owner used by the runtime task.
    pub fn into_handle(self) -> RealtimeIoDriverHandle {
        Arc::new(Mutex::new(self))
    }

    /// Address of the bound UDP socket.
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Access the peer for SDP negotiation or an application send operation.
    /// Callers must not hold the returned borrow across an await.
    pub fn peer_mut(&mut self) -> &mut WebRtcPeer {
        &mut self.peer
    }

    /// Close the peer while retaining the driver owner for deterministic
    /// shutdown tests.
    pub fn close(&mut self) -> Result<(), WebRtcError> {
        self.peer.close()
    }

    fn socket(&self) -> Arc<UdpSocket> {
        Arc::clone(&self.socket)
    }

    fn local_addr_value(&self) -> SocketAddr {
        self.local_addr
    }
}

/// Drive one WebRTC peer until the task is cancelled, its event receiver is
/// closed, or the peer reports a fatal I/O error.
pub async fn run_realtime_io(
    handle: RealtimeIoDriverHandle,
    events: Sender<RealtimeIoEvent>,
) -> Result<(), WebRtcError> {
    let mut receive_buffer = vec![0u8; MAX_UDP_DATAGRAM_BYTES];
    loop {
        let (socket, local_addr, outbound, timeout, pending_events) = {
            let mut driver = lock_driver(&handle)?;
            let socket = driver.socket();
            let local_addr = driver.local_addr_value();
            let now = Instant::now();
            // Encoded screen frames are drained directly into the sole native
            // RTP sender before network packets are collected. They never use
            // the DataChannel or this runtime event channel.
            driver.peer.flush_pending_h264_screen_video(now)?;
            let mut outbound = Vec::new();
            while let Some(packet) = driver.peer.poll_network_packet() {
                if packet.transport.transport_protocol != TransportProtocol::UDP {
                    return Err(WebRtcError::Io(
                        "WebRTC driver received a non-UDP packet from rtc".to_owned(),
                    ));
                }
                outbound.push((packet.transport.peer_addr, packet.message.to_vec()));
            }
            let mut pending_events = Vec::new();
            while let Some(event) = driver.peer.poll_event() {
                driver.peer.observe_screen_video_event(&event);
                for mapped in map_peer_event(event)? {
                    apply_terminal_media_policy(driver.peer_mut(), &mapped);
                    pending_events.push(mapped);
                }
            }
            while let Some(message) = driver.peer.poll_message() {
                match message {
                    RTCMessage::DataChannelMessage(channel_id, message) => {
                        pending_events.push(RealtimeIoEvent::DataChannelMessage {
                            channel_id,
                            is_string: message.is_string,
                            payload: message.data.to_vec(),
                        });
                    }
                    RTCMessage::RtpPacket(track_id, packet) => {
                        driver
                            .peer
                            .receive_h264_screen_video_rtp_for_track(&track_id, &packet, now)?;
                    }
                    _ => {}
                }
            }
            let timeout = driver.peer.poll_timeout();
            (socket, local_addr, outbound, timeout, pending_events)
        };

        for (peer_addr, payload) in outbound {
            socket
                .send_to(&payload, peer_addr)
                .await
                .map_err(|error| WebRtcError::Io(error.to_string()))?;
        }
        for event in pending_events {
            if events.send(event).await.is_err() {
                return Ok(());
            }
        }

        let deadline = timeout.unwrap_or_else(|| Instant::now() + DEFAULT_TIMEOUT);
        let delay = deadline.saturating_duration_since(Instant::now());
        if delay.is_zero() {
            handle_timeout(&handle, Instant::now())?;
            continue;
        }

        let timer = tokio::time::sleep(delay);
        tokio::pin!(timer);
        tokio::select! {
            _ = &mut timer => {
                handle_timeout(&handle, Instant::now())?;
            }
            result = socket.recv_from(&mut receive_buffer) => {
                let (bytes_read, peer_addr) = result
                    .map_err(|error| WebRtcError::Io(error.to_string()))?;
                let packet = TaggedBytesMut {
                    now: Instant::now(),
                    transport: TransportContext {
                        local_addr,
                        peer_addr,
                        ecn: None,
                        transport_protocol: TransportProtocol::UDP,
                    },
                    message: BytesMut::from(&receive_buffer[..bytes_read]),
                };
                let mut driver = lock_driver(&handle)?;
                driver.peer.handle_network_packet(packet)?;
            }
        }
    }
}

fn lock_driver(
    handle: &RealtimeIoDriverHandle,
) -> Result<MutexGuard<'_, RealtimeIoDriver>, WebRtcError> {
    handle
        .lock()
        .map_err(|_| WebRtcError::Io("WebRTC I/O driver mutex was poisoned".to_owned()))
}

fn handle_timeout(handle: &RealtimeIoDriverHandle, now: Instant) -> Result<(), WebRtcError> {
    let mut driver = lock_driver(handle)?;
    driver.peer.handle_timeout(now)
}

fn map_peer_event(event: RTCPeerConnectionEvent) -> Result<Vec<RealtimeIoEvent>, WebRtcError> {
    let mut mapped = Vec::new();
    match event {
        RTCPeerConnectionEvent::OnIceCandidateEvent(event) => {
            let candidate = event.candidate.to_json().map_err(|error| {
                WebRtcError::Rtc(format!("failed to serialize local ICE candidate: {error}"))
            })?;
            mapped.push(RealtimeIoEvent::LocalIceCandidate(IceCandidate::new(
                candidate.candidate,
                candidate.sdp_mid,
                candidate.sdp_mline_index,
                candidate.username_fragment,
            )?));
        }
        RTCPeerConnectionEvent::OnIceConnectionStateChangeEvent(state) => match state {
            RTCIceConnectionState::Connected | RTCIceConnectionState::Completed => {
                mapped.push(RealtimeIoEvent::IceConnected)
            }
            RTCIceConnectionState::Failed => mapped.push(RealtimeIoEvent::IceFailed),
            _ => {}
        },
        RTCPeerConnectionEvent::OnConnectionStateChangeEvent(state) => match state {
            RTCPeerConnectionState::Connected => mapped.push(RealtimeIoEvent::PeerConnected),
            RTCPeerConnectionState::Disconnected | RTCPeerConnectionState::Closed => {
                mapped.push(RealtimeIoEvent::PeerDisconnected)
            }
            RTCPeerConnectionState::Failed => mapped.push(RealtimeIoEvent::PeerFailed),
            _ => {}
        },
        RTCPeerConnectionEvent::OnDataChannel(event) => match event {
            RTCDataChannelEvent::OnOpen(channel_id) => {
                mapped.push(RealtimeIoEvent::DataChannelOpened(channel_id))
            }
            RTCDataChannelEvent::OnClose(channel_id) => {
                mapped.push(RealtimeIoEvent::DataChannelClosed(channel_id))
            }
            _ => {}
        },
        _ => {}
    }
    Ok(mapped)
}

fn apply_terminal_media_policy(peer: &mut WebRtcPeer, event: &RealtimeIoEvent) {
    if matches!(
        event,
        RealtimeIoEvent::IceFailed
            | RealtimeIoEvent::PeerDisconnected
            | RealtimeIoEvent::PeerFailed
    ) {
        peer.on_connection_lost();
    }
}

fn host_candidate(ip: IpAddr, port: u16) -> String {
    format!("candidate:1 1 udp {HOST_CANDIDATE_PRIORITY} {ip} {port} typ host")
}

#[cfg(test)]
#[path = "tests/driver.rs"]
mod tests;
