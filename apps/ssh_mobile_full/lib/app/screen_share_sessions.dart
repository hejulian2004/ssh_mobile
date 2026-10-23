import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:realtime_media/realtime_media.dart';
import 'realtime_media_feature_adapters.dart';
import 'screen_share_operation.dart';
import 'screen_share_route_arguments.dart';

/// App-scoped single operation owner. Pages hold presentation leases only.
final class AppScreenShareSessions extends ChangeNotifier {
  AppScreenShareOperation? _current;
  final Map<AppScreenShareOperation, int> _views = {};
  bool _closed = false;
  bool _notificationPending = false;
  Future<void>? _closing;

  AppScreenShareOperation? get current => _current;
  bool get pageVisible => (_views[_current] ?? 0) > 0;
  bool get isBusy => _current != null && !_current!.finished;

  AppScreenShareOperation open(
    AppScreenShareRouteArguments arguments,
    AppRealtimeMediaResources resources, {
    AppScreenSharePlatformCapabilities? capabilities,
  }) {
    if (_closed) throw StateError('Screen-share owner is closed.');
    final current = _current;
    if (current != null &&
        identical(current.arguments.session, arguments.session) &&
        current.arguments.operationId == arguments.operationId) {
      return current;
    }
    if (isBusy) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'Another screen-share operation is already active.',
      );
    }
    if (current != null && (_views[current] ?? 0) == 0) _retire(current);
    final operation = AppScreenShareOperation(
      arguments: arguments,
      resources: resources,
      capabilities: capabilities,
    );
    _current = operation;
    _views[operation] = 0;
    operation.addListener(_changed);
    unawaited(
      operation.initialization.then(
        (_) => _changed(),
        onError: (_) => _changed(),
      ),
    );
    _changed();
    return operation;
  }

  AppScreenShareOperation attach(
    AppScreenShareRouteArguments arguments,
    AppRealtimeMediaResources resources, {
    AppScreenSharePlatformCapabilities? capabilities,
  }) {
    final operation = open(arguments, resources, capabilities: capabilities);
    _views[operation] = (_views[operation] ?? 0) + 1;
    _changed();
    return operation;
  }

  void detach(AppScreenShareOperation operation) {
    if (_closed || !_views.containsKey(operation)) return;
    final remaining = (_views[operation]! - 1).clamp(0, 1 << 30);
    _views[operation] = remaining;
    if (remaining == 0 && operation.finished) _retire(operation);
    _changed();
  }

  void _changed() {
    if (_closed || _notificationPending) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (_closed) return;
      for (final operation in _views.keys.toList()) {
        if (operation.finished && _views[operation] == 0) _retire(operation);
      }
      notifyListeners();
    });
  }

  void _retire(AppScreenShareOperation operation) {
    if (identical(_current, operation)) _current = null;
    _views.remove(operation);
    operation.removeListener(_changed);
    unawaited(operation.close().whenComplete(operation.dispose));
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    final operations = _views.keys.toList();
    _views.clear();
    _current = null;
    for (final operation in operations) {
      operation.removeListener(_changed);
      await operation.close();
      operation.dispose();
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
