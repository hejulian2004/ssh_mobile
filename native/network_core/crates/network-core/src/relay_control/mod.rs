// Relay v2 control-plane, discovery, and reconnect ownership.
use super::*;

mod cache;
mod reconnect;
mod setup;

pub(crate) use cache::*;
pub(crate) use reconnect::*;
pub(crate) use setup::*;

#[cfg(test)]
#[path = "../tests/relay_control.rs"]
mod tests;
