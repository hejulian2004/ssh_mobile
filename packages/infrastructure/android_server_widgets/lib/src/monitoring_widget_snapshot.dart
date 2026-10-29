enum MonitoringWidgetStatus {
  notConfigured,
  notStarted,
  waiting,
  active,
  stopped,
  failed,
  stale,
}

/// Only an internal ID and a redacted label cross the directory boundary.
final class MonitoringWidgetServer {
  MonitoringWidgetServer({
    required String connectionId,
    required String displayName,
  }) : connectionId = requireWidgetConnectionId(connectionId),
       displayName = sanitizeWidgetDisplayName(displayName);

  final String connectionId;
  final String displayName;

  Map<String, Object> toMap() => {
    'connectionId': connectionId,
    'displayName': displayName,
  };
}

/// V1 contains the latest observation, never credentials or monitor history.
final class MonitoringWidgetSnapshotV1 {
  factory MonitoringWidgetSnapshotV1({
    required String connectionId,
    required String displayName,
    required DateTime? sampledAt,
    required double? cpuPercent,
    required double? memoryPercent,
    required double? networkBytesPerSecond,
    required double? diskBytesPerSecond,
    required int effectiveIntervalMs,
    required MonitoringWidgetStatus status,
    required DateTime now,
  }) {
    final validTime =
        sampledAt != null &&
        sampledAt.millisecondsSinceEpoch >= 946684800000 &&
        !sampledAt.isAfter(now.add(const Duration(seconds: 5)));
    double? metric(double? value, {bool percent = false}) =>
        validTime &&
            value != null &&
            value.isFinite &&
            value >= 0 &&
            (!percent || value <= 100)
        ? value
        : null;
    return MonitoringWidgetSnapshotV1._(
      requireWidgetConnectionId(connectionId),
      sanitizeWidgetDisplayName(displayName),
      validTime ? sampledAt.toUtc() : null,
      metric(cpuPercent, percent: true),
      metric(memoryPercent, percent: true),
      metric(networkBytesPerSecond),
      metric(diskBytesPerSecond),
      effectiveIntervalMs <= 0
          ? 10000
          : effectiveIntervalMs.clamp(1000, 300000),
      !validTime && status == MonitoringWidgetStatus.active
          ? MonitoringWidgetStatus.waiting
          : status,
    );
  }

  const MonitoringWidgetSnapshotV1._(
    this.connectionId,
    this.displayName,
    this.sampledAt,
    this.cpuPercent,
    this.memoryPercent,
    this.networkBytesPerSecond,
    this.diskBytesPerSecond,
    this.effectiveIntervalMs,
    this.status,
  );

  static const schemaVersion = 1;
  final String connectionId;
  final String displayName;
  final DateTime? sampledAt;
  final double? cpuPercent;
  final double? memoryPercent;
  final double? networkBytesPerSecond;
  final double? diskBytesPerSecond;
  final int effectiveIntervalMs;
  final MonitoringWidgetStatus status;

  MonitoringWidgetStatus statusAt(DateTime now) {
    final sampleTime = sampledAt;
    if (status != MonitoringWidgetStatus.active || sampleTime == null) {
      return status;
    }
    final threshold = (3 * effectiveIntervalMs).clamp(60000, 900000);
    return now.difference(sampleTime).inMilliseconds >= threshold
        ? MonitoringWidgetStatus.stale
        : status;
  }

  Map<String, Object?> toMap() => {
    'schemaVersion': schemaVersion,
    'connectionId': connectionId,
    'displayName': displayName,
    'sampledAt': sampledAt?.millisecondsSinceEpoch,
    'cpuPercent': cpuPercent,
    'memoryPercent': memoryPercent,
    'networkBytesPerSecond': networkBytesPerSecond,
    'diskBytesPerSecond': diskBytesPerSecond,
    'effectiveIntervalMs': effectiveIntervalMs,
    'status': status.name,
  };
}

String requireWidgetConnectionId(String id) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
    throw ArgumentError('Invalid widget connection ID');
  }
  return id;
}

/// Reject endpoint-like and credential-like labels before truncation. App
/// composition additionally removes the target's known host and username.
String sanitizeWidgetDisplayName(String raw) {
  if (raw.length > 1024) raw = raw.substring(0, 1024);
  if (RegExp(
    r'[@:/\\=]|\d+\.\d+|\b[\w-]+\.[A-Za-z]{2,}\b|password|passwd|token|secret|private.?key',
    caseSensitive: false,
  ).hasMatch(raw)) {
    return 'Server';
  }
  final clean = raw
      .replaceAll(
        RegExp(r'[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069]'),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (clean.isEmpty) return 'Server';
  return String.fromCharCodes(clean.runes.take(48));
}
