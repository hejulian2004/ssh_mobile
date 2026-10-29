import 'dart:async';

import 'package:android_server_widgets/android_server_widgets.dart';
import 'package:connection_core/connection_core.dart';
import 'package:feature_monitoring/feature_monitoring.dart';
import 'package:flutter/foundation.dart';

/// App-owned borrower of monitoring and directory observations. It never starts
/// sampling or closes the monitor. Native writes are single-flight, coalesced,
/// and tagged with a writer session and strictly increasing sequence.
final class MonitoringWidgetAdapter {
  static MonitoringWidgetAdapter? createForCurrentPlatform({
    required MonitoringService monitoring,
    required Stream<List<ConnectionConfig>> catalog,
    MonitoringWidgetPlatform platform = const MethodChannelMonitoringWidgets(),
    DateTime Function()? now,
    VoidCallback? onError,
  }) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    return MonitoringWidgetAdapter._(
      monitoring,
      catalog,
      platform,
      now ?? DateTime.now,
      onError,
    );
  }

  MonitoringWidgetAdapter._(
    this._monitoring,
    Stream<List<ConnectionConfig>> catalog,
    this._platform,
    this._now,
    this._onError,
  ) {
    _monitoring.addListener(_changed);
    _catalogSubscription = catalog.listen(
      _catalogChanged,
      onError: (Object _) {
        _onError?.call();
        _catalogChanged(const []);
      },
    );
  }

  final MonitoringService _monitoring;
  final MonitoringWidgetPlatform _platform;
  final DateTime Function() _now;
  final VoidCallback? _onError;
  late final StreamSubscription<List<ConnectionConfig>> _catalogSubscription;
  final Map<String, MonitoringWidgetServer> _servers = {};
  // Target identity stays in memory only; it never crosses the channel.
  final Map<String, Object> _targets = {};
  final Map<String, int> _invalidatedBefore = {};
  final Map<String, DateTime?> _blockedRuns = {};
  final Set<String> _ran = {};
  final Map<String, MonitoringWidgetSnapshotV1> _sent = {};
  final Map<String, DateTime> _sentAt = {};
  final Map<String, DateTime?> _sentRuns = {};
  bool _catalogLoaded = false;
  bool _catalogDirty = false;
  bool _reset = false;
  bool _requested = false;
  bool _disposed = false;
  String? _session;
  int _sequence = 0;
  int _catalogRevision = 0;
  Future<void>? _draining;
  Future<void>? _disposal;

  void _catalogChanged(List<ConnectionConfig> configs) {
    if (_disposed) return;
    final next = <String, MonitoringWidgetServer>{};
    final targets = <String, Object>{};
    for (final config in configs.take(100)) {
      try {
        var label = config.name;
        for (final value in [
          config.host,
          config.username,
          config.jumpHost,
          config.jumpUsername,
        ]) {
          if (value != null &&
              value.isNotEmpty &&
              label.toLowerCase().contains(value.toLowerCase())) {
            label = 'Server';
            break;
          }
        }
        final server = MonitoringWidgetServer(
          connectionId: config.id,
          displayName: label,
        );
        final target = (
          config.host,
          config.port,
          config.username,
          config.authMethod,
          config.serverPlatform,
          config.jumpHost,
          config.jumpPort,
          config.jumpUsername,
        );
        final previous = _targets[config.id];
        if (previous != null && previous != target) {
          _blockedRuns[config.id] = _monitoring.startedAt;
          _invalidatedBefore[config.id] = _now().millisecondsSinceEpoch;
          _sent.remove(config.id);
        } else if (!_catalogLoaded || !_servers.containsKey(config.id)) {
          _invalidatedBefore[config.id] =
              config.updatedAt.millisecondsSinceEpoch;
          if (_catalogLoaded &&
              _monitoring.isRunning &&
              _monitoring.monitoringConnectionIds.contains(config.id)) {
            _blockedRuns[config.id] = _monitoring.startedAt;
            _invalidatedBefore[config.id] = _now().millisecondsSinceEpoch;
          }
        }
        next[config.id] = server;
        targets[config.id] = target;
      } on ArgumentError {
        _onError?.call();
      }
    }
    final changed =
        !mapEquals(
          _servers.map((id, server) => MapEntry(id, server.displayName)),
          next.map((id, server) => MapEntry(id, server.displayName)),
        ) ||
        !mapEquals(_targets, targets);
    _servers
      ..clear()
      ..addAll(next);
    _targets
      ..clear()
      ..addAll(targets);
    _sent.removeWhere((id, _) => !next.containsKey(id));
    _sentAt.removeWhere((id, _) => !next.containsKey(id));
    _sentRuns.removeWhere((id, _) => !next.containsKey(id));
    _blockedRuns.removeWhere((id, _) => !next.containsKey(id));
    _invalidatedBefore.removeWhere((id, _) => !next.containsKey(id));
    _ran.removeWhere((id) => !next.containsKey(id));
    _catalogDirty = _catalogDirty || changed || !_catalogLoaded;
    _catalogLoaded = true;
    _catalogRevision++;
    _changed();
  }

  void _changed() {
    if (_disposed || !_catalogLoaded) return;
    if (_monitoring.isRunning) {
      _ran.addAll(
        _monitoring.monitoringConnectionIds.where(_servers.containsKey),
      );
    }
    _requested = true;
    if (_draining != null) return;
    // Start on the next microtask so a burst observes the latest state once.
    _draining = Future<void>.microtask(_drain).whenComplete(() {
      _draining = null;
      if (_requested && !_disposed) _changed();
    });
  }

  /// Settles already observed state without a polling timer or extra SSH work.
  Future<void> flush() async {
    if (_disposed) return;
    _changed();
    while (_draining != null) {
      await _draining;
    }
  }

  Future<void> invalidateConfiguration() async {
    if (_disposed) return;
    _reset = true;
    _catalogRevision++;
    for (final id in _servers.keys) {
      _blockedRuns[id] = _monitoring.startedAt;
    }
    _sent.clear();
    await flush();
  }

  Future<void> _drain() async {
    try {
      _session ??= await _platform.beginSession();
      while (_requested && !_disposed) {
        _requested = false;
        final revision = _catalogRevision;
        final now = _now();
        final snapshots = <MonitoringWidgetSnapshotV1>[];
        final run = _monitoring.startedAt;
        for (final server in _servers.values) {
          final snapshot = _snapshot(server, now);
          final prior = _sent[server.connectionId];
          final stateChanged =
              prior == null ||
              prior.status != snapshot.status ||
              _sentRuns[server.connectionId] != run ||
              prior.displayName != snapshot.displayName ||
              prior.effectiveIntervalMs != snapshot.effectiveIntervalMs;
          final sampleChanged = prior?.sampledAt != snapshot.sampledAt;
          final elapsed = now.difference(
            _sentAt[server.connectionId] ??
                DateTime.fromMillisecondsSinceEpoch(0),
          );
          if (stateChanged ||
              (sampleChanged && elapsed >= const Duration(seconds: 15))) {
            snapshots.add(snapshot);
          }
        }
        if (snapshots.isEmpty && !_catalogDirty && !_reset) continue;
        final reset = _reset;
        await _platform.synchronize(
          session: _session!,
          sequence: ++_sequence,
          servers: _servers.values.toList(growable: false),
          snapshots: snapshots,
          invalidatedBefore: Map.of(_invalidatedBefore),
          reset: reset,
        );
        if (_disposed) return;
        if (revision == _catalogRevision) {
          _catalogDirty = false;
          _reset = false;
        }
        for (final snapshot in snapshots) {
          // A concurrent deletion/config change cannot reinsert its cache.
          if (revision == _catalogRevision) {
            _sent[snapshot.connectionId] = snapshot;
            _sentAt[snapshot.connectionId] = now;
            _sentRuns[snapshot.connectionId] = run;
          }
        }
      }
    } catch (_) {
      _requested = false;
      _onError?.call();
    }
  }

  MonitoringWidgetSnapshotV1 _snapshot(
    MonitoringWidgetServer server,
    DateTime now,
  ) {
    final id = server.connectionId;
    final startedAt = _monitoring.startedAt;
    final blocked =
        _blockedRuns.containsKey(id) &&
        (_blockedRuns[id] == startedAt || startedAt == null);
    final running =
        _monitoring.isRunning &&
        startedAt != null &&
        _monitoring.monitoringConnectionIds.contains(id) &&
        !blocked;
    PerformanceSample? sample;
    if (running) {
      _ran.add(id);
      for (final candidate in _monitoring.samplesFor(id)) {
        if (candidate.connectionId == id &&
            !candidate.time.isBefore(startedAt) &&
            (sample == null || candidate.time.isAfter(sample.time))) {
          sample = candidate;
        }
      }
    }
    final status = blocked
        ? MonitoringWidgetStatus.notStarted
        : running
        ? _monitoring.errorsByConnection.containsKey(id)
              ? MonitoringWidgetStatus.failed
              : sample == null
              ? MonitoringWidgetStatus.waiting
              : MonitoringWidgetStatus.active
        : _ran.contains(id)
        ? MonitoringWidgetStatus.stopped
        : MonitoringWidgetStatus.notStarted;
    final previous = running || blocked ? null : _sent[id];
    return MonitoringWidgetSnapshotV1(
      connectionId: id,
      displayName: server.displayName,
      sampledAt: sample?.time ?? previous?.sampledAt,
      cpuPercent: sample?.cpuPercent ?? previous?.cpuPercent,
      memoryPercent: sample?.memoryPercent ?? previous?.memoryPercent,
      networkBytesPerSecond:
          sample?.networkBytesPerSecond ?? previous?.networkBytesPerSecond,
      diskBytesPerSecond:
          sample?.diskBytesPerSecond ?? previous?.diskBytesPerSecond,
      effectiveIntervalMs: _monitoring.effectiveInterval.inMilliseconds,
      status: status,
      now: now,
    );
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _requested = false;
    _monitoring.removeListener(_changed);
    await _catalogSubscription.cancel();
    await _draining;
    // App shutdown marks borrowed active snapshots stopped; sampling is released
    // later by its original Module owner. Persisted metrics remain available.
    final session = _session;
    if (session == null) return;
    try {
      final snapshots = _servers.values
          .map((server) {
            final previous = _sent[server.connectionId];
            return MonitoringWidgetSnapshotV1(
              connectionId: server.connectionId,
              displayName: server.displayName,
              sampledAt: previous?.sampledAt,
              cpuPercent: previous?.cpuPercent,
              memoryPercent: previous?.memoryPercent,
              networkBytesPerSecond: previous?.networkBytesPerSecond,
              diskBytesPerSecond: previous?.diskBytesPerSecond,
              effectiveIntervalMs: _monitoring.effectiveInterval.inMilliseconds,
              status: _ran.contains(server.connectionId)
                  ? MonitoringWidgetStatus.stopped
                  : MonitoringWidgetStatus.notStarted,
              now: _now(),
            );
          })
          .toList(growable: false);
      await _platform.synchronize(
        session: session,
        sequence: ++_sequence,
        servers: _servers.values.toList(growable: false),
        snapshots: snapshots,
        invalidatedBefore: Map.of(_invalidatedBefore),
        reset: _reset,
      );
    } catch (_) {
      _onError?.call();
    }
  }
}
