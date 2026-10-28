import 'notification_policy.dart';

/// Keeps only the latest notification click until navigation can run.
final class NotificationLaunchQueue {
  AppNotificationPayload? _pending;
  var _ready = false;

  bool get isReady => _ready;

  bool get hasPending => _pending != null;

  /// Replaces any click that arrived before navigation was ready.
  void remember(AppNotificationPayload payload) {
    _pending = payload;
  }

  void markReady() {
    _ready = true;
  }

  /// Returns the latest click once, after [markReady].
  AppNotificationPayload? take() {
    if (!_ready) return null;
    final payload = _pending;
    _pending = null;
    return payload;
  }
}
