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

  test(
    'maps failed adaptation rollback to a recreate-required error',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'recreate_required',
          message: 'adaptation rollback failed',
        );
      });

      const platform = MethodChannelAndroidRealtimeMediaPlatform();
      await expectLater(
        platform.applyAdaptation(
          endpointId: RealtimeMediaEndpointId('endpoint-1'),
          identity: RealtimeMediaEndpointIdentity(
            realtimeId: 'realtime-1',
            peerId: 'peer-1',
            generation: 1,
            direction: RealtimeMediaDirection.send,
          ),
          decision: const RealtimeMediaAdaptationDecision(
            bitrateKbps: 1536,
            framerate: 7,
            width: 1280,
            height: 720,
            reason: RealtimeMediaAdaptationReason.congestion,
          ),
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.recreateRequired,
          ),
        ),
      );
    },
  );

  test('maps deferred worker cleanup to a retryable typed error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'cleanup_deferred',
        message: 'encoder worker has not acknowledged stop',
      );
    });

    const platform = MethodChannelAndroidRealtimeMediaPlatform();
    await expectLater(
      platform.detach(
        endpointId: RealtimeMediaEndpointId('endpoint-1'),
        identity: RealtimeMediaEndpointIdentity(
          realtimeId: 'realtime-1',
          peerId: 'peer-1',
          generation: 1,
          direction: RealtimeMediaDirection.send,
        ),
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.cleanupDeferred,
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

  test('forwards bounded adaptation without media payloads', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return null;
    });
    const platform = MethodChannelAndroidRealtimeMediaPlatform();
    final identity = RealtimeMediaEndpointIdentity(
      realtimeId: 'realtime-1',
      peerId: 'peer-1',
      generation: 9,
      direction: RealtimeMediaDirection.send,
    );

    await platform.applyAdaptation(
      endpointId: RealtimeMediaEndpointId('endpoint-1'),
      identity: identity,
      ownerToken: RealtimeMediaNativeOwnerToken('owner-1'),
      decision: const RealtimeMediaAdaptationDecision(
        bitrateKbps: 1536,
        framerate: 7,
        width: 1280,
        height: 720,
        reason: RealtimeMediaAdaptationReason.congestion,
      ),
    );

    expect(captured?.method, 'applyAdaptation');
    final arguments = captured?.arguments as Map;
    expect(arguments['generation'], 9);
    expect(arguments['bitrate_kbps'], 1536);
    expect(arguments['framerate'], 7);
    expect(arguments['width'], 1280);
    expect(arguments['height'], 720);
    expect(arguments['reason'], 'congestion');
    expect(arguments.keys, isNot(contains('payload')));
  });

  test('decodes bounded native queue and recovery statistics', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readStats');
      return <String, Object?>{
        'width': 1920,
        'height': 1080,
        'frames_captured': 12,
        'frames_sent': 11,
        'frames_dropped': 2,
        'frames_decoded': 0,
        'frames_rendered': 0,
        'packets_sent': 24,
        'packets_received': 20,
        'packets_lost': 2,
        'frames_recovered': 1,
        'keyframe_requests': 3,
        'jitter_ms': 7,
        'rtt_ms': 0,
        'queue_depth': 2,
        'queue_capacity': 3,
      };
    });

    const platform = MethodChannelAndroidRealtimeMediaPlatform();
    final stats = await platform.readStats(
      endpointId: RealtimeMediaEndpointId('endpoint-1'),
      identity: RealtimeMediaEndpointIdentity(
        realtimeId: 'realtime-1',
        peerId: 'peer-1',
        generation: 9,
        direction: RealtimeMediaDirection.send,
      ),
      ownerToken: RealtimeMediaNativeOwnerToken('owner-1'),
    );

    expect(stats.framesDropped, 2);
    expect(stats.packetsSent, 24);
    expect(stats.packetsReceived, 20);
    expect(stats.packetsLost, 2);
    expect(stats.framesRecovered, 1);
    expect(stats.keyframeRequests, 3);
    expect(stats.jitterMs, 7);
    expect(stats.queueDepth, 2);
    expect(stats.queueCapacity, 3);
  });

  test(
    'fails closed when native queue statistics exceed the fixed bound',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{'queue_depth': 4, 'queue_capacity': 3};
      });

      const platform = MethodChannelAndroidRealtimeMediaPlatform();
      await expectLater(
        platform.readStats(
          endpointId: RealtimeMediaEndpointId('endpoint-1'),
          identity: RealtimeMediaEndpointIdentity(
            realtimeId: 'realtime-1',
            peerId: 'peer-1',
            generation: 9,
            direction: RealtimeMediaDirection.send,
          ),
        ),
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.backendFailure,
          ),
        ),
      );
    },
  );
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
