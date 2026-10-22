import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:realtime_media_android/realtime_media_android.dart';
import 'package:realtime_media_windows/realtime_media_windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platformName in ['android', 'windows']) {
    test(
      '$platformName preserves CPU choice across native lifecycle calls',
      () async {
        final channel = MethodChannel(
          'ssh_mobile/realtime_media/$platformName',
        );
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return call.method == 'attachRemoteVideoSurface'
                  ? {'surface_id': '1'}
                  : null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final dynamic platform = platformName == 'android'
            ? const MethodChannelAndroidRealtimeMediaPlatform()
            : const MethodChannelWindowsRealtimeMediaPlatform();
        final endpointId = RealtimeMediaEndpointId('fixture-endpoint');
        final owner = RealtimeMediaNativeOwnerToken('1');
        final send = RealtimeMediaEndpointIdentity(
          realtimeId: 'fixture-session',
          peerId: 'fixture-peer',
          generation: 1,
          direction: RealtimeMediaDirection.send,
          codecMode: RealtimeMediaCodecMode.cpu,
        );
        await platform.startCapture(
          endpointId: endpointId,
          identity: send,
          ownerToken: owner,
          source: ScreenCaptureSource(
            id: ScreenCaptureSourceId('display:default'),
            kind: ScreenCaptureSourceKind.display,
          ),
        );
        final receive = RealtimeMediaEndpointIdentity(
          realtimeId: 'fixture-session',
          peerId: 'fixture-peer',
          generation: 1,
          direction: RealtimeMediaDirection.receive,
          codecMode: RealtimeMediaCodecMode.cpu,
        );
        await platform.attachRemoteVideoSurface(
          endpointId: endpointId,
          identity: receive,
          ownerToken: owner,
        );
        await platform.detach(
          endpointId: endpointId,
          identity: receive,
          ownerToken: owner,
        );
        await platform.release(
          endpointId: endpointId,
          identity: receive,
          ownerToken: owner,
        );
        expect(calls.length, 4);
        for (final call in calls) {
          expect((call.arguments as Map)['codec_mode'], 'cpu');
        }
      },
    );
  }
}
