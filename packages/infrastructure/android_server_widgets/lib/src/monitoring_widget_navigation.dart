import 'package:flutter/services.dart';

import 'monitoring_widget_snapshot.dart';

/// A navigation hint only; the App must resolve the ID against its directory.
final class MonitoringWidgetOpenRequest {
  const MonitoringWidgetOpenRequest._(this.connectionId, this.requestId);
  final String connectionId;
  final String requestId;

  static MonitoringWidgetOpenRequest? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['connectionId'];
    final request = value['requestId'];
    if (id is! String ||
        request is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(request)) {
      return null;
    }
    try {
      return MonitoringWidgetOpenRequest._(
        requireWidgetConnectionId(id),
        request,
      );
    } on ArgumentError {
      return null;
    }
  }
}

abstract interface class MonitoringWidgetNavigationPort {
  Future<void> start(void Function(MonitoringWidgetOpenRequest) onOpen);
  Future<void> dispose();
}

/// One Engine channel registration. Replaced owners cannot clear a newer
/// listener, and a pending cold-start read never escapes its disposed owner.
final class MonitoringWidgetNavigationChannel
    implements MonitoringWidgetNavigationPort {
  static const _channel = MethodChannel('ssh_mobile/android_server_widgets');
  static MonitoringWidgetNavigationChannel? _owner;
  void Function(MonitoringWidgetOpenRequest)? _onOpen;
  bool _closed = false;
  Future<void>? _starting;

  @override
  Future<void> start(void Function(MonitoringWidgetOpenRequest) onOpen) async {
    if (_closed) throw StateError('Widget navigation listener is closed');
    await (_starting ??= _start(onOpen));
  }

  Future<void> _start(void Function(MonitoringWidgetOpenRequest) onOpen) async {
    _onOpen = onOpen;
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openMonitoring') _deliver(call.arguments);
    });
    final pending = await _channel.invokeMethod<Object?>(
      'takePendingNavigation',
    );
    _deliver(pending);
  }

  void _deliver(Object? payload) {
    if (_closed || !identical(_owner, this)) return;
    final request = MonitoringWidgetOpenRequest.tryParse(payload);
    if (request != null) _onOpen?.call(request);
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _onOpen = null;
    if (identical(_owner, this)) {
      _channel.setMethodCallHandler(null);
      _owner = null;
    }
  }
}
