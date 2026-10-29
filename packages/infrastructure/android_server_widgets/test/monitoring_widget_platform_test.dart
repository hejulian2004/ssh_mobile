import 'package:android_server_widgets/android_server_widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ssh_mobile/android_server_widgets');
  const platform = MethodChannelMonitoringWidgets();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'beginSession' ? 'writer-a' : null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('session and ordered safe batch cross the plugin channel', () async {
    final session = await platform.beginSession();
    expect(session, 'writer-a');
    await platform.synchronize(
      session: session,
      sequence: 2,
      servers: [
        MonitoringWidgetServer(connectionId: 'a', displayName: 'Compute A'),
      ],
      snapshots: [],
      invalidatedBefore: {'a': 1},
      reset: true,
    );
    expect(calls.map((call) => call.method), ['beginSession', 'synchronize']);
    expect(calls.last.arguments, {
      'session': 'writer-a',
      'sequence': 2,
      'servers': [
        {'connectionId': 'a', 'displayName': 'Compute A'},
      ],
      'snapshots': [],
      'invalidatedBefore': {'a': 1},
      'reset': true,
    });
  });

  test('missing native session is an explicit error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    await expectLater(platform.beginSession(), throwsStateError);
  });
}
