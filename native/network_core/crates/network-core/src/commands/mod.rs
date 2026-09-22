//! Network Protocol V2 运行时的命令校验、确认与任务分发。

mod connect;
mod ledger;
mod peer_lifecycle;

#[cfg(test)]
use std::sync::Arc;

#[cfg(test)]
use network_protocol::{
    network_command, CommunicationClass, NetworkCommand, NetworkErrorCode, NETWORK_PROTOCOL_VERSION,
};

#[cfg(test)]
use crate::connect::{PeerId, PeerState, PeerSupervisor};
#[cfg(test)]
use crate::errors::CoreNetworkError;
#[cfg(test)]
use crate::runtime::RuntimeState;

pub(crate) use ledger::run_command_worker;

#[allow(unused_imports)]
pub(crate) use connect::{
    connect_completion_was_cancelled, core_error, decode_communication_class,
    handle_network_environment_changed, start_configure_relay, start_connect_peer,
};
#[allow(unused_imports)]
pub(crate) use ledger::{
    command_peer_id, dispatch_command, CommandResultLedger, MAX_COMPLETED_COMMANDS,
};
#[allow(unused_imports)]
pub(crate) use peer_lifecycle::{emit_peer_diagnostics, remove_peer_v2, validate_e2ee_policy};

#[cfg(test)]
#[path = "../tests/commands.rs"]
mod tests;
