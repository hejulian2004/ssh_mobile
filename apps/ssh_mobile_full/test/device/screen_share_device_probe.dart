// Device-only entry point: flutter run -t test/device/screen_share_device_probe.dart.
// Uses isolated fixture identities and reports counters only, never frame data.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:realtime_media_android/realtime_media_android.dart';
import 'package:realtime_media_windows/realtime_media_windows.dart';
import 'package:ssh_mobile/app/realtime_feature_adapters.dart';
import 'package:ssh_mobile/app/realtime_media_feature_adapters.dart';
import 'package:ssh_mobile/app/screen_share_media_coordinator.dart';
import 'package:ssh_mobile/services/network/network_service.dart';

const _realtimeId = '00112233445566778899aabbccddeeff';
final _status = ValueNotifier<String>('Device probe starting');
final _surface = ValueNotifier<RemoteVideoSurface?>(null);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: _surface,
          builder: (_, surface, _) => surface == null
              ? Center(
                  child: ValueListenableBuilder(
                    valueListenable: _status,
                    builder: (_, status, _) => Text(status),
                  ),
                )
              : Texture(textureId: int.parse(surface.id.value)),
        ),
      ),
    ),
  );
  unawaited(_probe());
}

void _report(String message) {
  _status.value = message;
  debugPrint('SCREEN_DEVICE_PROBE $message');
}

void _require<T>(SdkResult<T> result) {
  if (result is! SdkSuccess<T>) throw StateError('sdk_failure');
}

Future<void> _probe() async {
  final sender = Platform.isWindows;
  final local = sender ? 'probe-windows' : 'probe-android';
  final remote = sender ? 'probe-android' : 'probe-windows';
  final root = await Directory.systemTemp.createTemp('screen-device-probe-');
  final runtime = NetworkRuntimeImpl();
  NativeNetworkService? service;
  RealtimeClientImpl? client;
  AppScreenShareMediaCoordinator? coordinator;
  RealtimeSession? session;
  try {
    service = NativeNetworkService.fromGateway(
      await runtime.openCommandGateway(),
    );
    final seed = Uint8List.fromList(List.filled(32, sender ? 61 : 62));
    final e2e = Uint8List.fromList(List.filled(32, sender ? 71 : 72));
    _require(
      await service.start(
        SdkRuntimeConfig(
          deviceId: local,
          identityPrivateKey: seed,
          e2ePrivateKey: e2e,
          listenAddress: sender ? '0.0.0.0:47832' : '0.0.0.0:47831',
          receiveDirectory: root.path,
        ),
      ),
    );
    Future<Uint8List> public(SimpleKeyPair pair) async =>
        Uint8List.fromList((await pair.extractPublicKey()).bytes);
    _require(
      await service.upsertPeer(
        SdkPeerConfig(
          peerId: remote,
          endpointAddress: sender ? '127.0.0.1:47831' : '',
          identityPublicKey: await public(
            await Ed25519().newKeyPairFromSeed(
              Uint8List.fromList(List.filled(32, sender ? 62 : 61)),
            ),
          ),
          e2ePublicKey: await public(
            await X25519().newKeyPairFromSeed(
              Uint8List.fromList(List.filled(32, sender ? 72 : 71)),
            ),
          ),
        ),
      ),
    );
    final backend = AppRealtimeSessionBackend(
      networkRuntime: runtime,
      screenVideo: true,
    );
    backend.observeGateway(await runtime.openRealtimeGateway());
    client = RealtimeClientImpl(backend: backend);
    _report('ready');
    RealtimeConsent request;
    if (sender) {
      _require(
        await service.connect(
          remote,
          communicationClass: CommunicationClass.reliableMessage,
        ),
      );
      session = client.createSession(realtimeId: _realtimeId, peerId: remote);
      _require(await session.start());
      if (session.sharedSessionInstanceId == null) {
        await session.snapshots
            .firstWhere((s) => s.sharedSessionInstanceId != null)
            .timeout(const Duration(seconds: 10));
      }
      final now = DateTime.now().toUtc();
      request = RealtimeConsent(
        operationId: 'device-probe-operation',
        realtimeId: _realtimeId,
        sharedSessionInstanceId: session.sharedSessionInstanceId!,
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 2)),
        decision: RealtimeConsentDecision.request,
        senderPeerId: local,
        actionRevision: 1,
      );
      final accepted = session.consentEvents.firstWhere(
        (c) => c.decision == RealtimeConsentDecision.accept,
      );
      _require(await session.sendConsent(request));
      await accepted.timeout(const Duration(seconds: 60));
      _report('accepted');
    } else {
      final offer = await client.incomingOffers.first.timeout(
        const Duration(minutes: 2),
      );
      _report('invitation_received');
      final claimed = await client.claimIncomingSession(offer);
      _require(claimed);
      session = (claimed as SdkSuccess<RealtimeSession>).data;
      if (session.sharedSessionInstanceId == null) {
        await session.snapshots
            .firstWhere((s) => s.sharedSessionInstanceId != null)
            .timeout(const Duration(seconds: 10));
      }
      final now = DateTime.now().toUtc();
      request = RealtimeConsent(
        operationId: 'device-probe-operation',
        realtimeId: _realtimeId,
        sharedSessionInstanceId: session.sharedSessionInstanceId!,
        issuedAt: now,
        expiresAt: now.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.accept,
        senderPeerId: local,
        actionRevision: 1,
      );
      _require(await session.sendConsent(request));
      _report('acceptance_sent');
    }
    if (session.state != RealtimeSessionState.connected) {
      await session.snapshots
          .firstWhere((s) => s.state == RealtimeSessionState.connected)
          .timeout(const Duration(seconds: 30));
    }
    final endpointBackend = _ProbeEndpointBackend(
      AppRealtimeMediaBackend(networkRuntime: runtime),
    );
    final RealtimeMediaBackend mediaBackend = sender
        ? WindowsRealtimeMediaBackend(
            endpointBackend: endpointBackend,
            platform: const MethodChannelWindowsRealtimeMediaPlatform(),
          )
        : AndroidRealtimeMediaBackend(
            endpointBackend: endpointBackend,
            platform: const MethodChannelAndroidRealtimeMediaPlatform(),
          );
    final capabilities = appScreenSharePlatformCapabilitiesFor(mediaBackend);
    final source = sender
        ? (await capabilities.listCaptureSources()).firstWhere(
            (s) => s.kind == ScreenCaptureSourceKind.display,
          )
        : null;
    coordinator = AppScreenShareMediaCoordinator(
      session: session,
      resources: AppRealtimeMediaResources(
        backend: mediaBackend,
        sessionFactory: AppRealtimeMediaSessionFactory(backend: mediaBackend),
      ),
      capabilities: capabilities,
      source: source,
    );
    await coordinator.prepare(capture: sender);
    if (sender) {
      await coordinator.port.startCapture(
        operationId: request.operationId,
        realtimeId: _realtimeId,
        generation: session.generation!,
      );
    } else {
      await coordinator.port.startViewer(
        operationId: request.operationId,
        realtimeId: _realtimeId,
        generation: session.generation!,
      );
      _surface.value = coordinator.remoteSurface;
    }
    _report('media_started');
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final stats = await mediaBackend.readStats(
        endpointId: endpointBackend.endpointId!,
        identity: endpointBackend.identity!,
      );
      _report(
        'counters captured=${stats.framesCaptured} sent=${stats.framesSent} '
        'decoded=${stats.framesDecoded} rendered=${stats.framesRendered} '
        'packetsSent=${stats.packetsSent} packetsReceived=${stats.packetsReceived} '
        'recovered=${stats.framesRecovered} requests=${stats.keyframeRequests} '
        'dropped=${stats.framesDropped} depth=${stats.queueDepth}',
      );
      if (sender ? stats.framesSent > 0 : stats.framesRendered > 0) {
        _report('PASS');
        await Future<void>.delayed(Duration(seconds: sender ? 45 : 8));
        return;
      }
    }
    _report('FAIL no_video_frames');
  } on RealtimeMediaException catch (error) {
    _report('FAIL ${error.code.name}');
  } on TimeoutException {
    _report('FAIL timeout');
  } catch (_) {
    _report('FAIL lifecycle');
  } finally {
    _surface.value = null;
    await coordinator?.dispose();
    await session?.stop();
    await client?.dispose();
    await service?.dispose();
    await runtime.dispose();
    await root.delete(recursive: true);
  }
}

final class _ProbeEndpointBackend
    implements RealtimeMediaBackend, RealtimeMediaNativeOwnerBackend {
  _ProbeEndpointBackend(this.inner);
  final AppRealtimeMediaBackend inner;
  RealtimeMediaEndpointId? endpointId;
  RealtimeMediaEndpointIdentity? identity;
  @override
  Future<RealtimeMediaEndpointId> start(
    RealtimeMediaEndpointIdentity value,
  ) async {
    identity = value;
    _report('endpoint_create');
    endpointId = await inner.start(value);
    _report('endpoint_created');
    return endpointId!;
  }

  @override
  Future<RealtimeMediaNativeOwnerToken> openNativeOwner({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) async {
    _report('owner_open');
    final token = await inner.openNativeOwner(
      endpointId: endpointId,
      identity: identity,
    );
    _report('owner_opened');
    return token;
  }

  @override
  Future<void> closeNativeOwner({
    required RealtimeMediaNativeOwnerToken token,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.closeNativeOwner(token: token, identity: identity);
  @override
  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  }) => inner.attachCaptureSource(
    endpointId: endpointId,
    identity: identity,
    source: source,
  );
  @override
  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.attachRemoteVideoSurface(
    endpointId: endpointId,
    identity: identity,
  );
  @override
  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.detach(endpointId: endpointId, identity: identity);
  @override
  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.release(endpointId: endpointId, identity: identity);
  @override
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  }) => inner.readStats(endpointId: endpointId, identity: identity);
}
