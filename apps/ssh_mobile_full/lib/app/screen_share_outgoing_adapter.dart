import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';

import 'app_runtime.dart';
import 'navigation/app_route_contributions.dart';
import 'screen_share_peer_arbitration.dart';
import 'screen_share_route_scope.dart';
import 'screen_share_session_lease.dart';

/// App-owned peer action that turns the LAN secondary action into a route.
final class ScreenShareEntryCoordinator
    implements lan.LanShareScreenSharePort {
  ScreenShareEntryCoordinator({
    required this.runtime,
    required this.navigatorKey,
    AppScreenSharePeerArbitrationRegistry? arbitration,
  }) : arbitration = arbitration ?? AppScreenSharePeerArbitrationRegistry();

  final AppRuntime runtime;
  final GlobalKey<NavigatorState> navigatorKey;
  final AppScreenSharePeerArbitrationRegistry arbitration;
  final Set<String> _startsInFlight = <String>{};
  int _operationSequence = 0;

  bool get _platformSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  bool canShareWith(String peerId) {
    if (!_platformSupported ||
        peerId == runtime.lanShareSettingsAdapter.lanDeviceId) {
      return false;
    }
    final state = runtime.lanShareModule.coordinator.viewModel?.peerStateFor(
      peerId,
    );
    return state?.isTrusted == true && state?.isOnline == true;
  }

  @override
  bool canReceiveScreenShareFrom(String peerId) {
    if (!_platformSupported ||
        peerId == runtime.lanShareSettingsAdapter.lanDeviceId) {
      return false;
    }
    return runtime.lanShareModule.coordinator.viewModel
            ?.peerStateFor(peerId)
            ?.isTrusted ==
        true;
  }

  @override
  Future<void> startScreenShare(String peerId) async {
    if (!canShareWith(peerId)) {
      throw StateError('Screen sharing is unavailable for this peer.');
    }
    if (!_startsInFlight.add(peerId)) return;
    final operationId = _newOperationId();
    var acquired = false;
    var superseded = false;
    var routeActive = false;
    RealtimeSession? session;
    AppScreenShareSessionLease? lease;
    var handedOff = false;
    try {
      acquired = arbitration.acquire(
        remotePeerId: peerId,
        initiatorPeerId: runtime.lanShareSettingsAdapter.lanDeviceId,
        operationId: operationId,
        onReplaced: () async {
          superseded = true;
          if (handedOff) {
            // The route owns the lease after handoff. It will stop and release
            // the exact session when the replacement arbitration pops it.
            if (routeActive) {
              unawaited(navigatorKey.currentState?.maybePop());
            }
            return;
          }
          if (routeActive) {
            unawaited(navigatorKey.currentState?.maybePop());
          }
          final replacedSession = session;
          if (replacedSession != null) {
            try {
              await replacedSession.stop();
            } catch (_) {}
            try {
              await runtime.realtimeClient.releaseSession(replacedSession);
            } catch (_) {}
          }
        },
      );
      if (!acquired) {
        throw StateError('Another screen-share operation is already active.');
      }
      final selectedSource = await _selectSource();
      if (selectedSource == null) return;
      if (superseded) throw StateError('Screen-share intent was superseded.');

      final realtimeId = _newHexIdentity();
      session = runtime.realtimeClient.createSession(
        realtimeId: realtimeId,
        peerId: peerId,
      );
      final startResult = await session.start();
      if (startResult is SdkFailure<void>) {
        throw StateError(startResult.error.message);
      }
      if (superseded) throw StateError('Screen-share intent was superseded.');
      await _waitForIdentity(session);
      if (superseded) throw StateError('Screen-share intent was superseded.');
      lease = AppScreenShareSessionLease(
        client: runtime.realtimeClient,
        session: session,
      );
      final arguments = AppScreenShareRouteArguments(
        session: session,
        sessionLease: lease,
        localPeerId: runtime.lanShareSettingsAdapter.lanDeviceId,
        source: selectedSource.nativeSource,
        sourceOption: selectedSource.option,
        operationId: operationId,
        mode: AppScreenShareRouteMode.send,
        startOutgoing: true,
      );
      try {
        routeActive = true;
        final navigation = navigatorKey.currentState!.pushNamed(
          AppShellRouteNames.screenShare,
          arguments: arguments,
        );
        handedOff = true;
        lease = null;
        await navigation;
      } catch (_) {
        if (!handedOff && lease != null) {
          await lease.stopAndRelease();
          lease = null;
        }
        rethrow;
      }
      // Ownership was transferred to the route arguments synchronously when
      // pushNamed succeeded. The route now performs teardown on pop.
      lease = null;
    } finally {
      if (session != null && !handedOff && acquired) {
        // A successful push transfers the lease; failures before transfer are
        // cleaned here. The route-owned lease is intentionally untouched.
        if (lease != null) {
          try {
            await lease.stopAndRelease();
          } catch (_) {}
        } else {
          if (session.state != RealtimeSessionState.stopped &&
              session.state != RealtimeSessionState.failed) {
            try {
              await session.stop();
            } catch (_) {}
          }
          try {
            await runtime.realtimeClient.releaseSession(session);
          } catch (_) {}
        }
      }
      if (acquired) {
        arbitration.release(
          remotePeerId: peerId,
          initiatorPeerId: runtime.lanShareSettingsAdapter.lanDeviceId,
          operationId: operationId,
        );
      }
      _startsInFlight.remove(peerId);
    }
  }

  Future<_SelectedScreenShareSource?> _selectSource() async {
    final context = navigatorKey.currentState?.context;
    if (context == null) throw StateError('Navigator is not ready.');
    final capabilities = appScreenSharePlatformCapabilitiesFor(
      runtime.realtimeMediaResources.backend,
    );
    final sources = await capabilities.listCaptureSources();
    if (sources.isEmpty) throw StateError('No screen source is available.');
    final options = <_SelectedScreenShareSource>[
      for (var index = 0; index < sources.length; index++)
        _SelectedScreenShareSource(
          nativeSource: sources[index],
          option: ScreenShareSourceOption(
            opaqueId: _newSourceToken(index),
            kind: sources[index].kind == ScreenCaptureSourceKind.display
                ? ScreenShareSourceKind.display
                : ScreenShareSourceKind.window,
            label: _boundedSourceLabel(
              sources[index].label,
              sources[index].kind,
            ),
            width: _boundedDimension(sources[index].width),
            height: _boundedDimension(sources[index].height),
          ),
        ),
    ];
    return showModalBottomSheet<_SelectedScreenShareSource>(
      context: context,
      builder: (context) => ScreenShareSourcePicker(
        options: [
          for (final selected in options) selected.option,
        ],
        onSelected: (option) {
          final selected = options.firstWhere(
            (candidate) => candidate.option.opaqueId == option.opaqueId,
          );
          Navigator.pop(context, selected);
        },
      ),
    );
  }

  Future<void> _waitForIdentity(RealtimeSession session) async {
    bool ready(RealtimeSnapshot? snapshot) {
      final effectiveState = snapshot?.state ?? session.state;
      return (effectiveState == RealtimeSessionState.negotiating ||
              effectiveState == RealtimeSessionState.connected) &&
          (snapshot?.generation ?? session.generation) != null &&
          (snapshot?.sharedSessionInstanceId ??
                  session.sharedSessionInstanceId) !=
              null;
    }

    if (ready(session.currentSnapshot)) return;
    final completer = Completer<void>();
    late final StreamSubscription<RealtimeSnapshot> subscription;
    subscription = session.snapshots.listen((snapshot) {
      if (!completer.isCompleted && ready(snapshot)) {
        completer.complete();
      }
    });
    try {
      if (ready(session.currentSnapshot)) return;
      await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      await subscription.cancel();
    }
  }

  String _newOperationId() {
    _operationSequence = (_operationSequence + 1) & 0xffff;
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
        '${_operationSequence.toRadixString(16).padLeft(8, '0')}';
  }

  String _newHexIdentity() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(16, '0')}'
      '${(_operationSequence++).toRadixString(16).padLeft(16, '0')}';

  String _newSourceToken(int index) =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(16, '0')}'
      '${(index ^ _operationSequence).toRadixString(16).padLeft(16, '0')}';
}

String _boundedSourceLabel(String? label, ScreenCaptureSourceKind kind) {
  final value = label?.trim();
  final fallback = kind == ScreenCaptureSourceKind.display
      ? 'Display'
      : 'Window';
  if (value == null || value.isEmpty) return fallback;
  if (value.length <= 120) return value;
  return '${value.substring(0, 117)}...';
}

int _boundedDimension(int? value) {
  if (value == null || value < 0) return 0;
  return value > 16_384 ? 16_384 : value;
}

final class _SelectedScreenShareSource {
  const _SelectedScreenShareSource({
    required this.nativeSource,
    required this.option,
  });

  final ScreenCaptureSource nativeSource;
  final ScreenShareSourceOption option;
}
