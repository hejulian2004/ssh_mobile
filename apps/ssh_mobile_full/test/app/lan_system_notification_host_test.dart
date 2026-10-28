import 'package:app_notifications/app_notifications.dart';
import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/app/lan_system_notification_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full app host shows redacted background notifications', (
    tester,
  ) async {
    final binding = _Binding();
    final center = AppNotificationCenter(binding: binding);
    final navigatorKey = GlobalKey<NavigatorState>();
    var english = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: LanSystemNotificationHost(
          navigatorKey: navigatorKey,
          english: () => english,
          center: center,
          diagnostic: (_) {},
          child: const _Probe(),
        ),
      ),
    );
    await tester.pump();
    expect(binding.identity, AppNotificationIdentity.full);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.tap(find.text('message'));
    await tester.pump();
    expect(binding.shown.single.body, '新消息 · Phone');
    expect(binding.shown.single.highPriority, isFalse);
    expect(binding.shown.single.body.contains('secret'), isFalse);

    english = true;
    await tester.tap(find.text('transferRequest'));
    await tester.tap(find.text('transferSucceeded'));
    await tester.tap(find.text('transferFailed'));
    await tester.pump();
    expect(binding.shown.map((item) => item.body), [
      '新消息 · Phone',
      'File transfer request · Phone',
      'File transfer complete · Phone',
      'File transfer failed · Phone',
    ]);
    expect(binding.shown[1].highPriority, isTrue);
    expect(binding.shown.map((item) => item.id).toSet(), hasLength(4));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('full app click resumes the app and does not accept a transfer', (
    tester,
  ) async {
    final binding = _Binding();
    final center = AppNotificationCenter(binding: binding);
    final navigatorKey = GlobalKey<NavigatorState>();
    final coordinator = _coordinator();
    addTearDown(() async {
      coordinator.dispose();
      await coordinator.historyRepository.database.dispose();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<LanReceiverCoordinator>.value(
        value: coordinator,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: LanSystemNotificationHost(
            navigatorKey: navigatorKey,
            english: () => false,
            center: center,
            child: const _Probe(),
          ),
        ),
      ),
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.tap(find.text('claim'));
    await tester.pump();

    for (final kind in AppNotificationKind.values) {
      center.deliverPayload(
        encodeNotificationPayload(
          AppNotificationPayload(
            kind: kind,
            peerId: 'peer',
            businessId: kind.name,
          ),
        ),
      );
      await tester.pump();
    }
    center.deliverPayload(
      encodeNotificationPayload(
        const AppNotificationPayload(
          kind: AppNotificationKind.message,
          peerId: '',
          businessId: 'missing',
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LanChatScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

LanReceiverCoordinator _coordinator() {
  return LanReceiverCoordinator(
    appSettings: _Settings(),
    logger: _Logger(),
    dataProtection: _Protection(),
    networkIdentity: _Identity(),
    networkAccess: _Access(),
    bootstrapClient: _Bootstrap(),
    historyRepository: LanShareHistoryRepository(
      LanShareDatabase.forTesting(NativeDatabase.memory()),
    ),
    networkRuntime: _Runtime(),
  );
}

final class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          onPressed: () => context.read<LanVisibleChat>().claim('peer'),
          child: const Text('claim'),
        ),
        for (final kind in LanNotificationKind.values)
          TextButton(
            onPressed: () {
              context.read<LanSystemNotificationPort>().present(
                LanNotificationEvent(
                  kind: kind,
                  businessId: kind.name,
                  peerId: 'peer',
                  displayName: 'Phone',
                ),
              );
            },
            child: Text(kind.name),
          ),
      ],
    );
  }
}

final class _Shown {
  const _Shown({
    required this.id,
    required this.body,
    required this.highPriority,
  });

  final int id;
  final String body;
  final bool highPriority;
}

final class _Binding implements LocalNotificationBinding {
  AppNotificationIdentity? identity;
  final List<_Shown> shown = <_Shown>[];

  @override
  Future<NotificationBindingStatus> initialize({
    required AppNotificationIdentity identity,
    required void Function(String? payload) onTap,
  }) async {
    this.identity = identity;
    return const NotificationBindingStatus(ready: true);
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
  }) async {}

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required bool highPriority,
  }) async {
    shown.add(_Shown(id: id, body: body, highPriority: highPriority));
  }

  @override
  Future<void> cancel(int id) async {}
}

final class _Settings extends Fake implements LanShareSettingsPort {}

final class _Logger extends Fake implements LanShareLoggerPort {}

final class _Protection extends Fake implements LanShareDataProtectionPort {}

final class _Identity extends Fake implements LanShareNetworkIdentityPort {}

final class _Access extends Fake implements LanShareNetworkAccessPort {}

final class _Bootstrap extends Fake implements BootstrapClient {}

final class _Runtime extends Fake implements LanShareNetworkRuntimePort {}
