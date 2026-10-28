use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::diagnostics::DiagnosticOutput;

#[test]
fn runtime_dispatch_is_private_bounded_and_drains() {
    let root = std::env::temp_dir().join(format!(
        "native-diagnostics-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    assert!(DiagnosticOutput::new(&root, "../bad").is_err());
    let output = DiagnosticOutput::new(&root, "test-run").unwrap();
    tracing::dispatcher::with_default(output.dispatch(), || {
        let parent = tracing::info_span!("diagnostic_operation", count = 1);
        let child = tracing::info_span!("child");
        child.follows_from(parent.id());
        let _entered = parent.enter();
        parent.record("count", 2);
        tracing::debug!(count = -1_i64, "debug site");
        tracing::error!(
            duration_ms = 12_u64,
            password = "private-value",
            "private-message"
        );
    });
    drop(output);
    let path = fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .unwrap();
    let text = fs::read_to_string(path).unwrap();
    assert!(!text.contains("private"));
    let value: serde_json::Value = serde_json::from_str(text.lines().last().unwrap()).unwrap();
    assert_eq!(value["run_id"], "test-run");
    assert_eq!(value["level"], "error");
    assert_eq!(value["attributes"]["duration_ms"], 12);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn runtime_tasks_inherit_their_own_dispatch() {
    let root = std::env::temp_dir().join(format!(
        "native-task-log-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let output = DiagnosticOutput::new(&root, "task-run").unwrap();
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let supervisor = crate::task_supervisor::RuntimeTaskSupervisor::new();
    let (sender, receiver) = tokio::sync::oneshot::channel();
    tracing::dispatcher::with_default(output.dispatch(), || {
        let _runtime = runtime.enter();
        supervisor
            .spawn_runtime("diagnostic-check", async move {
                tracing::warn!(count = 7_u64, "private-message");
                sender.send(()).unwrap();
            })
            .unwrap();
    });
    runtime.block_on(receiver).unwrap();
    runtime.block_on(supervisor.shutdown());
    drop(output);
    let path = fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .unwrap();
    let text = fs::read_to_string(path).unwrap();
    assert!(text.contains("warning"));
    assert!(text.contains("task-run"));
    assert!(!text.contains("private-message"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn file_retention_is_bounded_and_invalid_output_is_reported() {
    let root = std::env::temp_dir().join(format!(
        "native-rotation-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    let base = root.join("native-fixture");
    let record = serde_json::json!({"event":"fixture"});
    super::write_record(&base, &record).unwrap();
    for _ in 0..5 {
        fs::OpenOptions::new()
            .write(true)
            .open(base.with_extension("jsonl"))
            .unwrap()
            .set_len(5 * 1024 * 1024)
            .unwrap();
        super::write_record(&base, &record).unwrap();
    }
    assert_eq!(fs::read_dir(&root).unwrap().count(), 4);
    assert!(fs::read_to_string(base.with_extension("jsonl"))
        .unwrap()
        .contains("fixture"));
    assert!(super::write_record(&root.join("missing").join("output"), &record).is_err());
    assert!(
        super::write_record(&base, &serde_json::json!({"oversized":"x".repeat(65536)})).is_err()
    );
    assert_eq!(super::timestamp(0), "1970-01-01T00:00:00.000Z");
    assert_eq!(super::timestamp(1582934400000), "2020-02-29T00:00:00.000Z");
    fs::remove_dir_all(root).unwrap();
}
