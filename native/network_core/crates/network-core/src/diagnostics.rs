//! Runtime-owned local tracing, with no process-global subscriber or raw values.
use serde_json::{json, Map, Value};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{SystemTime, UNIX_EPOCH};
use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id, Record};
use tracing::{Event, Metadata, Subscriber};
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);

struct State {
    sender: Mutex<Option<mpsc::SyncSender<Value>>>,
    dropped: AtomicU64,
    failed: AtomicU64,
}

/// Owned beside the native runtime. Drop only after runtime tasks have stopped.
pub struct DiagnosticOutput {
    dispatch: tracing::Dispatch,
    state: Arc<State>,
    worker: Option<JoinHandle<()>>,
}

impl DiagnosticOutput {
    pub fn new(directory: &Path, run: &str) -> std::io::Result<Self> {
        if run.is_empty()
            || run.len() > 96
            || !run
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(std::io::ErrorKind::InvalidInput.into());
        }
        fs::create_dir_all(directory)?;
        let instance = format!(
            "{}_{}_{}",
            std::process::id(),
            unix_ms(),
            NEXT_INSTANCE.fetch_add(1, Ordering::Relaxed)
        );
        let base = directory.join(format!("native-{instance}"));
        let (sender, receiver) = mpsc::sync_channel(2048);
        let state = Arc::new(State {
            sender: Mutex::new(Some(sender)),
            dropped: AtomicU64::new(0),
            failed: AtomicU64::new(0),
        });
        let worker_state = state.clone();
        let worker = thread::Builder::new()
            .name("ssh-diagnostic-writer".into())
            .spawn(move || {
                let mut written = 0_u64;
                for record in receiver {
                    if write_record(&base, &record).is_ok() {
                        written += 1;
                    } else {
                        worker_state.failed.fetch_add(1, Ordering::Relaxed);
                    }
                    save_health(&base, &worker_state, written, false);
                }
                save_health(&base, &worker_state, written, true);
            })?;
        let dispatch = tracing::Dispatch::new(LocalSubscriber {
            state: state.clone(),
            run: run.into(),
            instance,
            next_span: AtomicU64::new(1),
        });
        Ok(Self {
            dispatch,
            state,
            worker: Some(worker),
        })
    }
    pub fn dispatch(&self) -> &tracing::Dispatch {
        &self.dispatch
    }
}

impl Drop for DiagnosticOutput {
    fn drop(&mut self) {
        if let Ok(mut sender) = self.state.sender.lock() {
            sender.take();
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

struct LocalSubscriber {
    state: Arc<State>,
    run: String,
    instance: String,
    next_span: AtomicU64,
}
impl Subscriber for LocalSubscriber {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        *metadata.level() <= tracing::Level::DEBUG
    }
    fn new_span(&self, _: &Attributes<'_>) -> Id {
        Id::from_u64(self.next_span.fetch_add(1, Ordering::Relaxed))
    }
    fn record(&self, _: &Id, _: &Record<'_>) {}
    fn record_follows_from(&self, _: &Id, _: &Id) {}
    fn enter(&self, _: &Id) {}
    fn exit(&self, _: &Id) {}
    fn event(&self, event: &Event<'_>) {
        let metadata = event.metadata();
        let mut fields = SafeFields(Map::new());
        event.record(&mut fields);
        // Free-form arguments may contain plaintext, endpoints or credentials.
        // A static module and line identify the existing call site instead.
        let source = format!(
            "{}:{}",
            metadata.module_path().unwrap_or("native"),
            metadata.line().unwrap_or(0)
        );
        let level = if *metadata.level() == tracing::Level::WARN {
            "warning".into()
        } else {
            metadata.level().to_string().to_lowercase()
        };
        let value = json!({"schema_version": 1, "occurred_at": timestamp(unix_ms()),
            "run_id": self.run, "instance_id": self.instance, "component": "native",
            "level": level, "event": "native_log", "message": "native_log", "source": source,
            "attributes": fields.0});
        if let Ok(sender) = self.state.sender.lock() {
            if let Some(sender) = sender.as_ref() {
                if sender.try_send(value).is_err() {
                    self.state.dropped.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
    }
}

struct SafeFields(Map<String, Value>);
impl Visit for SafeFields {
    fn record_debug(&mut self, _: &Field, _: &dyn std::fmt::Debug) {}
    fn record_u64(&mut self, field: &Field, value: u64) {
        if matches!(
            field.name(),
            "duration_ms" | "count" | "bytes" | "attempt" | "status_code"
        ) {
            self.0.insert(field.name().into(), value.into());
        }
    }
    fn record_i64(&mut self, field: &Field, value: i64) {
        if matches!(
            field.name(),
            "duration_ms" | "count" | "bytes" | "attempt" | "status_code"
        ) {
            self.0.insert(field.name().into(), value.into());
        }
    }
}

fn write_record(base: &Path, record: &Value) -> std::io::Result<()> {
    let file = base.with_extension("jsonl");
    let bytes = serde_json::to_vec(record)?;
    if bytes.len() > 65535 {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    if fs::metadata(&file).is_ok_and(|m| m.len() + bytes.len() as u64 + 1 > 5 * 1024 * 1024) {
        let rotated = |n| PathBuf::from(format!("{}.{}", file.display(), n));
        if rotated(3).exists() {
            fs::remove_file(rotated(3))?;
        }
        for index in (1..3).rev() {
            if rotated(index).exists() {
                fs::rename(rotated(index), rotated(index + 1))?;
            }
        }
        fs::rename(&file, rotated(1))?;
    }
    let mut output = OpenOptions::new().create(true).append(true).open(file)?;
    output.write_all(&bytes)?;
    output.write_all(b"\n")?;
    output.flush()
}

fn save_health(base: &Path, state: &State, written: u64, closed: bool) {
    let value = json!({"written": written, "dropped": state.dropped.load(Ordering::Relaxed), "failed": state.failed.load(Ordering::Relaxed), "closed": closed, "updated_at": timestamp(unix_ms())});
    if fs::write(base.with_extension("health.json"), value.to_string()).is_err() {
        state.failed.fetch_add(1, Ordering::Relaxed);
    }
}
fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn timestamp(ms: u64) -> String {
    // Gregorian civil date from Unix days; avoids a new runtime dependency.
    let z = (ms / 86_400_000) as i64 + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    let seconds = ms / 1000;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        seconds / 3600 % 24,
        seconds / 60 % 60,
        seconds % 60,
        ms % 1000
    )
}

#[cfg(test)]
#[path = "tests/diagnostics.rs"]
mod tests;
