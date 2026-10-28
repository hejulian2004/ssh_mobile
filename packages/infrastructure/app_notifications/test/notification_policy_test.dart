import 'package:app_notifications/app_notifications.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('foreground lifecycle does not raise a system notification', () {
    expect(
      visibilityForLifecycle(AppLifecycleState.resumed),
      NotificationVisibility.foreground,
    );
    expect(
      visibilityForLifecycle(AppLifecycleState.inactive),
      NotificationVisibility.foreground,
    );
    expect(
      shouldPresentSystemNotification(
        visibility: NotificationVisibility.foreground,
      ),
      isFalse,
    );
  });

  test('hidden, paused, and detached processes can notify', () {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      expect(
        shouldPresentSystemNotification(
          visibility: visibilityForLifecycle(state),
        ),
        isTrue,
      );
    }
  });

  test('copy omits message text, paths, secrets, and raw peer ids', () {
    const peerId = 'peer-1234567890';
    final hidden = notificationCopy(
      AppNotificationKind.message,
      english: false,
      displayName: 'hello secret token',
      peerId: peerId,
    );
    expect(hidden.body, '新消息');
    expect(hidden.body.contains('secret'), isFalse);

    final path = notificationCopy(
      AppNotificationKind.transferSucceeded,
      english: true,
      displayName: r'C:\private\clip.mp4',
      peerId: peerId,
    );
    expect(path.body, 'File transfer complete');

    final named = notificationCopy(
      AppNotificationKind.transferRequest,
      english: false,
      displayName: 'Alice',
      peerId: peerId,
    );
    expect(named.body, '文件传输申请 · Alice');
    expect(
      notificationCopy(
        AppNotificationKind.transferFailed,
        english: false,
        peerId: peerId,
      ).body,
      '文件传输失败',
    );

    final rawId = notificationCopy(
      AppNotificationKind.message,
      english: true,
      displayName: peerId,
      peerId: peerId,
    );
    expect(rawId.body, 'New message');
  });

  test('the same business id keeps one notification id', () {
    final first = stableNotificationId(AppNotificationKind.message, 'm-1');
    final second = stableNotificationId(AppNotificationKind.message, 'm-1');
    final other = stableNotificationId(
      AppNotificationKind.transferRequest,
      'm-1',
    );
    expect(second, first);
    expect(other, isNot(first));
    expect(first, greaterThanOrEqualTo(20000));
    expect(first, lessThan(1020000));
  });

  test('payload roundtrip excludes message text and rejects garbage', () {
    const payload = AppNotificationPayload(
      kind: AppNotificationKind.transferFailed,
      peerId: 'peer-a',
      businessId: 'transfer-1',
    );
    final encoded = encodeNotificationPayload(payload);
    expect(encoded.contains('hello'), isFalse);
    expect(decodeNotificationPayload(encoded), isNotNull);
    expect(decodeNotificationPayload(encoded)!.kind, payload.kind);
    expect(decodeNotificationPayload(encoded)!.peerId, 'peer-a');
    expect(decodeNotificationPayload(''), isNull);
    expect(decodeNotificationPayload('{'), isNull);
    expect(
      decodeNotificationPayload('{"v":"2","t":"message","p":"a","b":"b"}'),
      isNull,
    );
    expect(
      decodeNotificationPayload('{"v":"1","t":"nope","p":"a","b":"b"}'),
      isNull,
    );
  });

  test('a transfer request click does not open or accept the transfer', () {
    const request = AppNotificationPayload(
      kind: AppNotificationKind.transferRequest,
      peerId: 'peer-a',
      businessId: 'transfer-1',
    );
    expect(
      activationFor(request, recalled: false, peerMismatch: false),
      NotificationActivation.showApp,
    );
    expect(
      activationFor(
        const AppNotificationPayload(
          kind: AppNotificationKind.message,
          peerId: 'peer-a',
          businessId: 'message-1',
        ),
        recalled: false,
        peerMismatch: false,
      ),
      NotificationActivation.openChat,
    );
    expect(
      activationFor(request, recalled: true, peerMismatch: false),
      NotificationActivation.ignore,
    );
    expect(
      activationFor(
        const AppNotificationPayload(
          kind: AppNotificationKind.message,
          peerId: '',
          businessId: 'message-1',
        ),
        recalled: false,
        peerMismatch: false,
      ),
      NotificationActivation.ignore,
    );
  });

  test('navigation keeps only the latest click until it is ready', () {
    final queue = NotificationLaunchQueue();
    const first = AppNotificationPayload(
      kind: AppNotificationKind.message,
      peerId: 'a',
      businessId: '1',
    );
    const second = AppNotificationPayload(
      kind: AppNotificationKind.message,
      peerId: 'b',
      businessId: '2',
    );
    queue.remember(first);
    queue.remember(second);
    expect(queue.take(), isNull);
    queue.markReady();
    expect(queue.take()!.businessId, '2');
    expect(queue.take(), isNull);
  });
}
