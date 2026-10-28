import 'package:app_notifications/app_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shared center can prepare an android channel', () async {
    final binding = _FakeBinding();
    final center = AppNotificationCenter(binding: binding);
    expect(center.hasPendingLaunch, isFalse);
    expect(AppNotificationCenter.shared, isA<AppNotificationCenter>());
    await center.ensureAndroidChannel(
      id: 'ssh_mobile_client_tools',
      name: 'Tools',
      description: 'Client tool reminders',
      highPriority: false,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );
    expect(binding.channelIds, ['ssh_mobile_client_tools']);
  });

  test('foreground requests are not shown', () async {
    final binding = _FakeBinding();
    final center = AppNotificationCenter(binding: binding);
    final ready = await center.ensureInitialized(
      identity: AppNotificationIdentity.full,
    );
    expect(ready, isTrue);
    center.visibility = NotificationVisibility.foreground;
    final shown = await center.present(
      const AppNotificationRequest(
        kind: AppNotificationKind.message,
        peerId: 'peer',
        businessId: 'message-1',
        displayName: 'secret message body',
      ),
    );
    expect(shown, isFalse);
    expect(binding.shown, isEmpty);
  });

  test('background text uses a stable id and redacted copy', () async {
    final binding = _FakeBinding();
    final center = AppNotificationCenter(binding: binding);
    await center.ensureInitialized(identity: AppNotificationIdentity.network);
    center.visibility = NotificationVisibility.background;
    final shown = await center.present(
      const AppNotificationRequest(
        kind: AppNotificationKind.message,
        peerId: 'peer',
        businessId: 'message-1',
        displayName: 'Alice',
        english: true,
      ),
    );
    expect(shown, isTrue);
    expect(binding.shown, hasLength(1));
    expect(binding.shown.single.title, 'SSH Mobile');
    expect(binding.shown.single.body, 'New message · Alice');
    expect(binding.shown.single.body.contains('secret'), isFalse);
    expect(
      binding.shown.single.id,
      stableNotificationId(AppNotificationKind.message, 'message-1'),
    );
    final payload = decodeNotificationPayload(binding.shown.single.payload);
    expect(payload!.businessId, 'message-1');
    expect(payload.peerId, 'peer');
  });

  test('initialization failure is reported and can be retried', () async {
    final binding = _FakeBinding()..failInitialize = true;
    final notes = <String>[];
    final center = AppNotificationCenter(
      binding: binding,
      onDiagnostic: notes.add,
    );
    expect(
      await center.ensureInitialized(identity: AppNotificationIdentity.full),
      isFalse,
    );
    expect(notes.single, contains('StateError'));
    binding.failInitialize = false;
    expect(
      await center.ensureInitialized(identity: AppNotificationIdentity.full),
      isTrue,
    );
  });

  test('a cold-start payload waits until navigation is ready', () async {
    final binding = _FakeBinding()
      ..launchPayload = encodeNotificationPayload(
        const AppNotificationPayload(
          kind: AppNotificationKind.transferSucceeded,
          peerId: 'peer',
          businessId: 'file-1',
        ),
      );
    final center = AppNotificationCenter(binding: binding);
    await center.ensureInitialized(identity: AppNotificationIdentity.full);
    expect(center.takeLaunch(), isNull);
    center.markNavigationReady();
    expect(center.takeLaunch()!.businessId, 'file-1');
  });

  test('an invalid click is ignored', () async {
    final notes = <String>[];
    final center = AppNotificationCenter(
      binding: _FakeBinding(),
      onDiagnostic: notes.add,
    );
    await center.ensureInitialized(identity: AppNotificationIdentity.full);
    center.markNavigationReady();
    center.deliverPayload('not-json');
    expect(center.takeLaunch(), isNull);
    expect(notes.single, 'notification payload ignored');
  });

  test('show failures do not escape', () async {
    final binding = _FakeBinding()..failShow = true;
    final notes = <String>[];
    final center = AppNotificationCenter(
      binding: binding,
      onDiagnostic: notes.add,
    );
    await center.ensureInitialized(identity: AppNotificationIdentity.full);
    center.visibility = NotificationVisibility.background;
    expect(
      await center.present(
        const AppNotificationRequest(
          kind: AppNotificationKind.transferRequest,
          peerId: 'peer',
          businessId: 'transfer-1',
        ),
      ),
      isFalse,
    );
    expect(notes.single, contains('StateError'));
    expect(binding.shown.single.highPriority, isTrue);
  });
}

final class _Shown {
  const _Shown({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
    required this.highPriority,
  });

  final int id;
  final String title;
  final String body;
  final String payload;
  final bool highPriority;
}

final class _FakeBinding implements LocalNotificationBinding {
  var failInitialize = false;
  var failShow = false;
  String? launchPayload;
  final List<_Shown> shown = [];
  final List<String> channelIds = [];

  @override
  Future<NotificationBindingStatus> initialize({
    required AppNotificationIdentity identity,
    required void Function(String? payload) onTap,
  }) async {
    if (failInitialize) throw StateError('plugin unavailable');
    return NotificationBindingStatus(ready: true, launchPayload: launchPayload);
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
    channelIds.add(id);
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required bool highPriority,
  }) async {
    shown.add(
      _Shown(
        id: id,
        title: title,
        body: body,
        payload: payload,
        highPriority: highPriority,
      ),
    );
    if (failShow) throw StateError('show failed');
  }

  @override
  Future<void> cancel(int id) async {}
}
