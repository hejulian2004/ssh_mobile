> 最新更新时间：2026-10-23

# Local runtime diagnostic contract

The [runtime log Skill](../../.agents/skills/ssh-mobile-logs/SKILL.md) defines the
workflow. The repository tool `tool/agent_logs.dart` owns local processes and
host collection; `app_diagnostics` owns shared Dart output. Dependencies remain
App/tool → Infrastructure → public Core; Features use injected `AppLogger`.
Rust and Go adapt their existing tracing/slog boundaries; Front emits typed
development events through a loopback-only Vite receiver. No runtime imports
the query tools or Skill. No new database or remote log service is created.

## Output and compatibility

Default output is `build/agent-observability/<run_id>` in the current checkout.
`--output-dir` selects another host root. Each marked run has a checkout key,
code revision, creation/heartbeat/end state and per-component process status.
The worker owns live process objects; stop never kills a PID merely found in
an old manifest. Startup returns launching and readiness is reported separately.

JSONL schema version 1 requires `schema_version`, `occurred_at` (UTC), `run_id`,
`instance_id`, `component`, `level`, `message`, and `attributes`. Optional fields
are `source`, `event`, `trace_id`, `error_code`, `details`, `error`, `stack`, and
host `collected_at`. Correlation uses only existing trace IDs; this is not a
distributed tracing protocol. Native output is enabled through an additive
runtime-creation ABI, without changing Network V2 commands/events.

Core's existing redactor remains the Dart privacy boundary. Numeric attributes
are limited to duration/count/bytes/attempt/status metadata; safe typed labels
use an explicit allowlist. Browser payloads, auth headers, terminal/SSH output,
file contents and media never enter this stream. Rust/Go omit free-form log
arguments and identify existing call sites instead. Unstructured launcher
stdout/stderr is discarded before persistence.

Full App keeps its existing local text log/database/UI and telemetry gates.
The text log and JSONL share a bounded rotating writer. Local sinks see legacy
and structured records exactly once; existing telemetry sinks still see only
the original structured calls. App Runtime drains local sinks before logger
release. Shared output is disabled in release and without an explicit run ID.

## Bounds and failures

Each source retains a current file and three 5 MiB rotations; records are at
most 64 KiB. Dart writers bound both queued count (2048) and bytes (4 MiB).
Native uses a bounded writer channel and numeric-only fields. Health sidecars
report written, failed, dropped and closed state. A failed log write must not
block a business operation or recursively log its own failure.

Queries return at most 1000 records and report malformed/incomplete lines.
Summary reports only its query window. Missing files, failed components,
unconfirmed readiness, stale worker heartbeat, Android collection gaps and
forced termination must not be represented as complete evidence.

Browser requests are bounded to 16 in flight. HTTP failures and queue overflow
accumulate a count, reported as `diagnostic_dropped` after successful traffic
resumes; this does not create an automatic retry loop. The worker remembers the
loss flag beyond the query window. A live Vite server without a browser-ready
event remains an explicit gap. Android partial tails are retried and reported
until a complete snapshot is available. `query --follow` exits after its selected
run ends. Executable overrides `--flutter`, `--go`, `--npm`, and `--adb` select
the caller's native development toolchain without changing global PATH.

`clean` removes only owned ended runs older than seven days. Device cache
retention remains platform-owned. Linux/WSL and Windows use independent
checkouts/toolchains/output; synchronize source only through Git.
