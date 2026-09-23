use std::sync::Arc;
use std::time::Instant;

use network_protocol::{
    DataMessage, NetworkError as ProtocolError, NetworkErrorCode, SendMessageCommand,
};
use network_quic::MAX_CHANNEL_FRAME_BYTES;
use prost::Message;

use crate::connect::{PathLease, CAPABILITY_RELIABLE_MESSAGE};
use crate::crypto;
use crate::delivery::{DeliveryError, DeliveryPolicy, PendingMessage, RecoverySnapshot};
use crate::errors::CoreNetworkError;
use crate::events::{protocol_error, protocol_error_with_peer};
use crate::runtime::{RuntimeState, DELIVERY_RETRY_POLL_INTERVAL};
use crate::session::SessionId;

use super::inbound::{decode_policy, delivery_error, policy_code};
use super::policy::{
    application_payload_mode, ensure_reliable_message_path, next_business_ensure_id,
    select_business_path_lease, validate_business_application_policy, ApplicationPayloadMode,
    MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES,
};

/// Send one already-encoded business frame while its path lease is active.
///
/// The runtime path adapter is used only after the lease has validated the
/// peer, capability, and path lifetime. Business code does not inspect a
/// SessionStore route, relay data slot, or stream carrier projection.
pub(crate) async fn send_business_frame(
    state: &RuntimeState,
    peer_id: &str,
    lease: &PathLease,
    relay_token: &str,
    kind: crate::connection::GenericFrameKind,
    payload: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let required_capability = match kind {
        crate::connection::GenericFrameKind::DataMessage
        | crate::connection::GenericFrameKind::DeliveryAck => {
            crate::connection::ConnectionCapability::ReliableMessage
        }
        crate::connection::GenericFrameKind::StreamOpen
        | crate::connection::GenericFrameKind::StreamBytes
        | crate::connection::GenericFrameKind::StreamClose => {
            crate::connection::ConnectionCapability::ReliableStream
        }
    };
    if lease.handle().peer_id().as_str() != peer_id
        || !lease.profile().supports(required_capability)
        || !lease.is_active()
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "business path lease is no longer active",
        )
        .into());
    }
    let result = state
        .path_send_channel_frame_for_lease(lease, relay_token, kind, payload)
        .await;
    if result.is_ok() && !lease.is_active() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "business path was lost during send",
        )
        .into());
    }
    result
}

/// 将 Dart/Protobuf 命令转换为 Delivery 消息并立即排入当前逻辑 Session。
pub(crate) async fn start_send_message(
    state: Arc<RuntimeState>,
    command: SendMessageCommand,
) -> Result<(), ProtocolError> {
    if command.peer_id.is_empty() || command.channel_id.is_empty() {
        return Err(protocol_error(
            NetworkErrorCode::InvalidArgument,
            "peer_id and channel_id are required",
        ));
    }
    if command.payload.len() > MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "message payload exceeds the channel frame limit",
            "send_message",
            &command.peer_id,
        ));
    }
    let policy = decode_policy(command.policy).ok_or_else(|| {
        protocol_error_with_peer(
            NetworkErrorCode::InvalidArgument,
            "unsupported Delivery policy",
            "send_message",
            &command.peer_id,
        )
    })?;
    let session_id = ensure_reliable_message_path(
        Arc::clone(&state),
        &command.peer_id,
        &next_business_ensure_id(&command.peer_id),
    )
    .await
    .map_err(|error| {
        let code = match error {
            CoreNetworkError::NoRoute => NetworkErrorCode::NoRoute,
            CoreNetworkError::Cancelled | CoreNetworkError::SupervisorStopping => {
                NetworkErrorCode::Cancelled
            }
            _ => NetworkErrorCode::Lifecycle,
        };
        protocol_error_with_peer(code, error.to_string(), "send_message", &command.peer_id)
    })?;
    validate_business_application_policy(&state, &command.peer_id, session_id).await?;
    // §20：投递状态按 Peer 业务作用域保存，绝不使用每连接的 SessionId。
    let message = state
        .delivery
        .enqueue(
            &command.peer_id,
            &command.channel_id,
            command.payload,
            policy,
            Default::default(),
        )
        .await
        .map_err(|error| delivery_error(&command.peer_id, error))?;
    ensure_retry_worker(Arc::clone(&state), command.peer_id.clone()).await;
    let supervisor = Arc::clone(&state.task_supervisor);
    if supervisor
        .spawn_runtime(
            "delivery-send",
            deliver_pending_message(state, command.peer_id.clone(), message),
        )
        .is_none()
    {
        return Err(protocol_error_with_peer(
            NetworkErrorCode::Cancelled,
            "network runtime is stopping",
            "send_message",
            &command.peer_id,
        ));
    }
    Ok(())
}

/// 在当前 Route 上发送一个已由 DeliveryManager 领取的消息。
///
/// 发送时解析**当前** ConnectionSession（wire 信封与加密上下文必须属于当前
/// connection；pending 消息在旧连接入队后，可能在新连接上以同一 MessageId
/// 重发）。
pub(super) async fn deliver_pending_message(
    state: Arc<RuntimeState>,
    peer_id: String,
    message: PendingMessage,
) {
    if message.policy == DeliveryPolicy::BestEffort {
        let session_id = match ensure_reliable_message_path(
            Arc::clone(&state),
            &peer_id,
            &format!(
                "delivery-best-effort/{}",
                hex::encode(message.message_id.to_bytes())
            ),
        )
        .await
        {
            Ok(session_id) => session_id,
            Err(error) => {
                tracing::debug!(peer_id = %peer_id, error = %error, "best-effort ensure failed");
                return;
            }
        };
        /*
         * The lease is intentionally acquired below and dropped after this
         * single send. Waiting for an application ACK never owns a lease.
         */
        let lease = match select_business_path_lease(&state, &peer_id, CAPABILITY_RELIABLE_MESSAGE)
            .await
        {
            Ok(lease) => lease,
            Err(error) => {
                tracing::debug!(peer_id = %peer_id, error = %error, "best-effort path lease unavailable");
                return;
            }
        };
        if let Err(error) = send_data_message(&state, &peer_id, session_id, &lease, &message).await
        {
            tracing::debug!(peer_id = %peer_id, error = %error, "best-effort channel message was not sent");
        }
        return;
    }

    let sendable = match state
        .delivery
        .begin_send_for_peer(&peer_id, message.message_id, Instant::now())
        .await
    {
        Ok(Some(attempt)) => attempt,
        Ok(None) | Err(DeliveryError::NotFound) => return,
        Err(error) => {
            if let Some(recovery) = error.recovery_error() {
                tracing::debug!(
                    peer_id = %peer_id,
                    ?recovery,
                    error = %error,
                    "delivery send attempt rejected"
                );
            }
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery message was not sendable");
            return;
        }
    };
    let message = &sendable.message;
    let session_id = match ensure_reliable_message_path(
        Arc::clone(&state),
        &peer_id,
        &format!("delivery/{}", hex::encode(message.message_id.to_bytes())),
    )
    .await
    {
        Ok(session_id) => session_id,
        Err(error) => {
            // 连接在领取与发送之间丢失：退回重试队列，等待下一次 ConnectionSession。
            let _ = state
                .delivery
                .mark_send_failed_for_attempt(&sendable, Instant::now())
                .await;
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery ensure failed");
            return;
        }
    };
    let lease = match select_business_path_lease(&state, &peer_id, CAPABILITY_RELIABLE_MESSAGE)
        .await
    {
        Ok(lease) => lease,
        Err(error) => {
            let _ = state
                .delivery
                .mark_send_failed_for_attempt(&sendable, Instant::now())
                .await;
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery path lease unavailable");
            return;
        }
    };
    let result = send_data_message(&state, &peer_id, session_id, &lease, message).await;
    match result {
        Ok(()) => {
            let _ = state
                .delivery
                .mark_sent_for_attempt(&sendable, Instant::now())
                .await;
        }
        Err(error) => {
            let decision = state
                .delivery
                .mark_send_failed_for_attempt(&sendable, Instant::now())
                .await;
            if let Some(recovery) = decision.recovery_error() {
                tracing::debug!(
                    peer_id = %peer_id,
                    ?recovery,
                    "delivery send failure classified"
                );
            }
            tracing::debug!(
                peer_id = %peer_id,
                session_id = %session_id.wire_key(),
                error = %error,
                "delivery message send failed and was returned to retry queue"
            );
        }
    }
}

/// 将一个 RecoverySnapshot 逐条重新编码并发送；Snapshot 不再被静默丢弃。
///
/// 恢复按 Peer 业务作用域进行（§20）：新 Connection Ready 后，该 Peer 所有未
/// ACK 的 pending 消息都会以**同一个 MessageId** 在**当前** transport 上重发，
/// 由对端按 MessageId 去重。
pub(crate) async fn recover_session(state: Arc<RuntimeState>, peer_id: String) {
    let snapshot = match state.delivery.recover_peer_checked(&peer_id).await {
        Ok(snapshot) => snapshot,
        Err(error) => {
            tracing::debug!(peer_id = %peer_id, error = %error, "delivery recovery rejected");
            return;
        }
    };
    ensure_retry_worker(Arc::clone(&state), peer_id.clone()).await;
    replay_snapshot(state, peer_id, snapshot).await;
}

async fn replay_snapshot(state: Arc<RuntimeState>, peer_id: String, snapshot: RecoverySnapshot) {
    for message in snapshot.messages {
        deliver_pending_message(Arc::clone(&state), peer_id.clone(), message).await;
    }
}

/// 每个 Peer 只运行一个重试循环；所有权（注册表）在 DeliveryManager 业务层，
/// key 是 Peer 业务作用域——**不是** ConnectionSession 的 SessionId。
///
/// worker 无连接时暂停（只是休眠轮询），新 ConnectionSession 出现后自动恢复，
/// 因此一次认领即可覆盖后续所有重连；transport 丢失不会取消它。
async fn ensure_retry_worker(state: Arc<RuntimeState>, peer_id: String) {
    if !state.delivery.try_start_retry_worker(&peer_id).await {
        return;
    }
    let retry_state = Arc::clone(&state);
    let retry_peer_id = peer_id.clone();
    let task_started = state
        .task_supervisor
        .spawn_runtime("delivery-retry", async move {
            loop {
                if retry_state
                    .connection_sessions
                    .current_session_id(&retry_peer_id)
                    .await
                    .is_some()
                {
                    let expired = retry_state
                        .delivery
                        .expire_incoming(&retry_peer_id, Instant::now())
                        .await;
                    if !expired.is_empty() {
                        let failed_ordered_channels = expired
                            .iter()
                            .filter(|timeout| timeout.ordered_channel_failed)
                            .count();
                        tracing::warn!(
                            peer_id = %retry_peer_id,
                            expired = expired.len(),
                            failed_ordered_channels,
                            "application delivery ACK timeout released receive state"
                        );
                    }
                    let retryable = match retry_state
                        .delivery
                        .retryable_messages_checked(&retry_peer_id, Instant::now())
                        .await
                    {
                        Ok(messages) => messages,
                        Err(error) => {
                            tracing::debug!(
                                peer_id = %retry_peer_id,
                                error = %error,
                                "delivery retry scan rejected"
                            );
                            Vec::new()
                        }
                    };
                    for message in retryable {
                        deliver_pending_message(
                            Arc::clone(&retry_state),
                            retry_peer_id.clone(),
                            message,
                        )
                        .await;
                    }
                }
                tokio::time::sleep(DELIVERY_RETRY_POLL_INTERVAL).await;
            }
        });
    if task_started.is_none() {
        state.delivery.stop_retry_worker(&peer_id).await;
    }
}

pub(super) async fn send_data_message(
    state: &RuntimeState,
    peer_id: &str,
    session_id: SessionId,
    lease: &PathLease,
    message: &PendingMessage,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // wire 信封与加密上下文必须使用当前 ConnectionSession（重放时 MessageId
    // 不变，但 SessionId / Noise root 已经换代）。
    if state.connection_sessions.current_session_id(peer_id).await != Some(session_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "connection session changed before delivery send",
        )
        .into());
    }
    let session_key = session_id.wire_key();
    let mut data = DataMessage {
        session_id: session_key.clone(),
        channel_id: message.channel_id.clone(),
        message_id: message.message_id.to_bytes().to_vec(),
        sequence: message.sequence,
        recovery_epoch: message.recovery_epoch,
        policy: policy_code(message.policy),
        payload: Vec::new(),
    };
    let aad = crypto::data_message_aad(
        &data.session_id,
        &data.channel_id,
        &data.message_id,
        data.sequence,
        data.recovery_epoch,
        data.policy,
    );
    let e2ee_policy = state.e2ee_policy(peer_id).await;
    let has_crypto_context = state.crypto_context(peer_id, &session_key).await.is_ok();
    let mode =
        application_payload_mode(e2ee_policy, lease.profile().topology(), has_crypto_context)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::PermissionDenied, error))?;
    data.payload = match mode {
        ApplicationPayloadMode::Encrypted => {
            state
                .encrypt_application_payload(peer_id, &session_key, &aad, &message.payload)
                .await?
        }
        ApplicationPayloadMode::Plaintext => message.payload.clone(),
    };
    let encoded = data.encode_to_vec();
    if encoded.len() > MAX_CHANNEL_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "encoded channel message exceeds frame limit",
        )
        .into());
    }
    if state.connection_sessions.current_session_id(peer_id).await != Some(session_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotConnected,
            "connection session changed during delivery encoding",
        )
        .into());
    }
    send_business_frame(
        state,
        peer_id,
        lease,
        &hex::encode(message.message_id.to_bytes()),
        crate::connection::GenericFrameKind::DataMessage,
        &encoded,
    )
    .await
}
