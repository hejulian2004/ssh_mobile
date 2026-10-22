最新更新时间：2026-10-22

# feature_monitoring 维护约束

- Owns live server monitoring, health scoring, sample parsing, and monitoring
  tool contracts. Keep only bounded in-memory state; do not create trend DB.
  SSH exec, connection platform, logging, and background services arrive through
  public Ports.
- Sampling is explicitly user-started, never a permanent App-start Timer.
  `deactivate`/`dispose` cancels timers, stops sampling, and removes listeners.
  Monitoring SSH requests are low priority and cannot use the interactive
  Terminal scheduler.
- `MonitoringService` owns selection/Timer/probe/platform routing;
  `MonitoringSampleStore` owns history/counts/immutable views/health score;
  `MonitoringAlertEvaluator` owns thresholds, five-minute dedup, and bounded
  history. Do not add a second cache. Each `startMonitoring` captures an
  immutable target set and epoch; stale epochs cannot retry, record, clear a new
  marker, or restart a Timer. The old `lib/services/performance_monitor_service.dart`
  path has been removed. `apps/ssh_mobile_full/lib/services/server_status_probe.dart`
  only re-exports public probe types; new code uses
  `package:feature_monitoring/feature_monitoring.dart`.
- Contract: allowed models/parsers/Ports/Module/Service/ViewModel/tests; no other
  Feature/App `/src/`, global SSH/Settings, or unified storage. No DB or
  `monitoring.db`; AppRuntime owns Module, while Module/Service stop and release
  sampling timers/streams/subscriptions.

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test`；local aggregate CI 仅按用户明确要求运行。
