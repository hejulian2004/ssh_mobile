import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/screen_share_picture_in_picture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('publishes the latest session and mirrors mode once', () async {
    final platform = _Platform();
    final pip = AppScreenSharePictureInPicture(platform: platform);
    final modes = <bool>[];
    pip.addListener(() => modes.add(pip.active));
    final gate = Completer<void>();
    platform.block = gate;
    pip.update(const AppPictureInPictureSession(width: 16, height: 9));
    pip.update(const AppPictureInPictureSession(width: 4, height: 3));
    pip.update(const AppPictureInPictureSession(width: 4, height: 3));
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(
      platform.sessions.map((session) => (session?.width, session?.height)),
      [(16.0, 9.0), (4.0, 3.0)],
    );
    final applied = platform.attempts;
    pip.update(const AppPictureInPictureSession(width: 4, height: 3));
    await Future<void>.delayed(Duration.zero);
    expect(platform.attempts, applied);
    platform.listener!(true);
    platform.listener!(true);
    expect(pip.active, isTrue);
    expect(modes, [true]);
    pip.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(platform.sessions.last, isNull);
    expect(platform.bound, isFalse);
  });

  test('a platform error can be retried without a tight loop', () async {
    final platform = _Platform()..failOnce = true;
    final pip = AppScreenSharePictureInPicture(platform: platform);
    const session = AppPictureInPictureSession(width: 2, height: 1);
    pip.update(session);
    await Future<void>.delayed(Duration.zero);
    expect(platform.attempts, 1);
    expect(platform.sessions, isEmpty);
    pip.update(session);
    await Future<void>.delayed(Duration.zero);
    expect(platform.sessions.single?.width, 2);
    pip.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(platform.sessions.last, isNull);
  });

  test(
    'the method channel publishes a session and receives mode changes',
    () async {
      const channel = MethodChannel('ssh_mobile/screen_share_pip_round_trip');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final pip = AppScreenSharePictureInPicture(
        platform: MethodChannelAppPictureInPicture(channel: channel),
      );
      pip.update(const AppPictureInPictureSession(width: 8, height: 3));
      await Future<void>.delayed(Duration.zero);
      expect(calls.single.method, 'setSession');
      expect(calls.single.arguments, {'width': 8.0, 'height': 3.0});
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onModeChanged', true),
        ),
        (data) {},
      );
      expect(pip.active, isTrue);
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('ignored', null),
        ),
        (data) {},
      );
      expect(pip.active, isTrue);
      pip.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.method, 'setSession');
      expect(calls.last.arguments, isNull);
    },
  );

  test('a missing plugin disables later updates', () async {
    const channel = MethodChannel('ssh_mobile/screen_share_pip_missing');
    final pip = AppScreenSharePictureInPicture(
      platform: MethodChannelAppPictureInPicture(channel: channel),
    );
    pip.update(const AppPictureInPictureSession(width: 2, height: 1));
    await Future<void>.delayed(Duration.zero);
    pip.update(null);
    await Future<void>.delayed(Duration.zero);
    pip.dispose();
  });
}

class _Platform implements AppPictureInPicturePlatform {
  final sessions = <AppPictureInPictureSession?>[];
  var attempts = 0;
  var failOnce = false;
  var bound = false;
  Completer<void>? block;
  void Function(bool active)? listener;

  @override
  Future<void> setSession(AppPictureInPictureSession? session) async {
    attempts += 1;
    final gate = block;
    block = null;
    if (gate != null) await gate.future;
    if (failOnce) {
      failOnce = false;
      throw StateError('unavailable');
    }
    sessions.add(session);
  }

  @override
  void bind(void Function(bool active) onModeChanged) {
    bound = true;
    listener = onModeChanged;
  }

  @override
  void unbind() {
    bound = false;
    listener = null;
  }
}
