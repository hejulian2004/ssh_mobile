// Device-only scenario entry point: flutter run -t test/device/screen_share_scenario_probe.dart -- <args>
// Scenarios extend the public session-lifecycle probe with connect/disconnect
// behaviour: reject, cancel-early, both-stop, repeated rounds, and a survivor
// that must fail closed after its peer process is killed externally.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:app_core/app_core.dart';
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
final _offerInbox = <RealtimeIncomingSessionOffer>[];
Completer<RealtimeIncomingSessionOffer>? _offerArrived;
StreamSubscription<RealtimeIncomingSessionOffer>? _offerSub;

/// Pops a buffered offer or waits for the next one (host-like retention).
Future<RealtimeIncomingSessionOffer> _nextOffer() async {
  if (_offerInbox.isNotEmpty) {
    _report('offer_inbox drained');
    return _offerInbox.removeAt(0);
  }
  final waiter = Completer<RealtimeIncomingSessionOffer>();
  _offerArrived = waiter;
  try {
    return await waiter.future.timeout(const Duration(minutes: 2));
  } finally {
    _offerArrived = null;
  }
}

final _navigator = GlobalKey<NavigatorState>();
final _sessions = AppScreenShareSessions();
final _status = ValueNotifier('SCREEN SHARE SCENARIO PROBE');
late AppRealtimeMediaResources _resources;
late ProbeEndpointBackend _native;

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('SCREEN_SCENARIO_PROBE main_args=${args.join("|")}');
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
  unawaited(_probe(args));
}

void _report(String message) {
  _status.value = message;
  debugPrint('SCREEN_SCENARIO_PROBE $message');
}

final class _ProbeLogger implements AppLogger {
  @override
  void log(LogRecord record) =>
      debugPrint('SCREEN_SCENARIO_PROBE evt ${record.message}');

  @override
  AppLogger scope(String name) => this;
}

void _require(SdkResult<Object?> result, [String step = 'sdk']) {
  if (result is SdkFailure<Object?>) {
    final error = result.error;
    _report(
      'sdk_failed step=$step code=${error.code.name} message=${error.message}',
    );
    throw StateError('SDK operation failed at $step: ${error.code.name}');
  }
}

Future<void> _until(
  bool Function() ready, {
  int seconds = 90,
  String where = 'gate',
}) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed.inSeconds >= seconds) {
      throw TimeoutException('device gate: $where');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

bool _sameSize(Size a, Size b) =>
    (a.width - b.width).abs() <= 1 && (a.height - b.height).abs() <= 1;

class _ProbeContext {
  _ProbeContext({
    required this.reverse,
    required this.scenario,
    required this.hold,
    required this.rounds,
  });

  final bool reverse;
  final String scenario;
  final bool hold;
  final int rounds;

  bool get windows => Platform.isWindows;
  bool get senderRole => reverse ? !windows : windows;
  bool get survivor => scenario == 'peer-kill';
  String get local => windows ? 'probe-windows' : 'probe-android';
  String get remote => windows ? 'probe-android' : 'probe-windows';
}

/// Launch arguments for `flutter run` do not reach `main()` on these embedders,
/// so the orchestrator writes a scenario line out-of-band instead:
/// Android: adb exec-out run-as com.example.ssh_mobile sh -c
///   'printf "scenario=basic;rounds=2" > files/ssprobe_args.txt'
/// Windows: ssprobe_args.txt in the working directory of the exe.
String _argsFromFile() {
  try {
    final file = Platform.isAndroid
        ? File('/data/user/0/com.example.ssh_mobile/files/ssprobe_args.txt')
        : [
            File('ssprobe_args.txt'),
            File(
              '${File(Platform.resolvedExecutable).parent.path}\\ssprobe_args.txt',
            ),
          ].firstWhere(
            (f) => f.existsSync(),
            orElse: () => File('ssprobe_args.txt'),
          );
    if (file.existsSync()) return file.readAsStringSync().trim();
  } catch (error) {
    debugPrint('SCREEN_SCENARIO_PROBE args_file_error=$error');
  }
  return '';
}

Future<void> _probe(List<String> rawArgs) async {
  // Precedence: config file, then real launch arguments, then compiled defines.
  final args = <String>[
    ..._argsFromFile().split(RegExp(r'[;\s]+')),
    ...rawArgs,
  ].where((a) => a.isNotEmpty).toList();
  final reverse =
      const bool.fromEnvironment('SCREEN_PROBE_REVERSE') ||
      args.contains('reverse');
  final scenario = args
      .firstWhere(
        (a) => a.startsWith('scenario='),
        orElse: () => 'scenario=basic',
      )
      .substring(9);
  final rounds =
      int.tryParse(
        args
            .firstWhere(
              (a) => a.startsWith('rounds='),
              orElse: () => 'rounds=1',
            )
            .substring(7),
      ) ??
      1;
  final hold = args.contains('hold');
  final context = _ProbeContext(
    reverse: reverse,
    scenario: scenario,
    hold: hold,
    rounds: rounds.clamp(1, 10),
  );
  _report(
    'start scenario=$scenario rounds=${context.rounds} '
    'sender=${context.senderRole} survivor=${context.survivor}',
  );
  final temporary = await Directory.systemTemp.createTemp(
    'screen-scenario-probe-',
  );
  final runtime = NetworkRuntimeImpl();
  NativeNetworkService? service;
  RealtimeClientImpl? client;
  try {
    service = NativeNetworkService.fromGateway(
      await runtime.openCommandGateway(),
    );
    _report(
      'sdk_starting listen=${context.windows ? '0.0.0.0:47832' : '0.0.0.0:47831'} temp=${temporary.path}',
    );
    _require(
      await service.start(
        SdkRuntimeConfig(
          deviceId: context.local,
          identityPrivateKey: Uint8List.fromList(
            List.filled(32, context.windows ? 61 : 62),
          ),
          e2ePrivateKey: Uint8List.fromList(
            List.filled(32, context.windows ? 71 : 72),
          ),
          listenAddress: context.windows ? '0.0.0.0:47832' : '0.0.0.0:47831',
          receiveDirectory: temporary.path,
        ),
      ),
      'start',
    );
    _report('sdk_started');
    Future<Uint8List> public(SimpleKeyPair pair) async =>
        Uint8List.fromList((await pair.extractPublicKey()).bytes);
    _require(
      await service.upsertPeer(
        SdkPeerConfig(
          peerId: context.remote,
          endpointAddress: context.senderRole
              ? (context.windows ? '127.0.0.1:47831' : '10.0.2.2:47832')
              : '',
          identityPublicKey: await public(
            await Ed25519().newKeyPairFromSeed(
              Uint8List.fromList(List.filled(32, context.windows ? 62 : 61)),
            ),
          ),
          e2ePublicKey: await public(
            await X25519().newKeyPairFromSeed(
              Uint8List.fromList(List.filled(32, context.windows ? 72 : 71)),
            ),
          ),
        ),
      ),
      'upsert_peer',
    );
    _report('sdk_peer_upserted');
    final signaling = AppRealtimeSessionBackend(
      networkRuntime: runtime,
      screenVideo: true,
      logger: _ProbeLogger(),
    );
    signaling.observeGateway(await runtime.openRealtimeGateway());
    client = RealtimeClientImpl(backend: signaling);
    // Mirror the App's incoming-request host: listen continuously so an
    // offer that arrives during teardown of the previous round is buffered,
    // not lost.
    _offerSub = client.incomingOffers.listen((offer) {
      final waiter = _offerArrived;
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(offer);
      } else {
        _offerInbox.add(offer);
        _report('offer_inbox buffered depth=${_offerInbox.length}');
      }
    });
    _native = ProbeEndpointBackend(
      AppRealtimeMediaBackend(networkRuntime: runtime),
      onPhase: _report,
    );
    final RealtimeMediaBackend media = context.windows
        ? WindowsRealtimeMediaBackend(
            endpointBackend: _native,
            platform: const MethodChannelWindowsRealtimeMediaPlatform(),
          )
        : AndroidRealtimeMediaBackend(
            endpointBackend: _native,
            platform: const MethodChannelAndroidRealtimeMediaPlatform(),
          );
    _resources = AppRealtimeMediaResources(
      backend: media,
      sessionFactory: AppRealtimeMediaSessionFactory(backend: media),
      guidanceOverlay: context.windows
          ? null
          : const AndroidScreenShareGuidanceDisplay(
              MethodChannelAndroidGuidanceOverlay(),
            ),
    );
    final capabilities = appScreenSharePlatformCapabilitiesFor(media);
    _report('ready');
    for (var round = 1; round <= context.rounds; round++) {
      _report('round_begin $round/${context.rounds}');
      await _runRound(
        context: context,
        round: round,
        service: service,
        client: client,
        media: media,
        capabilities: capabilities,
      );
      _report('round_pass $round');
    }
    _report('PASS');
  } on TimeoutException catch (error) {
    _report('FAIL timeout where=${error.message}');
  } on RealtimeMediaException catch (error) {
    _report('FAIL ${error.code.name}');
  } catch (error) {
    _report('FAIL lifecycle type=${error.runtimeType} message=$error');
  } finally {
    await _offerSub?.cancel();
    await _sessions.close();
    await client?.dispose();
    await service?.dispose();
    await runtime.dispose();
    await temporary.delete(recursive: true);
    debugPrint('SCREEN_SCENARIO_PROBE cleanup_finished');
  }
}

Future<void> _runRound({
  required _ProbeContext context,
  required int round,
  required NativeNetworkService service,
  required RealtimeClientImpl client,
  required RealtimeMediaBackend media,
  required AppScreenSharePlatformCapabilities capabilities,
}) async {
  final sender = context.senderRole;
  final operationId = 'scenario-operation-$round';
  // Production entry uses a fresh hex realtimeId per share; mirror that here.
  final realtimeId =
      _id.substring(0, 30) + round.toRadixString(16).padLeft(2, '0');
  RealtimeSession session;
  RealtimeConsent? request;
  ScreenCaptureSource? source;
  if (sender) {
    final sources = await capabilities.listCaptureSources();
    final matches = sources
        .where(
          (item) => context.windows
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
        context.remote,
        communicationClass: CommunicationClass.reliableMessage,
      ),
      'connect',
    );
    _report('peer_connected');
    session = client.createSession(
      realtimeId: realtimeId,
      peerId: context.remote,
    );
    _require(await session.start(), 'session_start');
    await waitForScreenShareSessionIdentity(session);
  } else {
    final offer = await _nextOffer();
    final claimed = await client.claimIncomingSession(offer);
    _require(claimed, 'claim_offer');
    session = (claimed as SdkSuccess<RealtimeSession>).data;
    request = offer.request;
    await waitForScreenShareSessionIdentity(session);
  }
  final arguments = AppScreenShareRouteArguments(
    session: session,
    localPeerId: context.local,
    sessionLease: AppScreenShareSessionLease(client: client, session: session),
    operationId: sender ? operationId : request!.operationId,
    source: source,
    mode: sender
        ? AppScreenShareRouteMode.send
        : AppScreenShareRouteMode.receive,
    initialIncomingRequest: request,
    startOutgoing: sender,
    // reject/cancel-early exercise the explicit decision path on the viewer.
    acceptIncomingOnOpen:
        !sender &&
        context.scenario != 'reject' &&
        context.scenario != 'cancel-early',
    codecMode: RealtimeMediaCodecMode.cpu,
  );
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final originalWindowSize = view.physicalSize;
  final operation = _sessions.open(
    arguments,
    _resources,
    capabilities: capabilities,
  );
  unawaited(
    _navigator.currentState!.pushNamed<void>(
      AppShellRouteNames.screenShare,
      arguments: arguments,
    ),
  );
  session.snapshots.listen((snapshot) {
    _report(
      'snapshot state=${snapshot.state.name} gen=${snapshot.generation} '
      'ssid_len=${snapshot.sharedSessionInstanceId?.length ?? 0} '
      'rev=${snapshot.revision}',
    );
  });
  await operation.initialization;
  _report(
    'init_done state=${operation.controller?.state.name} '
    'session=${session.state.name} mediaReady=${operation.controller?.snapshot.mediaReady}',
  );

  Future<RealtimeMediaStats> stats() => media.readStats(
    endpointId: _native.endpointId!,
    identity: _native.identity!,
  );
  int frames(RealtimeMediaStats value) =>
      sender ? value.framesSent : value.framesDecoded;

  switch (context.scenario) {
    case 'reject':
      if (!sender) {
        await _until(
          () =>
              operation.controller?.state ==
              ScreenShareOperationState.incomingPending,
          seconds: 30,
          where: 'reject:incoming_pending',
        );
        await operation.controller!.rejectIncoming();
      }
      await _until(
        () => operation.finished,
        seconds: 30,
        where: 'reject:finished',
      );
      final state = operation.controller!.state;
      if (state != ScreenShareOperationState.rejected) {
        throw StateError('reject ended in ${state.name}');
      }
      if (_native.startCalls != 0) {
        throw StateError('Reject created a media endpoint');
      }
      if (!sender) {
        await _until(
          () => !_sessions.isBusy,
          seconds: 20,
          where: 'reject:busy_released',
        );
        if (!_sameSize(view.physicalSize, originalWindowSize)) {
          throw StateError('Reject did not restore the viewer window');
        }
      }
      _report('reject_converged state=${state.name}');
      return;
    case 'cancel-early':
      if (sender) {
        await _until(
          () =>
              operation.controller?.state ==
                  ScreenShareOperationState.outgoingPending ||
              operation.finished,
          seconds: 30,
          where: 'cancel-early:outgoing_pending',
        );
        if (operation.finished) throw StateError('Cancelled before sending');
        await Future<void>.delayed(const Duration(seconds: 2));
        await operation.stop();
      } else {
        await _until(
          () => operation.finished,
          seconds: 30,
          where: 'cancel-early:finished',
        );
        final state = operation.controller!.state;
        if (state != ScreenShareOperationState.cancelled) {
          throw StateError('cancel-early ended in ${state.name}');
        }
        if (_native.startCalls != 0) {
          throw StateError('Cancelled request created a media endpoint');
        }
        if (!_sameSize(view.physicalSize, originalWindowSize)) {
          throw StateError('Cancel did not keep the viewer window stable');
        }
      }
      _report(
        'cancel_early_converged state=${operation.controller?.state.name}',
      );
      return;
    case 'both-stop':
      await _waitActiveVideo(
        operation,
        frames,
        stats,
        sender: context.senderRole,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      unawaited(operation.stop());
      await _until(
        () => operation.finished,
        seconds: 30,
        where: 'both-stop:finished',
      );
      if (operation.cleanupFailed) throw StateError('Both-stop cleanup failed');
      _report('both_stop_converged');
      await _expectNoEndpoint(stats);
      return;
    case 'peer-kill':
      final baseline = await _waitActiveVideo(
        operation,
        frames,
        stats,
        sender: context.senderRole,
      );
      _report('survivor_waiting_peer_death');
      await _until(
        () => operation.finished,
        seconds: 60,
        where: 'peer-kill:finished',
      );
      final state = operation.controller!.state;
      if (state != ScreenShareOperationState.failed) {
        throw StateError('Peer death ended in ${state.name}');
      }
      if (_native.startCalls != 1) {
        throw StateError('Survivor endpoint accounting=${_native.startCalls}');
      }
      await _expectNoEndpoint(stats);
      // Media traffic must be fully stopped after the peer is gone.
      await Future<void>.delayed(const Duration(seconds: 2));
      _report('peer_kill_converged state=${state.name} frames=$baseline');
      return;
    case 'basic':
      await _waitActiveVideo(
        operation,
        frames,
        stats,
        sender: context.senderRole,
      );
      if (context.hold) {
        _report('basic_hold_ready');
        // The external orchestrator kills this process at a scripted moment.
        await Future<void>.delayed(const Duration(minutes: 30));
        return;
      }
      _navigator.currentState!.pop();
      await Future<void>.delayed(const Duration(seconds: 8));
      final hidden = await stats();
      if (!_sessions.isBusy || frames(hidden) == 0) {
        throw StateError('Hidden page stopped sharing');
      }
      _report('page_hidden_continues frames=${frames(hidden)}');
      // startCalls accumulates across rounds in one process; the reopen
      // invariant is that reopening adds no new media owner from here on.
      final startsBeforeReopen = _native.startCalls;
      unawaited(
        _navigator.currentState!.pushNamed<void>(
          AppShellRouteNames.screenShare,
          arguments: arguments,
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!identical(_sessions.current, operation) ||
          _native.startCalls != startsBeforeReopen ||
          !_sessions.pageVisible) {
        throw StateError('Reopening created another media owner');
      }
      if (context.windows && !sender) {
        await _until(
          () => _sameSize(view.physicalSize, originalWindowSize),
          seconds: 10,
          where: 'basic:window_restored',
        );
      }
      if (sender) {
        await Future<void>.delayed(const Duration(seconds: 5));
        await operation.stop().timeout(const Duration(seconds: 20));
        if (!operation.finished) throw StateError('Stop cleanup not confirmed');
      } else {
        await _until(
          () => operation.finished,
          seconds: 45,
          where: 'basic:peer_stop',
        );
      }
      await _expectNoEndpoint(stats);
      if (_sessions.isBusy) throw StateError('Busy after finished');
      return;
    default:
      throw StateError('Unknown scenario ${context.scenario}');
  }
}

Future<int> _waitActiveVideo(
  AppScreenShareOperation operation,
  int Function(RealtimeMediaStats) frames,
  Future<RealtimeMediaStats> Function() stats, {
  required bool sender,
}) async {
  await _until(
    () =>
        operation.controller?.state == ScreenShareOperationState.active ||
        operation.finished,
    seconds: 90,
    where: 'active',
  );
  if (operation.finished) throw StateError('Operation ended before video');
  var progress = await stats();
  for (var attempt = 0; frames(progress) == 0 && attempt < 60; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    progress = await stats();
    if (attempt % 10 == 9) {
      _report(
        'video_poll cap=${progress.framesCaptured} '
        'sent=${progress.framesSent} tx=${progress.packetsSent} '
        'rx=${progress.packetsReceived} dec=${progress.framesDecoded} '
        'rend=${progress.framesRendered} q=${progress.queueDepth} '
        'rtt=${progress.rttMs}',
      );
    }
    if (sender && attempt == 19 && progress.framesCaptured == 0) {
      // Windows Graphics Capture produces zero frames when the desktop is
      // locked; fail fast with a typed reason instead of a silent stall.
      throw StateError('capture_produced_no_frames_desktop_locked?');
    }
  }
  if (frames(progress) == 0) {
    throw StateError(
      'No actual video frames cap=${progress.framesCaptured} '
      'sent=${progress.framesSent} tx=${progress.packetsSent} '
      'rx=${progress.packetsReceived} dec=${progress.framesDecoded} '
      'q=${progress.queueDepth}',
    );
  }
  _report('video_active frames=${frames(progress)}');
  return frames(progress);
}

Future<void> _expectNoEndpoint(
  Future<RealtimeMediaStats> Function() stats,
) async {
  try {
    await stats();
    throw StateError('Stats readable after release');
  } on RealtimeMediaException catch (error) {
    if (error.code == RealtimeMediaErrorCode.backendFailure) rethrow;
  }
}
