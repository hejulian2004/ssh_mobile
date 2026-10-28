import 'package:app_notifications/app_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide NotificationVisibility;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'initialize':
              return true;
            case 'getNotificationAppLaunchDetails':
              return <String, Object?>{
                'notificationLaunchedApp': true,
                'notificationResponse': <String, Object?>{
                  'notificationId': 7,
                  'notificationResponseType': 0,
                  'payload': '{"v":"1","t":"message","p":"peer","b":"m1"}',
                },
              };
            default:
              return null;
          }
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'android initialization creates channels and can show or cancel',
    () async {
      final binding = FlutterLocalNotificationBinding();
      expect(binding.plugin, isA<FlutterLocalNotificationsPlugin>());
      String? tapped;
      final status = await binding.initialize(
        identity: AppNotificationIdentity.full,
        onTap: (payload) => tapped = payload,
      );

      expect(status.ready, isTrue);
      expect(status.launchPayload, contains('"t":"message"'));
      final channelIds = calls
          .where((call) => call.method == 'createNotificationChannel')
          .map((call) => (call.arguments as Map)['id'])
          .toList();
      expect(channelIds, [
        AppNotificationChannels.messages,
        AppNotificationChannels.transferRequests,
      ]);
      expect(
        calls
            .where((call) => call.method == 'createNotificationChannel')
            .map((call) => (call.arguments as Map)['importance']),
        everyElement(Importance.high.value),
      );

      await binding.show(
        id: 20001,
        title: 'SSH Mobile',
        body: 'New message',
        payload: 'payload',
        highPriority: false,
      );
      await binding.show(
        id: 20002,
        title: 'SSH Mobile',
        body: 'File transfer request',
        payload: 'payload-2',
        highPriority: true,
      );
      final shown = calls.where((call) => call.method == 'show').toList();
      expect((shown[0].arguments as Map)['body'], 'New message');
      expect(
        ((shown[0].arguments as Map)['platformSpecifics'] as Map)['channelId'],
        AppNotificationChannels.messages,
      );
      expect(
        ((shown[1].arguments as Map)['platformSpecifics'] as Map)['channelId'],
        AppNotificationChannels.transferRequests,
      );
      expect((shown[1].arguments as Map)['body'], isNot(contains('secret')));

      await binding.cancel(20001);
      expect(
        calls.lastWhere((call) => call.method == 'cancel').arguments,
        containsPair('id', 20001),
      );

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('didReceiveNotificationResponse', <String, Object?>{
            'notificationId': 7,
            'notificationResponseType': 0,
            'payload': 'clicked',
          }),
        ),
        (_) {},
      );
      expect(tapped, 'clicked');
    },
  );

  test('a rejected android initialization does not create channels', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'initialize') return false;
          return null;
        });
    final binding = FlutterLocalNotificationBinding();
    final status = await binding.initialize(
      identity: AppNotificationIdentity.network,
      onTap: (_) {},
    );
    expect(status.ready, isFalse);
    expect(status.launchPayload, isNull);
    expect(
      calls.where((call) => call.method == 'createNotificationChannel'),
      isEmpty,
    );
  });

  test('plugin failures stay inside the notification center', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'denied', message: call.method);
        });
    final diagnostics = <String>[];
    final center = AppNotificationCenter(
      binding: FlutterLocalNotificationBinding(),
      onDiagnostic: diagnostics.add,
    );
    final ready = await center.ensureInitialized(
      identity: AppNotificationIdentity.full,
    );
    expect(ready, isFalse);
    expect(diagnostics.single, contains('PlatformException'));
    expect(diagnostics.single, isNot(contains('denied')));
    center.visibility = NotificationVisibility.background;
    expect(
      await center.present(
        const AppNotificationRequest(
          kind: AppNotificationKind.message,
          peerId: 'peer',
          businessId: 'message-1',
        ),
      ),
      isFalse,
    );
  });

  test('channel creation is skipped off Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    calls.clear();
    final binding = FlutterLocalNotificationBinding();
    await binding.ensureAndroidChannel(
      id: 'ssh_mobile_foreground',
      name: 'SSH connection',
      description: 'foreground',
      highPriority: false,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );
    expect(calls, isEmpty);
  });
}
