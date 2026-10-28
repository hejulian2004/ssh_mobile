> Last updated: 2026-10-23

# app_diagnostics maintenance contract

- Own local structured envelopes and bounded file output only. Production
  dependencies are Dart SDK and the public `app_core` entry point.
- Never import App/Feature implementations, Flutter UI, network runtimes or
  development query/launcher code. Features keep using injected `AppLogger`.
- Reuse `LogRecord`, `LogSink` and `TelemetryRedactor`; do not create a global
  logger, database, uploader or alternative privacy policy.
- App composition roots own sinks and await `close`; scoped loggers borrow them.
  Text logs and JSONL reuse `RotatingLogWriter`.
- Optional development output stays disabled without a run ID and in release.
  Android paths stay under its private cache. Queue bounds and visible failure/
  drop counts are public behavior.
- Validate with `dart analyze .`, `flutter test --coverage`; new handwritten
  production files require independent tests and 90% line coverage.
