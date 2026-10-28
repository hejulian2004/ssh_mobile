> Last updated: 2026-10-23

# Local application diagnostics

`app_diagnostics` is an Infrastructure adapter for App composition roots and
development tools. Its public entry point is `package:app_diagnostics/app_diagnostics.dart`.
It depends only on Dart SDK and public Core logging/redaction contracts. It owns
no database, network runtime, telemetry uploader, business state or Flutter UI.

`DiagnosticFileSink` implements Core `LogSink`. `DiagnosticEnvelope` preserves
event time and optional trace/event/error metadata, redacts text using the existing
Core redactor and filters attributes before output. `RotatingLogWriter` is also
used by the Full App's existing text log output: 5 MiB per file, three rotations,
2048 queued records / 4 MiB, at most 64 KiB per record. Failure/drop counters are
visible through health snapshots and structured sink sidecars.

`DiagnosticConfig.fromEnvironment` reads `SSH_MOBILE_LOG_RUN_ID` and
`SSH_MOBILE_LOG_DIR` from Dart defines or the process environment. Output is opt-in
and disabled in release. Android ignores host output paths and writes under
its private cache's `agent-observability/<run_id>` directory.

The App Runtime owns each sink and awaits `close()` after borrowers stop.
Core `AppLoggerImpl` closes its sinks; Full App explicitly drains its local-only
sinks before disposing the legacy logger. Query and process-management code
remains in repository tools and is never a runtime dependency.

Validation: `dart analyze .`, `flutter test --coverage`.
