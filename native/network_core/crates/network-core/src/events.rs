//! Network Protocol V2 typed event construction and protocol error mapping.
//!
//! Event families live in focused modules; these re-exports keep the native
//! runtime's existing crate-private event API stable.

mod command;
mod error;
mod peer;
mod realtime;
mod relay_presence;
mod route;
mod stream;
mod transfer;

pub(crate) use command::emit_command_result;
pub(crate) use error::{
    protocol_error, protocol_error_with_context, protocol_error_with_peer,
    protocol_error_with_retry,
};
pub(crate) use peer::{
    emit_network_environment_changed, emit_peer_diagnostics, emit_peer_lifecycle, emit_peer_state,
    emit_peer_state_profile,
};
pub(crate) use realtime::{
    emit_realtime_incoming_session_offer, emit_realtime_signal, emit_realtime_snapshot,
    emit_realtime_state, RealtimeIncomingSessionOfferMetadata, RealtimeSessionIdentity,
};
pub(crate) use relay_presence::{
    emit_peer_presence_changed, emit_peer_presence_snapshot, emit_relay_state,
};
pub(crate) use route::{
    emit_route_attempt_changed, emit_route_changed, emit_route_changed_profile,
    protocol_route_metadata,
};
pub(crate) use stream::{emit_stream_closed, emit_stream_data_received};
pub(crate) use transfer::{
    emit_incoming_offer, emit_transfer_completed, emit_transfer_error, emit_transfer_progress,
    emit_transfer_progress_for_peer,
};

pub(crate) fn unix_timestamp_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
#[path = "tests/events.rs"]
mod tests;
