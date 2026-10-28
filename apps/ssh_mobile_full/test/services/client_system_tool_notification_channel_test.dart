import 'package:app_notifications/app_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reuses the shared center channel when it is already initialized',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final calls = <MethodCall>[];
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'initialize') return true;
            if (call.method == 'getNotificationAppLaunchDetails') {
              return <String, Object?>{'notificationLaunchedApp': false};
            }
            return null;
          });
      addTearDown(() async {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final ready = await AppNotificationCenter.shared.ensureInitialized(
        identity: AppNotificationIdentity.full,
      );
      expect(ready, isTrue);

      final service = ClientSystemToolService.instance;
      final alarm = await service.setAlarm(
        delayMinutes: 30,
        label: 'reminder',
        useSystemAlarm: false,
      );
      addTearDown(() => service.cancelAlarm(alarm['alarmId'] as String));

      final channelIds = calls
          .where((call) => call.method == 'createNotificationChannel')
          .map((call) => (call.arguments as Map)['id'])
          .toList();
      expect(channelIds, contains('ssh_mobile_client_tools'));
    },
  );
}
