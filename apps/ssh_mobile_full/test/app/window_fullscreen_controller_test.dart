import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/window_fullscreen_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'missing native platform leaves no window lease to trap navigation',
    () async {
      final platform = _Platform()..missing = true;
      final controller = AppWindowFullscreenController(platform: platform);
      await controller.setFullscreen(true);
      expect(controller.failure, AppFullscreenFailure.enter);
      expect(controller.needsRestore, isFalse);
      expect(controller.fullscreen, isFalse);
      await controller.close();
    },
  );

  test('platform refusal is an explicit failure', () async {
    const channel = MethodChannel('ssh_mobile/window_presentation');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await expectLater(
      const MethodChannelAppWindowPresentation().setFullscreen(
        leaseId: 3,
        enabled: true,
      ),
      throwsStateError,
    );
  });

  test(
    'platform channel carries only the exact window lease and intent',
    () async {
      const channel = MethodChannel('ssh_mobile/window_presentation');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const platform = MethodChannelAppWindowPresentation();
      await platform.setFullscreen(leaseId: 17, enabled: true);
      await platform.setFullscreen(leaseId: 17, enabled: false);
      expect(calls.map((call) => call.method), everyElement('setFullscreen'));
      expect(calls.map((call) => call.arguments), [
        {'lease_id': 17, 'enabled': true},
        {'lease_id': 17, 'enabled': false},
      ]);
    },
  );

  test(
    'serializes rapid toggles and restores the same acquired lease',
    () async {
      final entered = Completer<void>();
      final platform = _Platform()..entering = entered.future;
      final controller = AppWindowFullscreenController(platform: platform);
      final pending = controller.setFullscreen(true);
      expect(controller.busy, isTrue);
      expect(controller.fullscreen, isFalse);
      final cancelled = controller.setFullscreen(false);
      expect(platform.calls.length, 1);
      entered.complete();
      await Future.wait([pending, cancelled]);
      expect(controller.fullscreen, isFalse);
      expect(controller.busy, isFalse);
      expect(platform.calls.map((call) => call.$2), [true, false]);
      expect(platform.calls.first.$1, platform.calls.last.$1);
      await controller.setFullscreen(true);
      expect(controller.fullscreen, isTrue);
      expect(platform.calls.last.$1, isNot(platform.calls.first.$1));
      await controller.close();
      expect(platform.calls.last.$2, isFalse);
    },
  );

  test(
    'disposal compensates a late native enter without notifying disposed UI',
    () async {
      final entered = Completer<void>();
      final platform = _Platform()..entering = entered.future;
      final controller = AppWindowFullscreenController(platform: platform);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final pending = controller.setFullscreen(true);
      final closing = controller.close();
      final before = notifications;
      entered.complete();
      await Future.wait([pending, closing]);
      expect(notifications, before);
      expect(platform.calls.map((call) => call.$2), [true, false]);
      await controller.setFullscreen(true);
      controller.dispose();
      expect(platform.calls.length, 2);
    },
  );

  test('a new enter waits for the previous restore to finish', () async {
    final restored = Completer<void>();
    final platform = _Platform();
    final controller = AppWindowFullscreenController(platform: platform);
    await controller.setFullscreen(true);
    final firstLease = platform.calls.single.$1;
    platform.exiting = restored.future;
    final leaving = controller.setFullscreen(false);
    final reentering = controller.setFullscreen(true);
    expect(platform.calls.map((call) => call.$2), [true, false]);
    restored.complete();
    await Future.wait([leaving, reentering]);
    expect(controller.fullscreen, isTrue);
    expect(platform.calls.map((call) => call.$2), [true, false, true]);
    expect(platform.calls.last.$1, isNot(firstLease));
    await controller.close();
  });

  test(
    'failed native enter compensates partial state and reports failure',
    () async {
      final platform = _Platform()..failEnter = true;
      final controller = AppWindowFullscreenController(platform: platform);
      await controller.setFullscreen(true);
      expect(controller.fullscreen, isFalse);
      expect(controller.failure, AppFullscreenFailure.enter);
      expect(platform.calls.map((call) => call.$2), [true, false]);
      await controller.close();
    },
  );

  test('failed restoration retains its lease for an explicit retry', () async {
    final platform = _Platform();
    final controller = AppWindowFullscreenController(platform: platform);
    await controller.setFullscreen(true);
    platform.failExit = true;
    await controller.setFullscreen(false);
    expect(controller.fullscreen, isTrue);
    expect(controller.failure, AppFullscreenFailure.restore);
    platform.failExit = false;
    await controller.setFullscreen(false);
    expect(controller.fullscreen, isFalse);
    expect(controller.failure, isNull);
    expect(platform.calls.map((call) => call.$1).toSet().length, 1);
    await controller.close();
  });
}

class _Platform implements AppWindowPresentationPlatform {
  final calls = <(int, bool)>[];
  Future<void>? entering;
  Future<void>? exiting;
  bool failEnter = false;
  bool failExit = false;
  bool missing = false;
  @override
  Future<void> setFullscreen({
    required int leaseId,
    required bool enabled,
  }) async {
    calls.add((leaseId, enabled));
    if (missing) throw MissingPluginException();
    if (enabled) {
      await entering;
      if (failEnter) throw StateError('enter');
    } else {
      await exiting;
      if (failExit) throw StateError('restore');
    }
  }
}
