import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:feature_screen_share/feature_screen_share.dart';

import 'package:ssh_mobile/app/realtime_media_feature_adapters.dart';
import 'package:ssh_mobile/app/screen_share_route_scope.dart';

void main() {
  const realtimeId = '00112233445566778899aabbccddeeff';
  final source = ScreenCaptureSource(
    id: ScreenCaptureSourceId('display:1'),
    kind: ScreenCaptureSourceKind.display,
    label: 'Display 1',
    width: 1920,
    height: 1080,
  );

  late _RecordingMediaBackend backend;
  late _RecordingCapabilities capabilities;
  late _FakeRealtimeSession session;

  setUp(() {
    backend = _RecordingMediaBackend();
    capabilities = _RecordingCapabilities(
      sources: <ScreenCaptureSource>[source],
    );
    session = _FakeRealtimeSession(
      realtimeId: realtimeId,
      peerId: 'peer-remote',
      generation: 7,
    );
  });

  test('prepares capture and releases the endpoint in owner order', () async {
    final coordinator = _coordinator(
      backend,
      capabilities,
      session,
      source: source,
    );

    await coordinator.prepare(capture: true);
    await coordinator.port.startCapture(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    await coordinator.port.stop(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );

    expect(capabilities.prepareCalls, 1);
    expect(capabilities.listCalls, 1);
    expect(backend.operations, <String>[
      'start:send',
      'attach-capture:1',
      'detach:1',
      'release:1',
    ]);
    await coordinator.dispose();
  });

  test('rejects stale generation before touching the media backend', () async {
    final coordinator = _coordinator(
      backend,
      capabilities,
      session,
      source: source,
    );
    await coordinator.prepare(capture: true);

    await expectLater(
      coordinator.port.startCapture(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 8,
      ),
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.staleGeneration,
        ),
      ),
    );
    expect(backend.operations, isEmpty);
    await coordinator.dispose();
  });

  test(
    'receive attaches only an opaque surface and releases it safely',
    () async {
      final coordinator = _coordinator(backend, capabilities, session);
      await coordinator.prepare(capture: false);
      await coordinator.port.startViewer(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );
      await coordinator.port.stop(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );

      expect(backend.operations, <String>[
        'start:receive',
        'attach-surface:1',
        'detach:1',
        'release:1',
      ]);
      expect(capabilities.prepareCalls, 0);
      expect(capabilities.listCalls, 0);
      await coordinator.dispose();
    },
  );

  test(
    'screen-share controller does not capture before remote acceptance',
    () async {
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        source: source,
      );
      await coordinator.prepare(capture: true);
      final consent = _FakeConsentPort();
      final controller = ScreenShareController(
        consentPort: consent,
        mediaPort: coordinator.port,
        realtimeId: realtimeId,
        generation: 7,
        localPeerId: 'peer-local',
        remotePeerId: 'peer-remote',
        now: () => DateTime.utc(2030, 1, 1, 12),
      );
      await controller.setMediaReady(true);
      await controller.startOutgoing(operationId: 'operation-a');

      expect(backend.operations, isEmpty);
      consent.emit(
        RealtimeConsent(
          operationId: 'operation-a',
          realtimeId: realtimeId,
          issuedAt: DateTime.utc(2030, 1, 1, 12),
          expiresAt: DateTime.utc(2030, 1, 1, 12, 1),
          decision: RealtimeConsentDecision.accept,
          senderPeerId: 'peer-remote',
          actionRevision: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(backend.operations, <String>['start:send', 'attach-capture:1']);
      expect(controller.state, ScreenShareOperationState.active);
      await controller.cancel();
      controller.dispose();
      await consent.close();
      await coordinator.dispose();
    },
  );

  test(
    'stale capture preflight cannot create an endpoint after stop',
    () async {
      final gate = Completer<void>();
      capabilities.prepareGate = gate;
      final coordinator = _coordinator(
        backend,
        capabilities,
        session,
        source: source,
      );
      await coordinator.prepare(capture: true);

      final start = coordinator.port.startCapture(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );
      await Future<void>.delayed(Duration.zero);
      final stop = coordinator.port.stop(
        operationId: 'operation-a',
        realtimeId: realtimeId,
        generation: 7,
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await stop;

      await expectLater(
        start,
        throwsA(
          isA<RealtimeMediaException>().having(
            (error) => error.code,
            'code',
            RealtimeMediaErrorCode.staleEndpoint,
          ),
        ),
      );
      expect(backend.operations, isEmpty);
      await coordinator.dispose();
    },
  );

  test('generation replacement during preflight fails closed', () async {
    final gate = Completer<void>();
    capabilities.prepareGate = gate;
    final coordinator = _coordinator(
      backend,
      capabilities,
      session,
      source: source,
    );
    await coordinator.prepare(capture: true);

    final start = coordinator.port.startCapture(
      operationId: 'operation-a',
      realtimeId: realtimeId,
      generation: 7,
    );
    await Future<void>.delayed(Duration.zero);
    session.replaceGeneration(8);
    gate.complete();

    await expectLater(
      start,
      throwsA(
        isA<RealtimeMediaException>().having(
          (error) => error.code,
          'code',
          RealtimeMediaErrorCode.staleEndpoint,
        ),
      ),
    );
    expect(backend.operations, isEmpty);
    await coordinator.dispose();
  });
}

AppScreenShareMediaCoordinator _coordinator(
  _RecordingMediaBackend backend,
  _RecordingCapabilities capabilities,
  _FakeRealtimeSession session, {
  ScreenCaptureSource? source,
}) => AppScreenShareMediaCoordinator(
  session: session,
  resources: AppRealtimeMediaResources(
    backend: backend,
    sessionFactory: AppRealtimeMediaSessionFactory(backend: backend),
  ),
  capabilities: capabilities,
  source: source,
);

final class _FakeConsentPort implements ScreenShareConsentPort {
  final StreamController<RealtimeConsent> _events =
      StreamController<RealtimeConsent>.broadcast();
  final List<RealtimeConsent> sent = <RealtimeConsent>[];

  @override
  Stream<RealtimeConsent> get consents => _events.stream;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async {
    sent.add(consent);
    return const SdkSuccess<void>(null);
  }

  void emit(RealtimeConsent consent) => _events.add(consent);

  Future<void> close() => _events.close();
}

final class _RecordingCapabilities
    implements AppScreenSharePlatformCapabilities {
  _RecordingCapabilities({required this.sources});

  final List<ScreenCaptureSource> sources;
  int prepareCalls = 0;
  int listCalls = 0;
  Completer<void>? prepareGate;

  @override
  Future<void> prepareCapture() async {
    prepareCalls++;
    final gate = prepareGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<List<ScreenCaptureSource>> listCaptureSources() async {
    listCalls++;
    return sources;
  }
}

final class _RecordingMediaBackend implements RealtimeMediaBackend {
  final List<String> operations = <String>[];
  int _nextEndpoint = 0;

  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity identity,
  ) async {
    final id = RealtimeMediaEndpointId('${++_nextEndpoint}');
    operations.add('start:${identity.direction.name}');
    return id;
  }

  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) async {
    operations.add('attach-capture:${endpointId.value}');
  }

  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('attach-surface:${endpointId.value}');
    return RemoteVideoSurface(
      id: RemoteVideoSurfaceId('surface:${endpointId.value}'),
      endpointId: endpointId,
      identity: identity,
    );
  }

  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('detach:${endpointId.value}');
  }

  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    operations.add('release:${endpointId.value}');
  }

  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async => RealtimeMediaStats();
}

final class _FakeRealtimeSession implements RealtimeSession {
  _FakeRealtimeSession({
    required this.realtimeId,
    required this.peerId,
    required int generation,
  }) : mediaToken = RealtimeSessionToken(
         realtimeId: realtimeId,
         peerId: peerId,
         generation: generation,
       );

  @override
  final String realtimeId;

  @override
  final String peerId;

  @override
  RealtimeSessionToken mediaToken;

  @override
  RealtimeSessionState state = RealtimeSessionState.connected;

  @override
  int revision = 1;

  @override
  int? get generation => mediaToken.generation;

  @override
  RealtimeAudioState audioState = RealtimeAudioState.unavailable;

  @override
  final Stream<RealtimeConsent> consentEvents =
      const Stream<RealtimeConsent>.empty();

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> start() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess<void>(null);

  void replaceGeneration(int generation) {
    mediaToken = RealtimeSessionToken(
      realtimeId: realtimeId,
      peerId: peerId,
      generation: generation,
    );
  }
}
