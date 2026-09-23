//! Runtime lifecycle-owned resources.
//!
//! The Runtime root coordinates domains, while this aggregate owns the
//! process-local resources created and released by the native lifecycle:
//! endpoint handles, accept-loop task ids, local identity, and receive path.

use std::path::PathBuf;
use std::sync::{atomic::AtomicU16, Arc, Mutex};

#[cfg(test)]
use std::sync::atomic::AtomicBool;

use network_identity::DeviceIdentity;
use quinn::Endpoint;
use tokio::sync::RwLock;

use crate::task_supervisor::TaskId;

pub(crate) struct RuntimeLifecycleState {
    /// Native bind result exposed through the controlled diagnostic snapshot.
    pub(crate) bound_port: Arc<AtomicU16>,
    /// Runtime-owned QUIC endpoint. The endpoint itself is released on stop/drop.
    pub(crate) endpoint: RwLock<Option<Endpoint>>,
    /// Cancellation lookups for the accept loops; the supervisor owns the tasks.
    pub(crate) accept_task: Mutex<Option<TaskId>>,
    pub(crate) tcp_accept_task: Mutex<Option<TaskId>>,
    #[cfg(test)]
    pub(crate) tcp_fallback_enabled: AtomicBool,
    pub(crate) identity: RwLock<Option<Arc<DeviceIdentity>>>,
    pub(crate) receive_directory: RwLock<Option<PathBuf>>,
}

impl RuntimeLifecycleState {
    pub(crate) fn new(bound_port: Arc<AtomicU16>) -> Self {
        Self {
            bound_port,
            endpoint: RwLock::new(None),
            accept_task: Mutex::new(None),
            tcp_accept_task: Mutex::new(None),
            #[cfg(test)]
            tcp_fallback_enabled: AtomicBool::new(true),
            identity: RwLock::new(None),
            receive_directory: RwLock::new(None),
        }
    }
}
