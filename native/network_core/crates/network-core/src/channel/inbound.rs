use std::time::Instant;

use network_protocol::{
    network_event, AcknowledgeMessageCommand, ChannelMessageEvent, DataMessage, DeliveryAck,
    DeliveryAckedEvent, DeliveryPolicyCode, NetworkError as ProtocolError, NetworkErrorCode,
    NetworkEvent, NETWORK_PROTOCOL_VERSION,
};
use prost::Message;

use crate::connect::CAPABILITY_RELIABLE_MESSAGE;
use crate::connection::RouteTopology;
use crate::crypto;
use crate::delivery::{
    AckResult, DedupDecision, DeliveryError, DeliveryPolicy, OrderedInsertResult, OrderedMessage,
};
use crate::events::{protocol_error, protocol_error_with_peer};
use crate::runtime::RuntimeState;

use super::policy::{
    application_payload_mode, select_business_path_lease, ApplicationPayloadMode,
    MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES,
};
use super::send::send_business_frame;

/// 处理 Dart 对已交付消息的 ACK，并把 ACK 发送到当前 Route。
pub(crate) async fn acknowledge_message(
    state: &RuntimeState,
    command: AcknowledgeMessageCommand,
) -> Result<(), ProtocolError> {
    let message_id: [u8; 16] = command.message_id.try_into().map_err(|_| {
        protocol_error(
            NetworkErrorCode::InvalidArgument,
            "message_id must contain 16 bytes",
        )
    })?;
    if command.peer_id.is_empty() || command.session_id.is_empty() || command.channel_id.is_empty()
    {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id, session_id, and channel_id are required",
        ));
    }
    // 应用 ACK 的关联 key 是 Peer + Channel + MessageId（§20）。`command.session_id`
    // 只是事件里携带的 wire SessionId，仅用于回显，不参与关联。
    let completion = match state
        .delivery
        .complete_incoming_checked(
            &command.peer_id,
            &command.channel_id,
            crate::delivery::MessageId::from_bytes(message_id),
        )
        .await
    {
        Ok(Some(completion)) => completion,
        Ok(None) => {
            return Err(protocol_error_with_peer(
                NetworkErrorCode::InvalidArgument,
                "message is not awaiting acknowledgement",
                "acknowledge_message",
                &command.peer_id,
            ));
        }
        Err(error) => return Err(delivery_error(&command.peer_id, error)),
    };
    let ack = DeliveryAck {
        session_id: command.session_id,
        message_id: message_id.to_vec(),
        recovery_epoch: completion.recovery_epoch,
    };
    if let Some(next) = completion.next_ordered {
        // The application ACK is the ordering gate. The next buffered message
        // is published even if this transport ACK needs a later retry.
        emit_ordered_message(state, next);
    }
    let result = send_delivery_ack(state, &command.peer_id, &ack).await;
    result.map_err(|error| {
        protocol_error_with_peer(
            NetworkErrorCode::NoRoute,
            error.to_string(),
            "acknowledge_message",
            &command.peer_id,
        )
    })
}

async fn send_delivery_ack(
    state: &RuntimeState,
    peer_id: &str,
    ack: &DeliveryAck,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let encoded = ack.encode_to_vec();
    let _message_id: [u8; 16] = ack
        .message_id
        .as_slice()
        .try_into()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid ACK ID"))?;
    let lease = select_business_path_lease(state, peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
        .map_err(|error| {
            std::io::Error::new(std::io::ErrorKind::NotConnected, error.to_string())
        })?;
    send_business_frame(
        state,
        peer_id,
        &lease,
        &hex::encode(_message_id),
        crate::connection::GenericFrameKind::DeliveryAck,
        &encoded,
    )
    .await
}

/// 处理 QUIC/Relay 到达的 DataMessage；只有 New 消息才进入应用事件流。
pub(crate) async fn handle_data_message(
    state: &RuntimeState,
    peer_id: &str,
    encoded: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut message = DataMessage::decode(encoded)?;
    validate_data_message(&message)?;
    let policy = decode_policy(message.policy).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid Delivery policy")
    })?;
    let aad = crypto::data_message_aad(
        &message.session_id,
        &message.channel_id,
        &message.message_id,
        message.sequence,
        message.recovery_epoch,
        message.policy,
    );
    let e2ee_policy = state.e2ee_policy(peer_id).await;
    let has_crypto_context = state
        .crypto_context(peer_id, &message.session_id)
        .await
        .is_ok();
    let mode = application_payload_mode(
        e2ee_policy,
        state
            .path_profile(peer_id)
            .await
            .map(|profile| profile.topology())
            .unwrap_or(RouteTopology::Direct),
        has_crypto_context,
    )
    .map_err(|error| std::io::Error::new(std::io::ErrorKind::PermissionDenied, error))?;
    message.payload = match mode {
        ApplicationPayloadMode::Encrypted => {
            if !crypto::is_application_envelope(&message.payload) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "required application E2EE payload is missing",
                )
                .into());
            }
            if policy == DeliveryPolicy::BestEffort {
                state
                    .decrypt_application_payload(
                        peer_id,
                        &message.session_id,
                        &aad,
                        &message.payload,
                    )
                    .await?
            } else {
                state
                    .decrypt_application_payload_for_delivery(
                        peer_id,
                        &message.session_id,
                        &aad,
                        &message.payload,
                    )
                    .await?
            }
        }
        ApplicationPayloadMode::Plaintext => {
            if crypto::is_application_envelope(&message.payload) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "disabled application E2EE policy received ciphertext",
                )
                .into());
            }
            message.payload
        }
    };
    let message_id: [u8; 16] =
        message.message_id.as_slice().try_into().map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid message ID")
        })?;
    let incoming = OrderedMessage {
        peer_id: peer_id.to_string(),
        session_id: message.session_id.clone(),
        channel_id: message.channel_id.clone(),
        message_id: crate::delivery::MessageId::from_bytes(message_id),
        sequence: message.sequence,
        policy,
        payload: message.payload.clone(),
    };
    if message.policy != DeliveryPolicyCode::BestEffort as i32 {
        match state
            .delivery
            .begin_incoming_checked(
                peer_id,
                &message.channel_id,
                crate::delivery::MessageId::from_bytes(message_id),
                message.recovery_epoch,
                Instant::now(),
            )
            .await?
        {
            DedupDecision::DuplicateInFlight => {
                // 首次事件已经交给本地应用，但应用还没有 ACK；后续重传
                // 只能保持 InFlight，不能再次进入业务 handler 或发送 ACK。
                return Ok(());
            }
            DedupDecision::DuplicateProcessed => {
                // 应用已经完成首次处理；后续重传可以安全地用当前 epoch
                // 重发 ACK，但绝不能再次进入业务 handler。
                let Some(recovery_epoch) = state
                    .delivery
                    .incoming_recovery_epoch(
                        peer_id,
                        &message.channel_id,
                        crate::delivery::MessageId::from_bytes(message_id),
                    )
                    .await
                else {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "processed message lost its dedup record",
                    )
                    .into());
                };
                let ack = DeliveryAck {
                    session_id: message.session_id.clone(),
                    message_id: message_id.to_vec(),
                    recovery_epoch,
                };
                send_delivery_ack(state, peer_id, &ack).await?;
                return Ok(());
            }
            DedupDecision::CapacityExceeded => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "active delivery handler capacity exceeded",
                )
                .into());
            }
            DedupDecision::ChannelFailed => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "ordered delivery channel failed after application ACK timeout",
                )
                .into());
            }
            DedupDecision::New => {
                if policy == DeliveryPolicy::SessionBoundOrdered {
                    match state.delivery.accept_ordered(incoming.clone()).await {
                        OrderedInsertResult::Ready => {}
                        OrderedInsertResult::Buffered => return Ok(()),
                        OrderedInsertResult::Duplicate => {
                            let _ = state
                                .delivery
                                .reject_incoming(
                                    peer_id,
                                    &message.channel_id,
                                    crate::delivery::MessageId::from_bytes(message_id),
                                )
                                .await;
                            return Ok(());
                        }
                        OrderedInsertResult::Rejected => {
                            let _ = state
                                .delivery
                                .reject_incoming(
                                    peer_id,
                                    &message.channel_id,
                                    crate::delivery::MessageId::from_bytes(message_id),
                                )
                                .await;
                            return Err(std::io::Error::new(
                                std::io::ErrorKind::InvalidData,
                                "ordered message exceeds reorder limits",
                            )
                            .into());
                        }
                    }
                }
            }
        }
    }
    emit_ordered_message(state, incoming);
    Ok(())
}

fn emit_ordered_message(state: &RuntimeState, message: OrderedMessage) {
    let _ = state.event_tx.send(NetworkEvent {
        event_id: format!(
            "{}/channel/{}/{}/{}",
            message.peer_id,
            message.session_id,
            message.channel_id,
            hex::encode(message.message_id.to_bytes())
        ),
        timestamp_ms: crate::events::unix_timestamp_ms(),
        protocol_version: NETWORK_PROTOCOL_VERSION,
        payload: Some(network_event::Payload::ChannelMessage(
            ChannelMessageEvent {
                peer_id: message.peer_id,
                session_id: message.session_id,
                channel_id: message.channel_id,
                message_id: message.message_id.to_bytes().to_vec(),
                sequence: message.sequence,
                policy: policy_code(message.policy),
                payload: message.payload,
            },
        )),
    });
}

/// 处理传输层收到的 ACK。ACK 按 **MessageId** 关联（§20）：
/// 只要该 MessageId 仍在 pending 中即完成；已完成消息的重复 ACK 是 no-op。
/// `ack.session_id` / `ack.recovery_epoch` 只用于事件回显，不参与关联门控。
pub(crate) async fn handle_delivery_ack(
    state: &RuntimeState,
    peer_id: &str,
    encoded: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let ack = DeliveryAck::decode(encoded)?;
    if ack.session_id.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "DeliveryAck session_id is required",
        )
        .into());
    }
    let message_id: [u8; 16] = ack
        .message_id
        .as_slice()
        .try_into()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid ACK ID"))?;
    if state
        .delivery
        .acknowledge(peer_id, crate::delivery::MessageId::from_bytes(message_id))
        .await
        == AckResult::Acknowledged
    {
        let _ = state.event_tx.send(NetworkEvent {
            event_id: format!(
                "{peer_id}/delivery-ack/{}/{}",
                ack.session_id,
                hex::encode(message_id)
            ),
            timestamp_ms: crate::events::unix_timestamp_ms(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_event::Payload::DeliveryAcked(DeliveryAckedEvent {
                peer_id: peer_id.to_string(),
                session_id: ack.session_id,
                message_id: message_id.to_vec(),
                recovery_epoch: ack.recovery_epoch,
            })),
        });
    }
    Ok(())
}

pub(super) fn validate_data_message(
    message: &DataMessage,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if message.session_id.is_empty()
        || message.session_id.len() > 128
        || message.channel_id.is_empty()
        || message.channel_id.len() > 128
        || message.message_id.len() != 16
        || message.payload.len() > MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES
        || DeliveryPolicyCode::try_from(message.policy).is_err()
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "invalid DataMessage envelope",
        )
        .into());
    }
    Ok(())
}

pub(super) fn decode_policy(value: i32) -> Option<DeliveryPolicy> {
    match DeliveryPolicyCode::try_from(value).ok()? {
        DeliveryPolicyCode::BestEffort => Some(DeliveryPolicy::BestEffort),
        DeliveryPolicyCode::LatestState => Some(DeliveryPolicy::LatestState),
        DeliveryPolicyCode::Acked => Some(DeliveryPolicy::Acked),
        DeliveryPolicyCode::AckedDeduplicated => Some(DeliveryPolicy::AckedDeduplicated),
        DeliveryPolicyCode::SessionBoundOrdered => Some(DeliveryPolicy::SessionBoundOrdered),
        DeliveryPolicyCode::ResumableTransfer => Some(DeliveryPolicy::ResumableTransfer),
    }
}

pub(super) fn policy_code(policy: DeliveryPolicy) -> i32 {
    match policy {
        DeliveryPolicy::BestEffort => DeliveryPolicyCode::BestEffort as i32,
        DeliveryPolicy::LatestState => DeliveryPolicyCode::LatestState as i32,
        DeliveryPolicy::Acked => DeliveryPolicyCode::Acked as i32,
        DeliveryPolicy::AckedDeduplicated => DeliveryPolicyCode::AckedDeduplicated as i32,
        DeliveryPolicy::SessionBoundOrdered => DeliveryPolicyCode::SessionBoundOrdered as i32,
        DeliveryPolicy::ResumableTransfer => DeliveryPolicyCode::ResumableTransfer as i32,
    }
}

pub(super) fn delivery_error(peer_id: &str, error: DeliveryError) -> ProtocolError {
    let code = match error {
        DeliveryError::QueueFull | DeliveryError::PayloadTooLarge => {
            NetworkErrorCode::InvalidArgument
        }
        DeliveryError::InvalidScope | DeliveryError::InvalidRetryPolicy => {
            NetworkErrorCode::InvalidArgument
        }
        DeliveryError::NotFound | DeliveryError::Expired | DeliveryError::RetryExhausted => {
            NetworkErrorCode::IoError
        }
    };
    protocol_error_with_peer(code, error.to_string(), "send_message", peer_id)
}
