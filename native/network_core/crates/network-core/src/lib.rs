//! Network Protocol V2 原生网络运行时外观。
//!
//! 按职责拆分实现，使生命周期、命令分发、对端连接、传输、Relay 处理和
//! 线协议事件可以独立审查。

mod channel;
mod commands;
pub(crate) mod connect;
pub mod connection;
pub(crate) mod crypto;
mod crypto_handshake;
pub mod delivery;
mod discovery;
mod errors;
mod events;
mod generic_auth;
mod peer;
mod realtime;
mod realtime_media;
mod relay;
pub(crate) mod relay_state;
mod runtime;
mod runtime_event_lanes;
mod runtime_path_projections;
mod session;
mod stream;
mod task_supervisor;
mod transfer;

pub use errors::NetworkError;
pub use realtime_media::{RealtimeMediaDirection, RealtimeMediaEndpointId, RealtimeMediaError};
pub use runtime::NetworkRuntime;

#[cfg(test)]
mod tests;
