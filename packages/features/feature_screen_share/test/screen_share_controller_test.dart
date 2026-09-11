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
      sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
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
    'invalid outgoing operation IDs do not partially enter pending state',
    () async {
      await expectLater(
        controller.startOutgoing(operationId: ' '),
        throwsA(isA<ArgumentError>()),
      );
      expect(controller.state, ScreenShareOperationState.idle);
      expect(consent.sent, isEmpty);
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

  test('duplicate and unknown-operation requests are ignored', () async {
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
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ScreenShareOperationState.incomingPending);
    expect(controller.operationId, 'incoming-a');
  });

  test(
    'shared-session consent acceptance uses the current realtime identity',
    () async {
      await controller.setMediaReady(true);
      await controller.startOutgoing(operationId: 'operation-a');
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

  test('non-contiguous remote action revision fails closed', () async {
    await controller.startOutgoing(operationId: 'operation-a');
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
    expect(controller.state, ScreenShareOperationState.accepted);

    consent.emit(
      _consent(
        issued: issued,
        expires: issued.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.cancel,
        senderPeerId: 'remote-peer',
        actionRevision: 3,
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

  test(
    'cancel received while acceptance is in flight cannot resurrect viewer',
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

      final acceptance = Completer<SdkResult<void>>();
      consent.nextSend = acceptance;
      final acceptFuture = controller.acceptIncoming();
      await Future<void>.delayed(Duration.zero);
      consent.emit(
        _consent(
          issued: issued,
          expires: issued.add(const Duration(minutes: 1)),
          decision: RealtimeConsentDecision.cancel,
          senderPeerId: 'remote-peer',
          actionRevision: 2,
          operationId: 'incoming-a',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      acceptance.complete(const SdkSuccess<void>(null));
      await acceptFuture;

      expect(controller.state, ScreenShareOperationState.cancelled);
      expect(media.viewerStarts, isEmpty);
    },
  );

  test(
    'media readiness loss invalidates a stale capture completion and compensates',
    () async {
      await controller.startOutgoing(operationId: 'operation-a');
      media.captureGate = Completer<void>();
      await controller.setMediaReady(true);
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
      expect(media.captureStarts, ['operation-a']);

      await controller.setMediaReady(false);
      media.captureGate!.complete();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, ScreenShareOperationState.accepted);
      expect(controller.mediaReady, isFalse);
      expect(media.stops, ['operation-a']);
    },
  );

  test('cross-device consent ignores independent native generations', () async {
    final wire = _ConsentWire();
    final peerAMedia = _FakeMediaPort();
    final peerBMedia = _FakeMediaPort();
    final peerA = ScreenShareController(
      consentPort: _WireConsentPort(wire),
      mediaPort: peerAMedia,
      realtimeId: realtimeId,
      sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
      generation: 3,
      localPeerId: 'peer-a',
      remotePeerId: 'peer-b',
      now: () => issued,
    );
    final peerB = ScreenShareController(
      consentPort: _WireConsentPort(wire),
      mediaPort: peerBMedia,
      realtimeId: realtimeId,
      sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
      generation: 17,
      localPeerId: 'peer-b',
      remotePeerId: 'peer-a',
      now: () => issued,
    );
    try {
      await peerA.startOutgoing(operationId: 'cross-device-operation');
      await Future<void>.delayed(Duration.zero);
      expect(peerB.state, ScreenShareOperationState.incomingPending);

      await peerA.setMediaReady(true);
      await peerB.setMediaReady(true);
      await peerB.acceptIncoming();
      await Future<void>.delayed(Duration.zero);
      expect(peerA.state, ScreenShareOperationState.active);
      expect(peerB.state, ScreenShareOperationState.active);
      expect(peerAMedia.captureStarts, ['cross-device-operation']);
      expect(peerBMedia.viewerStarts, ['cross-device-operation']);

      await peerA.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(peerA.state, ScreenShareOperationState.cancelled);
      expect(peerB.state, ScreenShareOperationState.cancelled);
      expect(
        wire.sent.every((consent) => consent.realtimeId == realtimeId),
        isTrue,
      );
    } finally {
      peerA.dispose();
      peerB.dispose();
      await wire.close();
    }
  });
}

RealtimeConsent _consent({
  required DateTime issued,
  required DateTime expires,
  required RealtimeConsentDecision decision,
  required String senderPeerId,
  required int actionRevision,
  String operationId = 'operation-a',
}) => RealtimeConsent(
  operationId: operationId,
  realtimeId: '00112233445566778899aabbccddeeff',
  sharedSessionInstanceId: '00112233445566778899aabbccddeeff',
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
  Completer<SdkResult<void>>? nextSend;

  @override
  Stream<RealtimeConsent> get consents => _controller.stream;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async {
    sent.add(consent);
    final delayed = nextSend;
    nextSend = null;
    if (delayed != null) return delayed.future;
    return const SdkSuccess<void>(null);
  }

  void emit(RealtimeConsent consent) => _controller.add(consent);
}

final class _ConsentWire {
  final StreamController<RealtimeConsent> controller =
      StreamController<RealtimeConsent>.broadcast();
  final List<RealtimeConsent> sent = <RealtimeConsent>[];

  Future<void> close() => controller.close();
}

final class _WireConsentPort implements ScreenShareConsentPort {
  _WireConsentPort(this.wire);

  final _ConsentWire wire;

  @override
  Stream<RealtimeConsent> get consents => wire.controller.stream;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async {
    wire.sent.add(consent);
    wire.controller.add(consent);
    return const SdkSuccess<void>(null);
  }
}

final class _FakeMediaPort implements ScreenShareMediaPort {
  final StreamController<ScreenShareMediaEvent> _controller =
      StreamController<ScreenShareMediaEvent>.broadcast();
  final List<String> captureStarts = <String>[];
  final List<String> viewerStarts = <String>[];
  final List<String> stops = <String>[];
  Completer<void>? captureGate;

  @override
  Stream<ScreenShareMediaEvent> get events => _controller.stream;

  @override
  Future<void> startCapture({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) async {
    captureStarts.add(operationId);
    final gate = captureGate;
    if (gate != null) await gate.future;
  }

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
