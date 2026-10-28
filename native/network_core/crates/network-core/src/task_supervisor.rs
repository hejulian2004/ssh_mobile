//! Runtime-owned cancellation and task supervision.
//!
//! Every long-lived native task is registered here.  The supervisor deliberately
//! keeps a small cancellation primitive local to `network-core` instead of
//! leaking a Tokio task handle into feature code or the FFI boundary.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use tracing::instrument::WithSubscriber;

pub(crate) type TaskId = u64;

/// Hard cap on live supervisor records. Control-plane overload must fail at
/// task admission instead of growing an unbounded native allocation.
pub(crate) const MAX_SUPERVISED_TASKS: usize = 512;

/// An owning capability for one supervised task.
///
/// Most runtime tasks only need the supervisor's group cancellation and keep
/// using `TaskId` as a lookup key.  A composed resource such as a GenericRoute
/// also needs to hand its driver and receiver to another owner after startup,
/// so it keeps this lease until that handoff.  Dropping a live lease is a
/// synchronous last-resort abort; normal teardown should call `cancel` so the
/// task has a chance to release its async resources and be joined.
pub(crate) struct TaskLease {
    supervisor: Arc<RuntimeTaskSupervisor>,
    task_id: Option<TaskId>,
}

impl TaskLease {
    fn new(supervisor: Arc<RuntimeTaskSupervisor>, task_id: TaskId) -> Self {
        Self {
            supervisor,
            task_id: Some(task_id),
        }
    }

    /// Cancel and join the task.  This is idempotent so a natural task exit or
    /// a prior group cancellation can race with explicit route teardown.
    pub(crate) async fn cancel(&mut self) {
        let Some(task_id) = self.task_id.take() else {
            return;
        };
        self.supervisor.cancel_task(task_id).await;
    }

    /// Abort the task synchronously for a Drop path where awaiting is not
    /// possible.
    pub(crate) fn abort_now(&mut self) {
        if let Some(task_id) = self.task_id.take() {
            let _ = self.supervisor.cancel_task_sync(task_id);
        }
    }
}

impl Drop for TaskLease {
    fn drop(&mut self) {
        self.abort_now();
    }
}

/// A clonable cancellation signal that wakes every waiter exactly when the
/// owner cancels it.  It is intentionally tiny and does not expose Tokio
/// handles outside this module.
#[derive(Clone, Default)]
pub(crate) struct CancellationToken {
    cancelled: Arc<AtomicBool>,
    notify: Arc<Notify>,
}

impl CancellationToken {
    pub(crate) fn cancel(&self) {
        if !self.cancelled.swap(true, Ordering::AcqRel) {
            self.notify.notify_waiters();
        }
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    pub(crate) async fn cancelled(&self) {
        let notified = self.notify.notified();
        if self.is_cancelled() {
            return;
        }
        notified.await;
    }
}

struct TaskRecord {
    token: CancellationToken,
    join: Mutex<Option<JoinHandle<()>>>,
}

struct SessionTaskGroup {
    token: CancellationToken,
    task_ids: Mutex<Vec<TaskId>>,
}

/// The sole owner of native background tasks.
pub(crate) struct RuntimeTaskSupervisor {
    root: CancellationToken,
    next_id: AtomicU64,
    stopping: AtomicBool,
    tasks: Mutex<HashMap<TaskId, Arc<TaskRecord>>>,
    session_groups: Mutex<HashMap<String, Arc<SessionTaskGroup>>>,
}

impl RuntimeTaskSupervisor {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            root: CancellationToken::default(),
            next_id: AtomicU64::new(1),
            stopping: AtomicBool::new(false),
            tasks: Mutex::new(HashMap::new()),
            session_groups: Mutex::new(HashMap::new()),
        })
    }

    /// Spawn a runtime-scoped task.  The returned id is only for native owner
    /// bookkeeping; callers must not await or abort the raw JoinHandle.
    pub(crate) fn spawn_runtime<F>(&self, name: impl Into<String>, future: F) -> Option<TaskId>
    where
        F: Future<Output = ()> + Send + 'static,
    {
        self.spawn_scoped(name.into(), None, future)
    }

    /// Spawn a task bound to one logical Session.  Session cancellation is
    /// independent of the transport Connection and therefore survives route
    /// replacement while still allowing an explicit Session close to await
    /// every child.
    pub(crate) fn spawn_session<F>(
        &self,
        session_key: impl Into<String>,
        name: impl Into<String>,
        future: F,
    ) -> Option<TaskId>
    where
        F: Future<Output = ()> + Send + 'static,
    {
        if self.stopping.load(Ordering::Acquire) {
            return None;
        }
        let session_key = session_key.into();
        let group = {
            let mut groups = self.session_groups.lock().ok()?;
            let group = groups
                .entry(session_key.clone())
                .or_insert_with(|| {
                    Arc::new(SessionTaskGroup {
                        token: CancellationToken::default(),
                        task_ids: Mutex::new(Vec::new()),
                    })
                })
                .clone();
            if group.token.is_cancelled() {
                return None;
            }
            group
        };
        let task_id = self.spawn_scoped(name.into(), Some(group.clone()), future)?;
        if let Ok(mut task_ids) = group.task_ids.lock() {
            if group.token.is_cancelled() {
                task_ids.push(task_id);
                drop(task_ids);
                let _ = self.cancel_task_sync(task_id);
                return None;
            }
            task_ids.push(task_id);
        }
        Some(task_id)
    }

    /// Spawn a Session-scoped task and return an owning lease.  This is kept
    /// separate from `spawn_session` because existing task callers only need
    /// an index id and must not accidentally receive a Drop-aborting owner.
    pub(crate) fn spawn_session_controlled<F>(
        self: &Arc<Self>,
        session_key: impl Into<String>,
        name: impl Into<String>,
        future: F,
    ) -> Option<TaskLease>
    where
        F: Future<Output = ()> + Send + 'static,
    {
        let task_id = self.spawn_session(session_key, name, future)?;
        Some(TaskLease::new(Arc::clone(self), task_id))
    }

    /// Mark the root as stopping before closing the underlying I/O owners.
    /// `shutdown()` must still be called afterwards to drain and join records.
    pub(crate) fn cancel_root(&self) {
        self.stopping.store(true, Ordering::Release);
        self.root.cancel();
        if let Ok(groups) = self.session_groups.lock() {
            for group in groups.values() {
                group.token.cancel();
            }
        }
    }

    fn spawn_scoped<F>(
        &self,
        name: String,
        session_group: Option<Arc<SessionTaskGroup>>,
        future: F,
    ) -> Option<TaskId>
    where
        F: Future<Output = ()> + Send + 'static,
    {
        if self.stopping.load(Ordering::Acquire) {
            return None;
        }
        self.reap_finished();
        if self
            .tasks
            .lock()
            .ok()
            .is_some_and(|tasks| tasks.len() >= MAX_SUPERVISED_TASKS)
        {
            tracing::warn!(task = %name, "native task supervisor capacity exhausted");
            return None;
        }
        let task_id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let task_token = CancellationToken::default();
        let task_token_for_future = task_token.clone();
        let root_token = self.root.clone();
        let session_token = session_group.as_ref().map(|group| group.token.clone());
        let join = tokio::spawn(
            (async move {
                match session_token {
                    Some(session_token) => {
                        tokio::select! {
                            _ = root_token.cancelled() => {}
                            _ = session_token.cancelled() => {}
                            _ = task_token_for_future.cancelled() => {}
                            _ = future => {}
                        }
                    }
                    None => {
                        tokio::select! {
                            _ = root_token.cancelled() => {}
                            _ = task_token_for_future.cancelled() => {}
                            _ = future => {}
                        }
                    }
                }
            })
            .with_current_subscriber(),
        );
        tracing::trace!(task_id, task = %name, "supervised native task started");
        let record = Arc::new(TaskRecord {
            token: task_token,
            join: Mutex::new(Some(join)),
        });
        let mut tasks = self.tasks.lock().ok()?;
        if self.stopping.load(Ordering::Acquire) {
            record.token.cancel();
            if let Ok(mut join) = record.join.lock() {
                if let Some(join) = join.take() {
                    join.abort();
                }
            }
            return None;
        }
        tasks.insert(task_id, record);
        Some(task_id)
    }

    /// Cancel and await one task.  This is used for explicit Relay/task
    /// replacement, while runtime shutdown drains all records at once.
    pub(crate) async fn cancel_task(&self, task_id: TaskId) {
        if let Some(record) = self.take_task(task_id) {
            record.token.cancel();
            join_record(record).await;
        }
    }

    fn cancel_task_sync(&self, task_id: TaskId) -> Option<()> {
        let record = self.take_task(task_id)?;
        record.token.cancel();
        if let Ok(mut join) = record.join.lock() {
            if let Some(join) = join.take() {
                join.abort();
            }
        }
        Some(())
    }

    fn take_task(&self, task_id: TaskId) -> Option<Arc<TaskRecord>> {
        self.tasks.lock().ok()?.remove(&task_id)
    }

    /// Cancel and await every child belonging to one logical Session.
    pub(crate) async fn cancel_session(&self, session_key: &str) {
        let group = self
            .session_groups
            .lock()
            .ok()
            .and_then(|mut groups| groups.remove(session_key));
        let Some(group) = group else {
            return;
        };
        group.token.cancel();
        let task_ids = group
            .task_ids
            .lock()
            .map(|task_ids| task_ids.clone())
            .unwrap_or_default();
        for task_id in task_ids {
            self.cancel_task(task_id).await;
        }
    }

    /// Root shutdown is idempotent and does not return until all registered
    /// tasks have released their futures and task-owned resources.
    pub(crate) async fn shutdown(&self) {
        if self.stopping.swap(true, Ordering::AcqRel) {
            self.root.cancel();
            if let Ok(groups) = self.session_groups.lock() {
                for group in groups.values() {
                    group.token.cancel();
                }
            }
            self.await_all().await;
            if let Ok(mut groups) = self.session_groups.lock() {
                groups.clear();
            }
            return;
        }
        self.root.cancel();
        if let Ok(groups) = self.session_groups.lock() {
            for group in groups.values() {
                group.token.cancel();
            }
        }
        self.await_all().await;
        if let Ok(mut groups) = self.session_groups.lock() {
            groups.clear();
        }
    }

    async fn await_all(&self) {
        let records = self
            .tasks
            .lock()
            .map(|mut tasks| tasks.drain().map(|(_, record)| record).collect::<Vec<_>>())
            .unwrap_or_default();
        for record in records {
            record.token.cancel();
            join_record(record).await;
        }
    }

    /// Best-effort synchronous fallback used only by `Drop`, where awaiting is
    /// impossible.  Explicit `stop()` always calls `shutdown()` instead.
    pub(crate) fn abort_all_now(&self) {
        self.stopping.store(true, Ordering::Release);
        self.root.cancel();
        if let Ok(groups) = self.session_groups.lock() {
            for group in groups.values() {
                group.token.cancel();
            }
        }
        if let Ok(mut tasks) = self.tasks.lock() {
            for (_, record) in tasks.drain() {
                record.token.cancel();
                if let Ok(mut join) = record.join.lock() {
                    if let Some(join) = join.take() {
                        join.abort();
                    }
                }
            }
        }
        if let Ok(mut groups) = self.session_groups.lock() {
            groups.clear();
        }
    }

    #[cfg(test)]
    pub(crate) fn active_count(&self) -> usize {
        self.reap_finished();
        self.tasks.lock().map(|tasks| tasks.len()).unwrap_or(0)
    }

    fn reap_finished(&self) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.retain(|_, record| {
                record
                    .join
                    .lock()
                    .map(|join| join.as_ref().is_some_and(|join| !join.is_finished()))
                    .unwrap_or(false)
            });
        }
    }
}

async fn join_record(record: Arc<TaskRecord>) {
    let join = record.join.lock().ok().and_then(|mut join| join.take());
    if let Some(join) = join {
        let _ = join.await;
    }
}

#[cfg(test)]
#[path = "tests/task_supervisor.rs"]
mod tests;
