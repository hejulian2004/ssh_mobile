import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';

import 'package:ssh_mobile/app/screen_share_feature_adapters.dart';

void main() {
  test(
    'media failure logs only its typed code and preserves the error',
    () async {
      final logger = _MediaLogger();
      const failure = RealtimeMediaException(
        RealtimeMediaErrorCode.encoderUnavailable,
        'private-payload',
      );
      final port = AppScreenShareMediaPort(
        logger: logger,
        events: const Stream.empty(),
        onStartCapture:
            ({
              required operationId,
              required realtimeId,
              required generation,
            }) async => throw failure,
        onStartViewer:
            ({
              required operationId,
              required realtimeId,
              required generation,
            }) async {},
        onStop:
            ({
              required operationId,
              required realtimeId,
              required generation,
            }) async {},
      );
      await expectLater(
        port.startCapture(
          operationId: 'operation-a',
          realtimeId: 'session-a',
          generation: 1,
        ),
        throwsA(same(failure)),
      );
      expect(logger.messages, [
        'Screen-share media capture failed: encoderUnavailable',
      ]);
    },
  );
  const realtimeId = '00112233445566778899aabbccddeeff';
  final issued = DateTime.utc(2030, 1, 1, 12);
  final consent = RealtimeConsent(
    operationId: 'operation-a',
    realtimeId: realtimeId,
    sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
    issuedAt: issued,
    expiresAt: issued.add(const Duration(minutes: 1)),
    decision: RealtimeConsentDecision.request,
    senderPeerId: 'peer-a',
    actionRevision: 1,
  );

  test('consent port forwards the typed stream and send operation', () async {
    final events = StreamController<RealtimeConsent>.broadcast();
    addTearDown(events.close);
    final sent = <RealtimeConsent>[];
    final session = _FakeRealtimeSession(
      realtimeId: realtimeId,
      peerId: 'peer-a',
      consentStream: events.stream,
      onSendConsent: (value) async {
        sent.add(value);
        return const SdkSuccess<void>(null);
      },
    );
    final port = AppScreenShareConsentPort(session);

    expect(port.consents, isA<Stream<RealtimeConsent>>());
    final received = port.consents.first;
    events.add(consent);
    expect(await received, consent);

    expect(await port.sendConsent(consent), isA<SdkSuccess<void>>());
    expect(sent, [consent]);
  });

  test('media port forwards opaque lifecycle callbacks and events', () async {
    final events = StreamController<ScreenShareMediaEvent>.broadcast();
    addTearDown(events.close);
    final calls = <String>[];
    final port = AppScreenShareMediaPort(
      events: events.stream,
      onStartCapture:
          ({
            required operationId,
            required realtimeId,
            required generation,
          }) async {
            calls.add('capture:$operationId:$realtimeId:$generation');
          },
      onStartViewer:
          ({
            required operationId,
            required realtimeId,
            required generation,
          }) async {
            calls.add('viewer:$operationId:$realtimeId:$generation');
          },
      onStop:
          ({
            required operationId,
            required realtimeId,
            required generation,
          }) async {
            calls.add('stop:$operationId:$realtimeId:$generation');
          },
    );

    expect(port.events, isA<Stream<ScreenShareMediaEvent>>());
    final event = ScreenShareMediaEvent(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
      kind: ScreenShareMediaEventKind.stopped,
    );
    final received = port.events.first;
    events.add(event);
    expect(await received, event);

    await port.startCapture(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    await port.startViewer(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    await port.stop(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );

    expect(calls, [
      'capture:operation-a:$realtimeId:7',
      'viewer:operation-a:$realtimeId:7',
      'stop:operation-a:$realtimeId:7',
    ]);
  });
}

final class _MediaLogger implements AppLogger {
  final messages = <String>[];
  @override
  void log(LogRecord record) => messages.add(record.message);
  @override
  AppLogger scope(String name) => this;
}

final class _FakeRealtimeSession implements RealtimeSession {
  _FakeRealtimeSession({
    required this.realtimeId,
    required this.peerId,
    required this.consentStream,
    required this.onSendConsent,
  });

  @override
  final String realtimeId;

  @override
  final String peerId;

  @override
  String? get sharedSessionInstanceId => '00112233445566778899aabbccddeeff';

  final Stream<RealtimeConsent> consentStream;
  final Future<SdkResult<void>> Function(RealtimeConsent) onSendConsent;

  @override
  RealtimeSessionState get state => RealtimeSessionState.idle;

  @override
  int get revision => 0;

  @override
  int? get generation => 7;

  @override
  RealtimeSessionToken get mediaToken => const RealtimeSessionToken(
    realtimeId: '00112233445566778899aabbccddeeff',
    peerId: 'peer-a',
    generation: 7,
  );

  @override
  RealtimeAudioState get audioState => RealtimeAudioState.unavailable;

  @override
  RealtimeSnapshot? get currentSnapshot => null;

  @override
  Stream<RealtimeSnapshot> get snapshots =>
      const Stream<RealtimeSnapshot>.empty();

  @override
  Stream<RealtimeConsent> get consentEvents => consentStream;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent value) =>
      onSendConsent(value);

  @override
  Future<SdkResult<void>> start() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess<void>(null);
}
