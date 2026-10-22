// Device-only entry point: flutter run -t test/device/screen_share_device_probe.dart.
// Uses isolated fixture identities and reports counters only, never frame data.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:realtime_media_android/realtime_media_android.dart';
import 'package:realtime_media_windows/realtime_media_windows.dart';
import 'package:ssh_mobile/app/realtime_feature_adapters.dart';
import 'package:ssh_mobile/app/realtime_media_feature_adapters.dart';
import 'package:ssh_mobile/app/screen_share_media_coordinator.dart';
import 'package:ssh_mobile/app/screen_share_video_page.dart';
import 'package:ssh_mobile/app/window_fullscreen_controller.dart';
import 'package:ssh_mobile/services/network/network_service.dart';

const _realtimeId = '00112233445566778899aabbccddeeff';
final _status = ValueNotifier<String>('Device probe starting');
final _surface = ValueNotifier<RemoteVideoSurface?>(null);
final _videoSize = ValueNotifier<Size?>(null);
final _stopped = Completer<void>();
final _publicView = GlobalKey();

Widget _statusView() => ValueListenableBuilder(
  valueListenable: _status,
  builder: (_, status, _) => Text(status),
);

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    RepaintBoundary(
      key: _publicView,
      child: MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: _surface,
          builder: (_, surface, _) => surface == null
              ? Scaffold(body: Center(child: _statusView()))
              : AppScreenShareVideoPage(
                  video: Texture(textureId: int.parse(surface.id.value)),
                  videoSize: _videoSize,
                  controls: _statusView(),
                  onStop: () {
                    if (!_stopped.isCompleted) _stopped.complete();
                  },
                ),
        ),
      ),
    ),
  );
  unawaited(
    _probe(
      reverse:
          const bool.fromEnvironment('SCREEN_PROBE_REVERSE') ||
          args.contains('reverse'),
      selfWindow: args.contains('self-window'),
      verifyWindow: args.contains('verify-window'),
    ),
  );
}

void _report(String message) {
  _status.value = message;
  debugPrint('SCREEN_DEVICE_PROBE $message');
}

void _require<T>(SdkResult<T> result) {
  if (result is! SdkSuccess<T>) throw StateError('sdk_failure');
}

Future<void> _probe({
  required bool reverse,
  required bool selfWindow,
  required bool verifyWindow,
}) async {
  final windows = Platform.isWindows;
  final sender = reverse ? !windows : windows;
  final local = windows ? 'probe-windows' : 'probe-android';
  final remote = windows ? 'probe-android' : 'probe-windows';
  final root = await Directory.systemTemp.createTemp('screen-device-probe-');
  final runtime = NetworkRuntimeImpl();
  NativeNetworkService? service;
  RealtimeClientImpl? client;
  AppScreenShareMediaCoordinator? coordinator;
  VoidCallback? refreshVideoSize;
  RealtimeSession? session;
  RealtimeConsent? operation;
  StreamSubscription<RealtimeConsent>? cancellation;
  final peerCancelled = Completer<void>();
  var passed = false;
  try {
    service = NativeNetworkService.fromGateway(
      await runtime.openCommandGateway(),
    );
    final seed = Uint8List.fromList(List.filled(32, windows ? 61 : 62));
    final e2e = Uint8List.fromList(List.filled(32, windows ? 71 : 72));
    _require(
      await service.start(
        SdkRuntimeConfig(
          deviceId: local,
          identityPrivateKey: seed,
          e2ePrivateKey: e2e,
          listenAddress: windows ? '0.0.0.0:47832' : '0.0.0.0:47831',
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
          endpointAddress: sender
              ? (windows ? '127.0.0.1:47831' : '10.0.2.2:47832')
              : '',
          identityPublicKey: await public(
            await Ed25519().newKeyPairFromSeed(
              Uint8List.fromList(List.filled(32, windows ? 62 : 61)),
            ),
          ),
          e2ePublicKey: await public(
            await X25519().newKeyPairFromSeed(
              Uint8List.fromList(List.filled(32, windows ? 72 : 71)),
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
    operation = request;
    final activeSession = session;
    cancellation = activeSession.consentEvents.listen((consent) {
      if (consent.decision == RealtimeConsentDecision.cancel &&
          consent.operationId == request.operationId &&
          consent.sharedSessionInstanceId ==
              activeSession.sharedSessionInstanceId &&
          !peerCancelled.isCompleted) {
        peerCancelled.complete();
      }
    });
    if (session.state != RealtimeSessionState.connected) {
      await session.snapshots
          .firstWhere((s) => s.state == RealtimeSessionState.connected)
          .timeout(const Duration(seconds: 30));
    }
    final endpointBackend = _ProbeEndpointBackend(
      AppRealtimeMediaBackend(networkRuntime: runtime),
    );
    final RealtimeMediaBackend mediaBackend = windows
        ? WindowsRealtimeMediaBackend(
            endpointBackend: endpointBackend,
            platform: const MethodChannelWindowsRealtimeMediaPlatform(),
          )
        : AndroidRealtimeMediaBackend(
            endpointBackend: endpointBackend,
            platform: const MethodChannelAndroidRealtimeMediaPlatform(),
          );
    final capabilities = appScreenSharePlatformCapabilitiesFor(mediaBackend);
    ScreenCaptureSource? source;
    if (sender) {
      final sources = await capabilities.listCaptureSources();
      if (windows) {
        const configuredFixture = String.fromEnvironment(
          'SCREEN_PROBE_WINDOW_TITLE',
          defaultValue: 'SSH Mobile screen share test - Notepad',
        );
        final fixture = selfWindow ? 'SSH Mobile' : configuredFixture;
        final matches = sources
            .where(
              (s) =>
                  s.kind == ScreenCaptureSourceKind.window &&
                  fixture.isNotEmpty &&
                  (s.label == fixture || s.label == '*$fixture'),
            )
            .toList();
        if (matches.length != 1) {
          _report('FAIL fixture_window_unavailable');
          return;
        }
        source = matches.single;
      } else {
        source = sources.firstWhere(
          (s) => s.kind == ScreenCaptureSourceKind.display,
        );
      }
    }
    coordinator = AppScreenShareMediaCoordinator(
      session: session,
      codecMode: const bool.fromEnvironment('SCREEN_PROBE_CPU')
          ? RealtimeMediaCodecMode.cpu
          : RealtimeMediaCodecMode.hardware,
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
      final viewer = coordinator;
      refreshVideoSize = () => _videoSize.value = viewer.remoteVideoSize.value;
      viewer.remoteVideoSize.addListener(refreshVideoSize);
      refreshVideoSize();
    }
    _report('media_started');
    const requestedDuration = int.fromEnvironment(
      'SCREEN_PROBE_HOLD_SECONDS',
      defaultValue: 120,
    );
    final duration = requestedDuration.clamp(8, 300);
    final waiting = Stopwatch()..start();
    final viewing = Stopwatch();
    Size? observedSize;
    for (
      var attempt = 0;
      !_stopped.isCompleted &&
          !peerCancelled.isCompleted &&
          (passed
              ? viewing.elapsed < Duration(seconds: duration)
              : waiting.elapsed < const Duration(minutes: 3));
      attempt++
    ) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_stopped.isCompleted || peerCancelled.isCompleted) break;
      final stats = await mediaBackend.readStats(
        endpointId: endpointBackend.endpointId!,
        identity: endpointBackend.identity!,
      );
      if (attempt % 5 == 0) {
        _report(
          'counters captured=${stats.framesCaptured} sent=${stats.framesSent} '
          'size=${stats.width}x${stats.height} '
          'decoded=${stats.framesDecoded} rendered=${stats.framesRendered} '
          'packetsSent=${stats.packetsSent} packetsReceived=${stats.packetsReceived} '
          'recovered=${stats.framesRecovered} requests=${stats.keyframeRequests} '
          'dropped=${stats.framesDropped} depth=${stats.queueDepth}',
        );
      }
      if (!passed &&
          (sender ? stats.framesSent > 0 : stats.framesRendered > 0)) {
        passed = true;
        viewing.start();
        _report('PASS');
        if (windows && !sender && verifyWindow) {
          await _verifyNativeWindow();
        }
      }
      if (windows &&
          !sender &&
          verifyWindow &&
          passed &&
          stats.width > 0 &&
          stats.height > 0) {
        final size = Size(stats.width.toDouble(), stats.height.toDouble());
        if (observedSize != null && observedSize != size) {
          await Future<void>.delayed(const Duration(seconds: 6));
          await _snapshotPublicViewer(
            suffix: stats.width > stats.height ? 'landscape' : 'portrait',
          );
          _report('geometry_changed size=${stats.width}x${stats.height}');
        }
        observedSize = size;
      }
    }
    _report(passed ? 'finished after_video' : 'FAIL no_video_frames');
  } on RealtimeMediaException catch (error) {
    final expectedPeerEnd =
        passed &&
        peerCancelled.isCompleted &&
        {
          RealtimeMediaErrorCode.staleEndpoint,
          RealtimeMediaErrorCode.staleGeneration,
          RealtimeMediaErrorCode.sessionReleased,
        }.contains(error.code);
    _report(
      expectedPeerEnd ? 'finished peer_cancelled' : 'FAIL ${error.code.name}',
    );
    if (error.code == RealtimeMediaErrorCode.decoderFailed &&
        error.message.startsWith('Windows H.264 decoder failed at ')) {
      _report(error.message);
    }
  } on TimeoutException {
    _report('FAIL timeout');
  } catch (_) {
    _report('FAIL lifecycle');
  } finally {
    final activeSession = session;
    final activeOperation = operation;
    if (activeSession != null &&
        activeOperation != null &&
        !peerCancelled.isCompleted &&
        activeSession.state != RealtimeSessionState.stopped &&
        activeSession.state != RealtimeSessionState.failed) {
      final now = DateTime.now().toUtc();
      try {
        final cancelled = await activeSession
            .sendConsent(
              RealtimeConsent(
                operationId: activeOperation.operationId,
                realtimeId: _realtimeId,
                sharedSessionInstanceId:
                    activeOperation.sharedSessionInstanceId,
                issuedAt: now,
                expiresAt: now.add(const Duration(minutes: 1)),
                decision: RealtimeConsentDecision.cancel,
                senderPeerId: local,
                actionRevision: 2,
              ),
            )
            .timeout(const Duration(seconds: 5));
        if (cancelled is SdkSuccess<void>) {
          debugPrint('SCREEN_DEVICE_PROBE cancel_sent');
        } else {
          _report('FAIL cancel_unconfirmed');
        }
      } catch (_) {
        _report('FAIL cancel_unconfirmed');
      }
    }
    await cancellation?.cancel();
    _surface.value = null;
    if (refreshVideoSize != null && coordinator != null) {
      coordinator.remoteVideoSize.removeListener(refreshVideoSize);
    }
    await coordinator?.dispose();
    await session?.stop();
    await client?.dispose();
    await service?.dispose();
    await runtime.dispose();
    await root.delete(recursive: true);
    debugPrint('SCREEN_DEVICE_PROBE cleanup_finished');
  }
}

Future<void> _verifyNativeWindow() async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final before = view.physicalSize;
  final surface = _surface.value;
  final window = AppWindowFullscreenController(
    platform: const MethodChannelAppWindowPresentation(),
  );
  bool sameSize(Size a, Size b) =>
      (a.width - b.width).abs() <= 1 && (a.height - b.height).abs() <= 1;
  try {
    await window.setFullscreen(true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!window.fullscreen || !sameSize(view.physicalSize, view.display.size)) {
      throw StateError('Native fullscreen did not fill the display.');
    }
    _report('presentation_native_fullscreen');
    await window.setFullscreen(false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (window.needsRestore ||
        !sameSize(before, view.physicalSize) ||
        !identical(surface, _surface.value)) {
      throw StateError('Native fullscreen did not restore the viewer.');
    }
    _report('presentation_native_restored');
    await _snapshotPublicViewer();
  } finally {
    await window.close();
  }
}

Future<void> _snapshotPublicViewer({String? suffix}) async {
  await WidgetsBinding.instance.endOfFrame;
  final boundary =
      _publicView.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  try {
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var samples = 0;
    var visible = 0;
    for (var y = image.height ~/ 2 - 24; y <= image.height ~/ 2 + 24; y += 4) {
      for (var x = image.width ~/ 2 - 24; x <= image.width ~/ 2 + 24; x += 4) {
        final offset = (y * image.width + x) * 4;
        samples++;
        if (rgba.getUint8(offset) > 32 ||
            rgba.getUint8(offset + 1) > 32 ||
            rgba.getUint8(offset + 2) > 32) {
          visible++;
        }
      }
    }
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File(
      '${File(Platform.resolvedExecutable).parent.path}/screen-experience-received${suffix == null ? '' : '-$suffix'}.png',
    ).writeAsBytes(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
    if (visible * 4 < samples) {
      _report('FAIL fixture_pixels_black');
      throw StateError('Public fixture pixels were not visible.');
    }
    _report('presentation_pixels_verified');
  } finally {
    image.dispose();
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
