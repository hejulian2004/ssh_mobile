import 'package:flutter/services.dart';

import 'monitoring_widget_snapshot.dart';

/// A later App writer session invalidates old engines. Sequence numbers prevent
/// delayed writes from restoring an earlier monitoring state.
abstract interface class MonitoringWidgetPlatform {
  Future<String> beginSession();
  Future<void> synchronize({
    required String session,
    required int sequence,
    required List<MonitoringWidgetServer> servers,
    required List<MonitoringWidgetSnapshotV1> snapshots,
    required Map<String, int> invalidatedBefore,
    bool reset = false,
  });
}

final class MethodChannelMonitoringWidgets implements MonitoringWidgetPlatform {
  const MethodChannelMonitoringWidgets();
  static const _channel = MethodChannel('ssh_mobile/android_server_widgets');

  @override
  Future<String> beginSession() async {
    final session = await _channel.invokeMethod<String>('beginSession');
    if (session == null || session.isEmpty) {
      throw StateError('Android widget storage did not create a writer');
    }
    return session;
  }

  @override
  Future<void> synchronize({
    required String session,
    required int sequence,
    required List<MonitoringWidgetServer> servers,
    required List<MonitoringWidgetSnapshotV1> snapshots,
    required Map<String, int> invalidatedBefore,
    bool reset = false,
  }) => _channel.invokeMethod<void>('synchronize', {
    'session': session,
    'sequence': sequence,
    'servers': servers.map((server) => server.toMap()).toList(growable: false),
    'snapshots': snapshots
        .map((sample) => sample.toMap())
        .toList(growable: false),
    'invalidatedBefore': invalidatedBefore,
    'reset': reset,
  });
}
