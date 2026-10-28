// Device-only integration: actual App operation ownership with public fixtures.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:realtime_media_android/realtime_media_android.dart';
import 'package:realtime_media_windows/realtime_media_windows.dart';
import 'package:ssh_mobile/app/navigation/app_route_contributions.dart';
import 'package:ssh_mobile/app/realtime_feature_adapters.dart';
import 'package:ssh_mobile/app/realtime_media_feature_adapters.dart';
import 'package:ssh_mobile/app/screen_share_background_host.dart';
import 'package:ssh_mobile/app/screen_share_guidance_android.dart';
import 'package:ssh_mobile/app/screen_share_operation.dart';
import 'package:ssh_mobile/app/screen_share_route_scope.dart';
import 'package:ssh_mobile/app/screen_share_session_lease.dart';
import 'package:ssh_mobile/services/network/network_service.dart';
import 'screen_share_probe_backend.dart';

const _id = '00112233445566778899aabbccddeeff';
final _navigator = GlobalKey<NavigatorState>();
final _sessions = AppScreenShareSessions();
final _status = ValueNotifier('PUBLIC SCREEN SHARE LIFECYCLE TEST');
late AppRealtimeMediaResources _resources;

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      navigatorKey: _navigator,
      builder: (_, child) => AppScreenShareBackgroundHost(
        sessions: _sessions,
        navigatorKey: _navigator,
        child: child!,
      ),
      onGenerateRoute: (settings) =>
          settings.name == AppShellRouteNames.screenShare
          ? MaterialPageRoute<void>(
              allowSnapshotting: false,
              settings: settings,
              builder: (_) => AppScreenShareRouteScope(
                arguments: settings.arguments! as AppScreenShareRouteArguments,
                resources: _resources,
                sessions: _sessions,
              ),
            )
          : null,
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: _status,
            builder: (_, value, _) => Text(value),
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
      annotate:
          const bool.fromEnvironment('SCREEN_PROBE_ANNOTATE') ||
          args.contains('annotate'),
    ),
  );
}

void _report(String message) {
  _status.value = message;
  debugPrint('SCREEN_SESSION_PROBE $message');
}

void _require<T>(SdkResult<T> result) {
  if (result is SdkFailure<T>) {
    _report('sdk_failed code=${result.error.code.name}');
    throw StateError('SDK operation failed');
  }
}

Future<void> _until(bool Function() ready, {int seconds = 90}) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed.inSeconds >= seconds) {
      throw TimeoutException('device gate');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

bool _hasFullscreenExit() {
  var found = false;
  void visit(Element element) {
    if (element.widget case IconButton(tooltip: 'Exit fullscreen')) {
      found = true;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return found;
}

bool _sameSize(Size a, Size b) =>
    (a.width - b.width).abs() <= 1 && (a.height - b.height).abs() <= 1;

Future<void> _exerciseAnnotation({
  required bool sender,
  required AppScreenShareOperation operation,
}) async {
  if (!sender) {
    await _until(() => operation.annotation?.canPaint == true, seconds: 30);
    final session = operation.annotation!;
    final points = <ScreenShareAnnotationPoint>[
      const ScreenShareAnnotationPoint(4000, 8000),
      const ScreenShareAnnotationPoint(20000, 20000),
      const ScreenShareAnnotationPoint(36000, 32000),
      const ScreenShareAnnotationPoint(52000, 44000),
      const ScreenShareAnnotationPoint(62000, 56000),
    ];
    if (!session.beginStroke(points.first, width: 80)) {
      throw StateError('Annotation pen refused the stroke');
    }
    for (final point in points.skip(1)) {
      if (!session.extendStroke(point)) {
        throw StateError('Annotation pen refused the stroke');
      }
    }
    if (!session.endStroke()) {
      throw StateError('Annotation pen refused the stroke');
    }
    _report('annotation_sent points=${session.strokes.single.points.length}');
    final ready = Stopwatch()..start();
    while (operation.annotation?.remoteDisplayReady == null &&
        ready.elapsed.inSeconds < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _report(
      'annotation_display_ready=${operation.annotation?.remoteDisplayReady}',
    );
  } else {
    await _until(() {
      final strokes = operation.annotation?.strokes;
      return strokes != null &&
          strokes.any((stroke) => stroke.complete && stroke.points.length >= 5);
    }, seconds: 45);
    final stroke = operation.annotation!.strokes.firstWhere(
      (item) => item.complete && item.points.length >= 5,
    );
    _report(
      'annotation_visible points=${stroke.points.length} width=${stroke.width}',
    );
  }
  await Future<void>.delayed(const Duration(seconds: 25));
  _report('annotation_hold_finished');
}

Future<void> _probe({required bool reverse, required bool annotate}) async {
  final windows = Platform.isWindows;
  final sender = reverse ? !windows : windows;
  _report('role sender=$sender annotate=$annotate');
  final local = windows ? 'probe-windows' : 'probe-android';
  final remote = windows ? 'probe-android' : 'probe-windows';
  final temporary = await Directory.systemTemp.createTemp(
    'screen-session-probe-',
  );
  final runtime = NetworkRuntimeImpl();
  NativeNetworkService? service;
  RealtimeClientImpl? client;
  try {
    service = NativeNetworkService.fromGateway(
      await runtime.openCommandGateway(),
    );
    _require(
      await service.start(
        SdkRuntimeConfig(
          deviceId: local,
          identityPrivateKey: Uint8List.fromList(
            List.filled(32, windows ? 61 : 62),
          ),
          e2ePrivateKey: Uint8List.fromList(List.filled(32, windows ? 71 : 72)),
          listenAddress: windows ? '0.0.0.0:47832' : '0.0.0.0:47831',
          receiveDirectory: temporary.path,
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
    final signaling = AppRealtimeSessionBackend(
      networkRuntime: runtime,
      screenVideo: true,
    );
    signaling.observeGateway(await runtime.openRealtimeGateway());
    client = RealtimeClientImpl(backend: signaling);
    final native = ProbeEndpointBackend(
      AppRealtimeMediaBackend(networkRuntime: runtime),
      onPhase: _report,
    );
    final RealtimeMediaBackend media = windows
        ? WindowsRealtimeMediaBackend(
            endpointBackend: native,
            platform: const MethodChannelWindowsRealtimeMediaPlatform(),
          )
        : AndroidRealtimeMediaBackend(
            endpointBackend: native,
            platform: const MethodChannelAndroidRealtimeMediaPlatform(),
          );
    _resources = AppRealtimeMediaResources(
      backend: media,
      sessionFactory: AppRealtimeMediaSessionFactory(backend: media),
      guidanceOverlay: windows
          ? null
          : const AndroidScreenShareGuidanceDisplay(
              MethodChannelAndroidGuidanceOverlay(),
            ),
    );
    final capabilities = appScreenSharePlatformCapabilitiesFor(media);
    _report('ready');
    RealtimeSession session;
    RealtimeConsent? request;
    ScreenCaptureSource? source;
    if (sender) {
      final sources = await capabilities.listCaptureSources();
      final matches = sources
          .where(
            (item) => windows
                ? item.kind == ScreenCaptureSourceKind.window &&
                      item.label == 'SSH Mobile'
                : item.kind == ScreenCaptureSourceKind.display,
          )
          .toList();
      if (matches.length != 1) {
        throw StateError('Public capture fixture unavailable');
      }
      source = matches.single;
      _require(
        await service.connect(
          remote,
          communicationClass: CommunicationClass.reliableMessage,
        ),
      );
      _report('peer_connected');
      session = client.createSession(realtimeId: _id, peerId: remote);
      _require(await session.start());
      _report(
        'session_started state=${session.state.name} '
        'generation=${session.generation} '
        'shared=${session.sharedSessionInstanceId != null}',
      );
      await waitForScreenShareSessionIdentity(session);
    } else {
      final offer = await client.incomingOffers.first.timeout(
        Duration(minutes: annotate ? 10 : 2),
      );
      final claimed = await client.claimIncomingSession(offer);
      _require(claimed);
      session = (claimed as SdkSuccess<RealtimeSession>).data;
      request = offer.request;
      await waitForScreenShareSessionIdentity(session);
    }
    final arguments = AppScreenShareRouteArguments(
      session: session,
      localPeerId: local,
      sessionLease: AppScreenShareSessionLease(
        client: client,
        session: session,
      ),
      operationId: sender ? 'device-probe-operation' : request!.operationId,
      source: source,
      mode: sender
          ? AppScreenShareRouteMode.send
          : AppScreenShareRouteMode.receive,
      initialIncomingRequest: request,
      startOutgoing: sender,
      acceptIncomingOnOpen: !sender,
      codecMode: RealtimeMediaCodecMode.cpu,
    );
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final originalWindowSize = view.physicalSize;
    final operation = _sessions.open(
      arguments,
      _resources,
      capabilities: capabilities,
    );
    operation.addListener(() {
      _report(
        'state=${operation.controller?.state.name} '
        'media_error=${operation.media?.failureCode?.name ?? 'none'}',
      );
    });
    unawaited(
      _navigator.currentState!.pushNamed<void>(
        AppShellRouteNames.screenShare,
        arguments: arguments,
      ),
    );
    await operation.initialization;
    await _until(
      () =>
          operation.controller!.state == ScreenShareOperationState.active ||
          operation.finished,
    );
    if (operation.finished) throw StateError('Operation ended before video');
    Future<RealtimeMediaStats> stats() => media.readStats(
      endpointId: native.endpointId!,
      identity: native.identity!,
    );
    int frames(RealtimeMediaStats value) =>
        sender ? value.framesSent : value.framesDecoded;
    var progress = await stats();
    for (
      var attempt = 0;
      (frames(progress) == 0 || (!sender && progress.framesRendered == 0)) &&
          attempt < 40;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      progress = await stats();
    }
    if (frames(progress) == 0 || (!sender && progress.framesRendered == 0)) {
      throw StateError('No actual video frames');
    }
    _report(
      'video_active frames=${frames(progress)} rendered=${progress.framesRendered}',
    );
    if (!sender) {
      await _until(_hasFullscreenExit, seconds: 10);
      if (windows && !_sameSize(view.physicalSize, view.display.size)) {
        throw StateError('Receiver window did not fill the display');
      }
      _report('receiver_default_fullscreen');
    } else if (_hasFullscreenExit()) {
      throw StateError('Sender entered viewer fullscreen');
    }
    if (annotate) {
      await _exerciseAnnotation(sender: sender, operation: operation);
    }
    _navigator.currentState!.pop();
    await Future<void>.delayed(const Duration(seconds: 15));
    final hidden = await stats();
    if (!_sessions.isBusy ||
        _sessions.pageVisible ||
        frames(hidden) <= frames(progress)) {
      throw StateError('Hidden page stopped sharing');
    }
    _report('page_hidden_continues frames=${frames(hidden)}');
    if (windows &&
        !sender &&
        !_sameSize(view.physicalSize, originalWindowSize)) {
      throw StateError('Closing viewer did not restore its window');
    }
    unawaited(
      _navigator.currentState!.pushNamed<void>(
        AppShellRouteNames.screenShare,
        arguments: arguments,
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!identical(_sessions.current, operation) ||
        native.startCalls != 1 ||
        !_sessions.pageVisible) {
      throw StateError('Reopening created another media owner');
    }
    _report('page_reopened_same_endpoint');
    if (!sender) {
      await _until(_hasFullscreenExit, seconds: 10);
      _report('receiver_reopened_fullscreen');
    }
    if (windows) {
      await Future<void>.delayed(const Duration(seconds: 10));
      await operation.stop().timeout(const Duration(seconds: 20));
      if (!operation.finished) throw StateError('Stop cleanup not confirmed');
      _report('explicit_stop_finished');
    } else {
      await _until(() => operation.finished, seconds: 45);
      _report('peer_stop_finished');
    }
    if (!sender) {
      await _until(() => !_hasFullscreenExit(), seconds: 10);
    }
    _report('PASS');
  } on RealtimeMediaException catch (error) {
    _report('FAIL ${error.code.name}');
  } on TimeoutException catch (error) {
    _report('FAIL timeout where=${error.message}');
  } catch (error, stack) {
    _report('FAIL lifecycle type=${error.runtimeType}');
    for (final line in stack.toString().split('\n').take(6)) {
      debugPrint('SCREEN_SESSION_PROBE trace=${line.split('(').first.trim()}');
    }
  } finally {
    await _sessions.close();
    await client?.dispose();
    await service?.dispose();
    await runtime.dispose();
    await temporary.delete(recursive: true);
    debugPrint('SCREEN_SESSION_PROBE cleanup_finished');
  }
}
