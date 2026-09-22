use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::connection::{ConnectionProfile, GenericRouteHandle};
use crate::task_supervisor::{CancellationToken, TaskLease};

const GENERIC_ROUTE_CLOSE_TIMEOUT: Duration = Duration::from_secs(1);

/// Owns the generic route driver and receiver leases while a route is being
/// staged for publication. The path owner takes this value only after the
/// authenticated route wins its admission race.
pub(crate) struct GenericRouteOwner {
    handle: GenericRouteHandle,
    driver_task: TaskLease,
    receiver_task: TaskLease,
    route_stop: CancellationToken,
    stopping: Arc<AtomicBool>,
    committed: bool,
}

impl GenericRouteOwner {
    pub(crate) fn new(
        handle: GenericRouteHandle,
        driver_task: TaskLease,
        receiver_task: TaskLease,
        route_stop: CancellationToken,
        stopping: Arc<AtomicBool>,
    ) -> Self {
        Self {
            handle,
            driver_task,
            receiver_task,
            route_stop,
            stopping,
            committed: false,
        }
    }

    pub(crate) fn handle(&self) -> &GenericRouteHandle {
        &self.handle
    }

    pub(super) async fn close(mut self) {
        self.stopping.store(true, Ordering::Release);
        if !self.committed {
            self.route_stop.cancel();
            self.receiver_task.cancel().await;
            self.driver_task.cancel().await;
            return;
        }
        self.receiver_task.cancel().await;
        match tokio::time::timeout(GENERIC_ROUTE_CLOSE_TIMEOUT, self.handle.close()).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                tracing::debug!(route_id = self.handle.id().raw(), %error, "generic route close failed")
            }
            Err(_) => {
                tracing::debug!(
                    route_id = self.handle.id().raw(),
                    "generic route close timed out"
                )
            }
        }
        self.route_stop.cancel();
        self.driver_task.cancel().await;
    }
}

impl Drop for GenericRouteOwner {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        self.route_stop.cancel();
        self.receiver_task.abort_now();
        self.driver_task.abort_now();
    }
}

/// Staged generic route between task startup and physical-path publication.
pub(crate) struct GenericRouteScope {
    owner: Option<GenericRouteOwner>,
    commit: Option<tokio::sync::oneshot::Sender<()>>,
}

impl GenericRouteScope {
    pub(crate) fn new(
        handle: GenericRouteHandle,
        driver_task: TaskLease,
        receiver_task: TaskLease,
        route_stop: CancellationToken,
        stopping: Arc<AtomicBool>,
        commit: tokio::sync::oneshot::Sender<()>,
    ) -> Self {
        Self {
            owner: Some(GenericRouteOwner::new(
                handle,
                driver_task,
                receiver_task,
                route_stop,
                stopping,
            )),
            commit: Some(commit),
        }
    }

    pub(crate) fn profile(&self) -> Option<ConnectionProfile> {
        self.owner.as_ref().map(|owner| owner.handle().profile())
    }

    pub(crate) fn commit_and_take_owner(&mut self) -> Result<GenericRouteOwner, ()> {
        let commit = self.commit.take().ok_or(())?;
        commit.send(()).map_err(|_| ())?;
        let mut owner = self.owner.take().ok_or(())?;
        owner.committed = true;
        Ok(owner)
    }

    pub(crate) async fn close(mut self) {
        if let Some(owner) = self.owner.take() {
            owner.close().await;
        }
    }
}
