import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:realtime_media_windows/src/method_channel_windows_realtime_media_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ssh_mobile/realtime_media/windows');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'maps native encoder-unavailable failure to typed media error',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'encoder_unavailable',
          message: 'hardware H.264 MFT unavailable',
        );
      });

      const platform = MethodChannelWindowsRealtimeMediaPlatform();
      await expectLater(
        platform.startCapture(
          endpointId: RealtimeMediaEndpointId('endpoint-1'),
          identity: RealtimeMediaEndpointIdentity(
            realtimeId: 'realtime-1',
            peerId: 'peer-1',
            generation: 1,
            direction: RealtimeMediaDirection.send,
          ),
          source: ScreenCaptureSource(
            id: ScreenCaptureSourceId('display:1'),
            kind: ScreenCaptureSourceKind.display,
          ),
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.encoderUnavailable,
          ),
        ),
      );
    },
  );

  test(
    'maps native decoder-unavailable surface failure to typed media error',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'decoder_unavailable',
          message: 'hardware H.264 decoder unavailable',
        );
      });

      const platform = MethodChannelWindowsRealtimeMediaPlatform();
      await expectLater(
        platform.attachRemoteVideoSurface(
          endpointId: RealtimeMediaEndpointId('endpoint-1'),
          identity: RealtimeMediaEndpointIdentity(
            realtimeId: 'realtime-1',
            peerId: 'peer-1',
            generation: 1,
            direction: RealtimeMediaDirection.receive,
          ),
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.decoderUnavailable,
          ),
        ),
      );
    },
  );

  test('forwards generation-bound recovery commands', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    const platform = MethodChannelWindowsRealtimeMediaPlatform();
    final identity = RealtimeMediaEndpointIdentity(
      realtimeId: 'realtime-1',
      peerId: 'peer-1',
      generation: 9,
      direction: RealtimeMediaDirection.receive,
    );

    await platform.requestKeyframe(
      endpointId: RealtimeMediaEndpointId('endpoint-1'),
      identity: identity,
      ownerToken: RealtimeMediaNativeOwnerToken('owner-1'),
    );
    await platform.resetDecoder(
      endpointId: RealtimeMediaEndpointId('endpoint-1'),
      identity: identity,
      ownerToken: RealtimeMediaNativeOwnerToken('owner-1'),
    );

    expect(calls.map((call) => call.method), <String>[
      'requestKeyframe',
      'resetDecoder',
    ]);
    expect((calls.first.arguments as Map)['generation'], 9);
    expect((calls.last.arguments as Map)['direction'], 'receive');
  });
}
