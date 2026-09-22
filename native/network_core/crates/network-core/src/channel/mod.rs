//! Delivery Manager 与当前 Route 的生产接线。
//!
//! Delivery 只保存可重编码的应用消息；本模块负责在 Connection Ready、
//! ACK、重连和 Route 变化时把同一份 DataMessage 发送到当前 QUIC 或 Relay。
//! 所有发送都以逻辑 SessionId 为边界，不把 MessageId、Sequence 或
//! RecoveryEpoch 存进具体 Connection。

mod inbound;
mod policy;
mod send;

pub(crate) use inbound::{acknowledge_message, handle_data_message, handle_delivery_ack};
pub(crate) use policy::select_business_path_lease;
pub(crate) use send::{recover_session, send_business_frame, start_send_message};

#[cfg(test)]
use inbound::{decode_policy, delivery_error, policy_code, validate_data_message};
#[cfg(test)]
use policy::{
    application_payload_mode, ensure_reliable_message_path, next_business_ensure_id,
    validate_business_application_policy, ApplicationPayloadMode, ApplicationPolicyError,
    MAX_DELIVERY_MESSAGE_PAYLOAD_BYTES,
};
#[cfg(test)]
use send::{deliver_pending_message, send_data_message};

#[cfg(test)]
#[path = "../tests/channel.rs"]
mod tests;
