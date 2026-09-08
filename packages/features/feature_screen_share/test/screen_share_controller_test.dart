import 'dart:async';

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  const realtimeId = '00112233445566778899aabbccddeeff';
  final issued = DateTime.utc(2026, 1, 1, 12);

  late _FakeConsentPort consent;
  late _FakeMediaPort media;
  late ScreenShareController controller;

  setUp(() {
    consent = _FakeConsentPort();
    media = _FakeMediaPort();
    controller = ScreenShareController(
      consentPort: consent,
      mediaPort: media,
      realtimeId: realtimeId,
      generation: 7,
      localPeerId: 'local-peer',
      remotePeerId: 'remote-peer',
      now: () => issued,
    );
  });

  tearDown(() => controller.dispose());

  test(
    'outgoing capture waits for remote acceptance and media readiness',
    () async {
      await controller.startOutgoing(operationId: 'operation-a');
      expect(controller.state, ScreenShareOperationState.outgoingPending);
      expect(consent.sent.single.decision, RealtimeConsentDecision.request);

      await controller.setMediaReady(true);
      expect(media.captureStarts, isEmpty);

      consent.emit(
        _consent(
          issued: issued,
          expires: issued.add(const Duration(minutes: 1)),
          decision: RealtimeConsentDecision.accept,
          senderPeerId: 'remote-peer',
          actionRevision: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, ScreenShareOperationState.active);
      expect(media.captureStarts, ['operation-a']);
    },
  );

  test(
    'incoming request requires explicit acceptance before viewer starts',
    () async {
      await controller.setMediaReady(true);
      consent.emit(
        _consent(
          issued: issued,
          expires: issued.add(const Duration(minutes: 1)),
          decision: RealtimeConsentDecision.request,
          senderPeerId: 'remote-peer',
          actionRevision: 1,
          operationId: 'incoming-a',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, ScreenShareOperationState.incomingPending);
      expect(media.viewerStarts, isEmpty);
      await controller.acceptIncoming();

      expect(controller.state, ScreenShareOperationState.active);
      expect(consent.sent.last.decision, RealtimeConsentDecision.accept);
      expect(media.viewerStarts, ['incoming-a']);
    },
  );

  test(
    'duplicate and stale consent are ignored by operation and generation',
    () async {
      consent.emit(
        _consent(
          issued: issued,
          expires: issued.add(const Duration(minutes: 1)),
          decision: RealtimeConsentDecision.request,
          senderPeerId: 'remote-peer',
          actionRevision: 1,
          operationId: 'incoming-a',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      consent.emit(
        _consent(
          issued: issued,
          expires: issued.add(const Duration(minutes: 1)),
          decision: RealtimeConsentDecision.request,
          senderPeerId: 'remote-peer',
          actionRevision: 1,
          operationId: 'incoming-a',
        ),
      );
      consent.emit(
        _consent(
          issued: issued,
          expires: issued.add(const Duration(minutes: 1)),
          decision: RealtimeConsentDecision.request,
          senderPeerId: 'remote-peer',
          actionRevision: 1,
          operationId: 'incoming-b',
          generation: 8,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, ScreenShareOperationState.incomingPending);
      expect(controller.operationId, 'incoming-a');
    },
  );

  test('non-contiguous remote action revision fails closed', () async {
    await controller.startOutgoing(operationId: 'operation-a');
    consent.emit(
      _consent(
        issued: issued,
        expires: issued.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.accept,
        senderPeerId: 'remote-peer',
        actionRevision: 2,
        operationId: 'operation-a',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ScreenShareOperationState.accepted);

    consent.emit(
      _consent(
        issued: issued,
        expires: issued.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.cancel,
        senderPeerId: 'remote-peer',
        actionRevision: 4,
        operationId: 'operation-a',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ScreenShareOperationState.failed);
  });

  test('expiration and cancellation stop an active operation', () async {
    await controller.startOutgoing(operationId: 'operation-a');
    await controller.setMediaReady(true);
    consent.emit(
      _consent(
        issued: issued,
        expires: issued.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.accept,
        senderPeerId: 'remote-peer',
        actionRevision: 1,
        operationId: 'operation-a',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ScreenShareOperationState.active);

    await controller.cancel();
    expect(controller.state, ScreenShareOperationState.cancelled);
    expect(media.stops, ['operation-a']);
    expect(consent.sent.last.decision, RealtimeConsentDecision.cancel);
  });
}

RealtimeConsent _consent({
  required DateTime issued,
  required DateTime expires,
  required RealtimeConsentDecision decision,
  required String senderPeerId,
  required int actionRevision,
  String operationId = 'operation-a',
  int generation = 7,
}) => RealtimeConsent(
  operationId: operationId,
  realtimeId: '00112233445566778899aabbccddeeff',
  generation: generation,
  issuedAt: issued,
  expiresAt: expires,
  decision: decision,
  senderPeerId: senderPeerId,
  actionRevision: actionRevision,
);

final class _FakeConsentPort implements ScreenShareConsentPort {
  final StreamController<RealtimeConsent> _controller =
      StreamController<RealtimeConsent>.broadcast();
  final List<RealtimeConsent> sent = <RealtimeConsent>[];

  @override
  Stream<RealtimeConsent> get consents => _controller.stream;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async {
    sent.add(consent);
    return const SdkSuccess<void>(null);
  }

  void emit(RealtimeConsent consent) => _controller.add(consent);
}

final class _FakeMediaPort implements ScreenShareMediaPort {
  final StreamController<ScreenShareMediaEvent> _controller =
      StreamController<ScreenShareMediaEvent>.broadcast();
  final List<String> captureStarts = <String>[];
  final List<String> viewerStarts = <String>[];
  final List<String> stops = <String>[];

  @override
  Stream<ScreenShareMediaEvent> get events => _controller.stream;

  @override
  Future<void> startCapture({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) async => captureStarts.add(operationId);

  @override
  Future<void> startViewer({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) async => viewerStarts.add(operationId);

  @override
  Future<void> stop({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) async => stops.add(operationId);
}
