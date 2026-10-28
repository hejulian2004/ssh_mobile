import 'notification_launch_queue.dart';
import 'notification_policy.dart';
import 'flutter_local_notification_binding.dart';

/// Reports a notification failure without message text or peer ids.
typedef AppNotificationDiagnostic = void Function(String message);

/// Owns plugin initialization, redacted presentation, and click delivery.
final class AppNotificationCenter {
  AppNotificationCenter({
    LocalNotificationBinding? binding,
    NotificationLaunchQueue? launches,
    this.onDiagnostic,
  }) : _binding = binding ?? FlutterLocalNotificationBinding(),
       _launches = launches ?? NotificationLaunchQueue();

  static final AppNotificationCenter shared = AppNotificationCenter();

  final LocalNotificationBinding _binding;
  final NotificationLaunchQueue _launches;
  AppNotificationDiagnostic? onDiagnostic;
  void Function()? onLaunchReady;
  Future<bool>? _pending;
  var _ready = false;
  NotificationVisibility visibility = NotificationVisibility.foreground;

  bool get isInitialized => _ready;

  bool get hasPendingLaunch => _launches.hasPending;

  /// Initializes the plugin once. A failed attempt can be retried.
  Future<bool> ensureInitialized({required AppNotificationIdentity identity}) {
    if (_ready) return Future<bool>.value(true);
    final pending = _pending;
    if (pending != null) return pending;
    final future = _initialize(identity);
    _pending = future;
    return future.whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
  }

  Future<bool> _initialize(AppNotificationIdentity identity) async {
    try {
      final status = await _binding.initialize(
        identity: identity,
        onTap: deliverPayload,
      );
      _ready = status.ready;
      final launch = decodeNotificationPayload(status.launchPayload);
      if (launch != null) _launches.remember(launch);
      return _ready;
    } catch (error) {
      _ready = false;
      onDiagnostic?.call(
        'notification initialization failed: ${error.runtimeType}',
      );
      return false;
    }
  }

  Future<void> ensureAndroidChannel({
    required String id,
    required String name,
    required String description,
    required bool highPriority,
    bool playSound = true,
    bool enableVibration = true,
    bool showBadge = true,
  }) {
    return _binding.ensureAndroidChannel(
      id: id,
      name: name,
      description: description,
      highPriority: highPriority,
      playSound: playSound,
      enableVibration: enableVibration,
      showBadge: showBadge,
    );
  }

  /// Shows a background notification, or returns false when it must stay quiet.
  Future<bool> present(AppNotificationRequest request) async {
    if (!shouldPresentSystemNotification(visibility: visibility)) return false;
    if (!_ready) return false;
    final copy = notificationCopy(
      request.kind,
      english: request.english,
      displayName: request.displayName,
      peerId: request.peerId,
    );
    try {
      await _binding.show(
        id: stableNotificationId(request.kind, request.businessId),
        title: copy.title,
        body: copy.body,
        payload: encodeNotificationPayload(request.payload),
        highPriority: request.kind == AppNotificationKind.transferRequest,
      );
      return true;
    } catch (error) {
      onDiagnostic?.call('notification show failed: ${error.runtimeType}');
      return false;
    }
  }

  /// Records a click. Navigation receives it only after [markNavigationReady].
  void deliverPayload(String? raw) {
    final payload = decodeNotificationPayload(raw);
    if (payload == null) {
      onDiagnostic?.call('notification payload ignored');
      return;
    }
    _launches.remember(payload);
    _notifyLaunch();
  }

  void markNavigationReady() {
    _launches.markReady();
    _notifyLaunch();
  }

  void _notifyLaunch() {
    if (_launches.isReady && _launches.hasPending) onLaunchReady?.call();
  }

  AppNotificationPayload? takeLaunch() => _launches.take();
}
