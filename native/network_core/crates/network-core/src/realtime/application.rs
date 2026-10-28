//! Opaque application bytes on the session DataChannel.
//!
//! Screen-share marks travel here. This module checks identity and size only.

use super::*;
use crate::events::{
    emit_realtime_application_channel, emit_realtime_application_data, protocol_error,
    RealtimeSessionIdentity,
};
use crate::runtime::RuntimeState;
use network_protocol::SendRealtimeApplicationDataCommand;
use network_webrtc::RealtimeIoEvent;

pub(crate) const MAX_REALTIME_APPLICATION_DATA_BYTES: usize = 4 * 1024;

pub(crate) async fn send_application_data(
    state: &RuntimeState,
    command: SendRealtimeApplicationDataCommand,
) -> Result<(), network_protocol::NetworkError> {
    validate_realtime_id(&command.realtime_id)?;
    if command.generation == 0 {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "realtime generation must be positive",
        ));
    }
    if command.payload.is_empty() || command.payload.len() > MAX_REALTIME_APPLICATION_DATA_BYTES {
        return Err(protocol_error(
            network_protocol::NetworkErrorCode::InvalidArgument,
            "application payload must contain 1-4096 bytes",
        ));
    }
    let driver = {
        let sessions = state.realtime.lock().await;
        let generation = sessions
            .session_generation(&command.realtime_id)
            .unwrap_or_default();
        if generation != command.generation {
            return Err(realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "realtime generation does not match",
                "send_realtime_application_data",
                "",
            ));
        }
        let session = sessions.sessions.get(&command.realtime_id).ok_or_else(|| {
            realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "realtime session does not exist",
                "send_realtime_application_data",
                "",
            )
        })?;
        session.driver.clone().ok_or_else(|| {
            realtime_error(
                network_protocol::NetworkErrorCode::InvalidArgument,
                "realtime session has no data channel owner",
                "send_realtime_application_data",
                &session.peer_id,
            )
        })?
    };
    let mut driver = driver.lock().map_err(|_| {
        realtime_error(
            network_protocol::NetworkErrorCode::IoError,
            "realtime I/O driver mutex was poisoned",
            "send_realtime_application_data",
            "",
        )
    })?;
    driver
        .send_application_data(&command.payload)
        .map_err(|error| {
            realtime_error(
                network_protocol::NetworkErrorCode::IoError,
                error.to_string(),
                "send_realtime_application_data",
                "",
            )
        })
}

pub(crate) async fn forward_data_channel_message(
    state: &RuntimeState,
    realtime_id: &str,
    peer_id: &str,
    event: RealtimeIoEvent,
) {
    let sessions = state.realtime.lock().await;
    let Some(session) = sessions.sessions.get(realtime_id) else {
        return;
    };
    if session.peer_id != peer_id {
        return;
    }
    let generation = sessions.session_generation(realtime_id).unwrap_or_default();
    if generation == 0 || session.shared_session_instance_id.is_empty() {
        return;
    }
    let identity = RealtimeSessionIdentity::new(generation, &session.shared_session_instance_id);
    match event {
        RealtimeIoEvent::DataChannelOpened(_) => {
            emit_realtime_application_channel(
                &state.event_tx,
                realtime_id,
                peer_id,
                identity,
                true,
            );
        }
        RealtimeIoEvent::DataChannelClosed(_) => {
            emit_realtime_application_channel(
                &state.event_tx,
                realtime_id,
                peer_id,
                identity,
                false,
            );
        }
        RealtimeIoEvent::DataChannelMessage {
            is_string, payload, ..
        } => {
            if is_string
                || payload.is_empty()
                || payload.len() > MAX_REALTIME_APPLICATION_DATA_BYTES
            {
                return;
            }
            emit_realtime_application_data(
                &state.event_tx,
                realtime_id,
                peer_id,
                identity,
                payload,
            );
        }
        _ => {}
    }
}
