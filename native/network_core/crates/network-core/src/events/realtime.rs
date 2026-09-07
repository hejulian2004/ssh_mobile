//! WebRTC Realtime event construction.

use super::unix_timestamp_ms;
use crate::runtime::EventSender;
use network_protocol::{
    network_event, NetworkError as ProtocolError, NetworkEvent, RealtimeSignalEvent,
    RealtimeSnapshotEvent, RealtimeStateChangedEvent, NETWORK_PROTOCOL_VERSION,
};

/// 发布 WebRTC realtime Session 的状态变化，不改变普通 Data Route 的状态。
pub(crate) fn emit_realtime_state(
    event_tx: &EventSender,
    realtime_id: &str,
    peer_id: &str,
    state: i32,
    revision: u64,
    generation: u64,
    error: Option<ProtocolError>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("realtime/{realtime_id}/state/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RealtimeState(
            RealtimeStateChangedEvent {
                realtime_id: realtime_id.to_string(),
                peer_id: peer_id.to_string(),
                state,
                revision,
                error,
                generation,
            },
        )),
    });
}

/// 发布 WebRTC Offer/Answer/ICE 控制面消息，SDP 不进入文件数据面。
pub(crate) fn emit_realtime_signal(
    event_tx: &EventSender,
    realtime_id: &str,
    peer_id: &str,
    kind: i32,
    revision: u64,
    payload: Vec<u8>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("realtime/{realtime_id}/signal/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RealtimeSignal(
            RealtimeSignalEvent {
                realtime_id: realtime_id.to_string(),
                peer_id: peer_id.to_string(),
                kind,
                revision,
                payload,
            },
        )),
    });
}

/// 发布 Realtime Session 稳定后的完整状态快照。该事件在对应的状态 delta 之后
/// 发布，携带 RealtimeManager 中权威的 `session_id`/`peer_id`/`revision`。
pub(crate) fn emit_realtime_snapshot(
    event_tx: &EventSender,
    realtime_id: &str,
    peer_id: &str,
    state: i32,
    revision: u64,
    generation: u64,
    error: Option<ProtocolError>,
) {
    let _ = event_tx.send(NetworkEvent {
        event_id: format!("realtime/{realtime_id}/snapshot/{}", unix_timestamp_ms()),
        timestamp_ms: unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::RealtimeSnapshot(
            RealtimeSnapshotEvent {
                realtime_id: realtime_id.to_string(),
                peer_id: peer_id.to_string(),
                state,
                revision,
                error,
                generation,
            },
        )),
    });
}
