import 'dart:async';

import 'package:android_server_widgets/android_server_widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ssh_mobile/android_server_widgets');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const payload = {'connectionId': 'server-a', 'requestId': 'request-a'};
  Future<void> emit(
    Object? arguments, {
    String method = 'openMonitoring',
  }) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => done.complete(),
    );
    await done.future;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('cold and warm requests cross only the navigation channel', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return payload;
    });
    final received = <MonitoringWidgetOpenRequest>[];
    final port = MonitoringWidgetNavigationChannel();
    await port.start(received.add);
    await port.start(received.add);
    await emit({'connectionId': 'server-b', 'requestId': 'request-b'});
    await emit(payload, method: 'unrelated');
    expect(calls, ['takePendingNavigation']);
    expect(received.map((request) => request.connectionId), [
      'server-a',
      'server-b',
    ]);
    await port.dispose();
    await port.dispose();
    await expectLater(port.start(received.add), throwsStateError);
  });

  test('malformed and oversized intent payloads are ignored', () async {
    for (final value in [
      null,
      '',
      {},
      {'connectionId': 'x', 'requestId': ''},
      {'connectionId': 'operator@example.invalid', 'requestId': 'a'},
      {'connectionId': 'a', 'requestId': 'x' * 65},
    ]) {
      expect(MonitoringWidgetOpenRequest.tryParse(value), isNull);
    }
    expect(
      MonitoringWidgetOpenRequest.tryParse(payload)?.requestId,
      'request-a',
    );
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final received = <MonitoringWidgetOpenRequest>[];
    final port = MonitoringWidgetNavigationChannel();
    await port.start(received.add);
    await emit({'connectionId': 1});
    expect(received, isEmpty);
    await port.dispose();
  });

  test(
    'late startup and stale owner disposal cannot affect a new owner',
    () async {
      final gate = Completer<Map<String, String>>();
      var takes = 0;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => ++takes == 1 ? gate.future : null,
      );
      final stale = <MonitoringWidgetOpenRequest>[];
      final live = <MonitoringWidgetOpenRequest>[];
      final old = MonitoringWidgetNavigationChannel();
      final pending = old.start(stale.add);
      final current = MonitoringWidgetNavigationChannel();
      await current.start(live.add);
      await old.dispose();
      gate.complete(payload);
      await pending;
      await emit(payload);
      expect(stale, isEmpty);
      expect(live.single.connectionId, 'server-a');
      await current.dispose();
    },
  );
}
