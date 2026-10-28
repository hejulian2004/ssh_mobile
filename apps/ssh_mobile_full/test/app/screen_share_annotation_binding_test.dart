import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/app/screen_share_annotation_binding.dart';

void main() {
  test(
    'closed channel disables drawing and denial does not end the share',
    () async {
      final realtime = _Realtime();
      final operation = _Operation(
        ScreenShareOperationSnapshot(
          state: ScreenShareOperationState.active,
          role: ScreenShareRole.receiver,
          realtimeId: 'realtime',
          generation: 4,
          operationId: 'operation-a',
          mediaReady: true,
        ),
      );
      final frame = ValueNotifier<Size?>(const Size(1080, 2400));
      final binding = AppScreenShareAnnotationBinding(
        realtime: realtime,
        operation: operation,
        snapshot: () => operation.snapshot,
        frameSize: frame,
        onChanged: () {},
      );
      binding.start();
      expect(binding.interactive, isTrue);
      expect(
        binding.session!.beginStroke(const ScreenShareAnnotationPoint(1, 2)),
        isFalse,
      );

      realtime.open = true;
      realtime.channel.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(binding.session!.canPaint, isTrue);
      expect(
        binding.session!.beginStroke(const ScreenShareAnnotationPoint(1, 2)),
        isTrue,
      );
      expect(binding.session!.endStroke(), isTrue);
      expect(realtime.sent, isNotEmpty);

      frame.value = const Size(1920, 1080);
      await Future<void>.delayed(Duration.zero);
      expect(binding.session!.strokes, isEmpty);
      final cleared = realtime.sent.map(ScreenShareAnnotationCodec.decode);
      expect(cleared.whereType<AnnotationClear>(), isNotEmpty);

      operation.snapshot = ScreenShareOperationSnapshot(
        state: ScreenShareOperationState.cancelled,
        role: ScreenShareRole.receiver,
        realtimeId: 'realtime',
        generation: 4,
        operationId: 'operation-a',
        mediaReady: false,
      );
      operation.notifyListeners();
      expect(binding.session, isNull);
      expect(binding.interactive, isFalse);
      binding.dispose();
      frame.dispose();
      await realtime.channel.close();
      await realtime.incoming.close();
    },
  );

  test('overlay denial publishes that the sender cannot show marks', () async {
    final realtime = _Realtime()..open = true;
    final operation = _Operation(
      ScreenShareOperationSnapshot(
        state: ScreenShareOperationState.active,
        role: ScreenShareRole.sender,
        realtimeId: 'realtime',
        generation: 4,
        operationId: 'operation-a',
        mediaReady: true,
      ),
    );
    final overlay = _Overlay();
    final binding = AppScreenShareAnnotationBinding(
      realtime: realtime,
      operation: operation,
      snapshot: () => operation.snapshot,
      frameSize: ValueNotifier<Size?>(const Size(1080, 2400)),
      overlay: overlay,
      onChanged: () {},
    );
    binding.start();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(binding.interactive, isFalse);
    expect(overlay.presented, greaterThan(0));
    expect(overlay.hidden, 0);
    final ready =
        ScreenShareAnnotationCodec.decode(realtime.sent.last)!
            as AnnotationDisplayReady;
    expect(ready.ready, isFalse);

    operation.snapshot = ScreenShareOperationSnapshot(
      state: ScreenShareOperationState.cancelled,
      role: ScreenShareRole.sender,
      realtimeId: 'realtime',
      generation: 4,
      operationId: 'operation-a',
      mediaReady: false,
    );
    operation.notifyListeners();
    await Future<void>.delayed(Duration.zero);
    expect(overlay.hidden, 1);
    binding.dispose();
    await realtime.channel.close();
    await realtime.incoming.close();
  });
}

final class _Operation extends ChangeNotifier {
  _Operation(this.snapshot);

  ScreenShareOperationSnapshot snapshot;
}

final class _Overlay implements ScreenShareGuidanceDisplay {
  int presented = 0;
  int hidden = 0;

  @override
  Future<bool> present(ScreenShareGuidanceFrame frame) async {
    presented += 1;
    return false;
  }

  @override
  Future<void> hide() async {
    hidden += 1;
  }
}

final class _Realtime extends Fake implements RealtimeSession {
  bool open = false;
  final StreamController<bool> channel = StreamController<bool>.broadcast();
  final StreamController<Uint8List> incoming =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> sent = <Uint8List>[];

  @override
  bool get applicationChannelOpen => open;

  @override
  Stream<bool> get applicationChannelEvents => channel.stream;

  @override
  Stream<Uint8List> get applicationData => incoming.stream;

  @override
  Future<SdkResult<void>> sendApplicationData(Uint8List payload) async {
    sent.add(Uint8List.fromList(payload));
    return const SdkSuccess<void>(null);
  }
}
