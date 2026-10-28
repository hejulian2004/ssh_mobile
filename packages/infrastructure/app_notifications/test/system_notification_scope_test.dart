import 'dart:async';

import 'package:app_notifications/app_notifications.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('background presentation and one click reach the app', (
    tester,
  ) async {
    final binding = _FakeBinding();
    final center = AppNotificationCenter(binding: binding);
    final activated = <String>[];
    await tester.pumpWidget(
      SystemNotificationScope(
        identity: AppNotificationIdentity.network,
        center: center,
        onActivate: (payload) async {
          activated.add(payload.businessId);
        },
        child: Builder(
          builder: (context) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                final presenter = SystemNotificationScope.maybeOf(context);
                presenter!.present(
                  const AppNotificationRequest(
                    kind: AppNotificationKind.message,
                    peerId: 'peer-1',
                    businessId: 'message-1',
                    displayName: 'Alice',
                    english: true,
                  ),
                );
              },
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
    await tester.pump();
    expect(center.isInitialized, isTrue);

    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    expect(binding.shown, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    expect(binding.shown, hasLength(1));
    expect(binding.shown.single.body, 'New message · Alice');
    expect(binding.shown.single.body, isNot(contains('peer-1')));

    center.deliverPayload(binding.shown.single.payload);
    center.deliverPayload(
      encodeNotificationPayload(
        const AppNotificationPayload(
          kind: AppNotificationKind.transferRequest,
          peerId: 'peer-1',
          businessId: 'transfer-9',
        ),
      ),
    );
    await tester.pump();
    expect(activated, ['message-1', 'transfer-9']);
  });

  testWidgets('a second click waits until the first activation finishes', (
    tester,
  ) async {
    final binding = _FakeBinding();
    final center = AppNotificationCenter(binding: binding);
    final gate = Completer<void>();
    final activated = <String>[];
    await tester.pumpWidget(
      SystemNotificationScope(
        identity: AppNotificationIdentity.full,
        center: center,
        onActivate: (payload) async {
          activated.add(payload.businessId);
          await gate.future;
        },
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    expect(center.isInitialized, isTrue);
    center.deliverPayload(
      encodeNotificationPayload(
        const AppNotificationPayload(
          kind: AppNotificationKind.message,
          peerId: 'peer',
          businessId: 'one',
        ),
      ),
    );
    await tester.pump();
    expect(activated, ['one']);
    center.deliverPayload(
      encodeNotificationPayload(
        const AppNotificationPayload(
          kind: AppNotificationKind.message,
          peerId: 'peer',
          businessId: 'two',
        ),
      ),
    );
    await tester.pump();
    expect(activated, ['one']);
    gate.complete();
    await tester.pump();
    expect(activated, ['one', 'two']);
  });

  testWidgets('activation errors stay inside the scope', (tester) async {
    final binding = _FakeBinding();
    final center = AppNotificationCenter(binding: binding);
    final notes = <String>[];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      SystemNotificationScope(
        identity: AppNotificationIdentity.full,
        center: center,
        diagnostic: notes.add,
        onActivate: (_) {
          throw StateError('navigation');
        },
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    center.deliverPayload(
      encodeNotificationPayload(
        const AppNotificationPayload(
          kind: AppNotificationKind.message,
          peerId: 'peer',
          businessId: 'broken',
        ),
      ),
    );
    await tester.pump();
    expect(notes, ['notification activation failed: StateError']);

    await tester.pumpWidget(
      SystemNotificationScope(
        identity: AppNotificationIdentity.full,
        center: center,
        onActivate: (_) async {},
        child: const SizedBox.expand(),
      ),
    );
    await tester.pump();
    expect(center.onLaunchReady, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(center.onLaunchReady, isNull);
  });
}

final class _Shown {
  _Shown(this.body, this.payload);
  final String body;
  final String payload;
}

final class _FakeBinding implements LocalNotificationBinding {
  final shown = <_Shown>[];

  @override
  Future<NotificationBindingStatus> initialize({
    required AppNotificationIdentity identity,
    required void Function(String? payload) onTap,
  }) async {
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
    shown.add(_Shown(body, payload));
  }

  @override
  Future<void> cancel(int id) async {}
}
