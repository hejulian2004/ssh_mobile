import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_policy.dart';

/// Android channel ids owned by system notifications.
abstract final class AppNotificationChannels {
  static const messages = 'ssh_mobile_messages';
  static const transferRequests = 'ssh_mobile_transfer_requests';
}

/// Result of one plugin initialization attempt.
final class NotificationBindingStatus {
  const NotificationBindingStatus({required this.ready, this.launchPayload});

  final bool ready;
  final String? launchPayload;
}

/// Narrow plugin boundary used by [AppNotificationCenter].
abstract interface class LocalNotificationBinding {
  Future<NotificationBindingStatus> initialize({
    required AppNotificationIdentity identity,
    required void Function(String? payload) onTap,
  });

  Future<void> ensureAndroidChannel({
    required String id,
    required String name,
    required String description,
    required bool highPriority,
    bool playSound = true,
    bool enableVibration = true,
    bool showBadge = true,
  });

  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required bool highPriority,
  });

  Future<void> cancel(int id);
}

/// `flutter_local_notifications` adapter. One process should initialize once.
final class FlutterLocalNotificationBinding
    implements LocalNotificationBinding {
  FlutterLocalNotificationBinding({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  FlutterLocalNotificationsPlugin get plugin => _plugin;

  @override
  Future<NotificationBindingStatus> initialize({
    required AppNotificationIdentity identity,
    required void Function(String? payload) onTap,
  }) async {
    final accepted = await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: const DarwinInitializationSettings(),
        macOS: const DarwinInitializationSettings(),
        windows: WindowsInitializationSettings(
          appName: identity.appName,
          appUserModelId: identity.appUserModelId,
          guid: identity.guid,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        onTap(response.payload);
      },
    );
    if (accepted != true) {
      return const NotificationBindingStatus(ready: false);
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await ensureAndroidChannel(
        id: AppNotificationChannels.messages,
        name: 'Messages',
        description:
            'LAN chat messages received while the app is in the background.',
        highPriority: true,
      );
      await ensureAndroidChannel(
        id: AppNotificationChannels.transferRequests,
        name: 'File transfers',
        description: 'Incoming LAN file transfer requests.',
        highPriority: true,
      );
    }
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    return NotificationBindingStatus(
      ready: true,
      launchPayload: launch?.didNotificationLaunchApp == true ? payload : null,
    );
  }

  @override
  Future<void> ensureAndroidChannel({
    required String id,
    required String name,
    required String description,
    required bool highPriority,
    bool playSound = true,
    bool enableVibration = true,
    bool showBadge = true,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final importance = highPriority ? Importance.high : Importance.low;
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          AndroidNotificationChannel(
            id,
            name,
            description: description,
            importance: importance,
            playSound: playSound,
            enableVibration: enableVibration,
            showBadge: showBadge,
          ),
        );
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required bool highPriority,
  }) {
    final channelId = highPriority
        ? AppNotificationChannels.transferRequests
        : AppNotificationChannels.messages;
    return _plugin.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          highPriority ? 'File transfers' : 'Messages',
          importance: highPriority
              ? Importance.high
              : Importance.defaultImportance,
          priority: highPriority ? Priority.high : Priority.defaultPriority,
          category: AndroidNotificationCategory.message,
        ),
        windows: WindowsNotificationDetails(
          duration: highPriority
              ? WindowsNotificationDuration.long
              : WindowsNotificationDuration.short,
        ),
      ),
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}
