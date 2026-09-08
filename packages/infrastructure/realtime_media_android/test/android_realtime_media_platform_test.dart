import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:realtime_media_android/src/method_channel_android_realtime_media_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ssh_mobile/realtime_media/android');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('maps projection denial to permissionDenied', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'permission_denied',
        message: 'projection was denied',
      );
    });

    const platform = MethodChannelAndroidRealtimeMediaPlatform();
    await expectLater(
      platform.requestProjection(),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.permissionDenied,
        ),
      ),
    );
  });

  test('maps projection revoke to permissionDenied', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'projection_revoked',
        message: 'projection stopped',
      );
    });

    const platform = MethodChannelAndroidRealtimeMediaPlatform();
    await expectLater(
      platform.requestProjection(),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.permissionDenied,
        ),
      ),
    );
  });

  test('maps hardware codec failures to typed errors', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: call.method == 'startCapture'
            ? 'encoder_unavailable'
            : 'decoder_unavailable',
      );
    });

    const platform = MethodChannelAndroidRealtimeMediaPlatform();
    final identity = RealtimeMediaEndpointIdentity(
      realtimeId: 'realtime-1',
      peerId: 'peer-1',
      generation: 1,
      direction: RealtimeMediaDirection.send,
    );
    await expectLater(
      platform.startCapture(
        endpointId: RealtimeMediaEndpointId('endpoint-1'),
        identity: identity,
        source: ScreenCaptureSource(
          id: ScreenCaptureSourceId('display:default'),
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

    await expectLater(
      platform.attachRemoteVideoSurface(
        endpointId: RealtimeMediaEndpointId('endpoint-2'),
        identity: identity.copyWithDirection(RealtimeMediaDirection.receive),
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.decoderUnavailable,
        ),
      ),
    );
  });

  test('forwards generation-bound recovery commands', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    const platform = MethodChannelAndroidRealtimeMediaPlatform();
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

extension on RealtimeMediaEndpointIdentity {
  RealtimeMediaEndpointIdentity copyWithDirection(
    RealtimeMediaDirection direction,
  ) => RealtimeMediaEndpointIdentity(
    realtimeId: realtimeId,
    peerId: peerId,
    generation: generation,
    direction: direction,
  );
}
