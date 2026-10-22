import 'dart:async';

import 'package:app_core/app_core.dart';

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
import 'screen_share_codec_mode_picker.dart';

/// App-owned peer action that turns the LAN secondary action into a route.
final class ScreenShareEntryCoordinator implements lan.LanShareScreenSharePort {
  ScreenShareEntryCoordinator({
    required this.runtime,
    required this.navigatorKey,
    AppScreenSharePeerArbitrationRegistry? arbitration,
    AppScreenShareSessions? sessions,
  }) : _ownsArbitration = arbitration == null,
       _ownsSessions = sessions == null,
       sessions = sessions ?? AppScreenShareSessions(),
       arbitration = arbitration ?? AppScreenSharePeerArbitrationRegistry();

  final AppRuntime runtime;
  final GlobalKey<NavigatorState> navigatorKey;
  final AppScreenSharePeerArbitrationRegistry arbitration;
  final bool _ownsArbitration;
  final AppScreenShareSessions sessions;
  final bool _ownsSessions;
  Future<void>? _closing;
  bool _disposed = false;
  final Completer<void> _disposedSignal = Completer<void>();
  final Set<String> _startsInFlight = <String>{};
  int _operationSequence = 0;

  bool get _platformSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  bool canShareWith(String peerId) {
    if (_disposed ||
        !_platformSupported ||
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
    if (_disposed ||
        !_platformSupported ||
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
            final replaced = sessions.current;
            if (replaced?.arguments.operationId == operationId) {
              await replaced!.stop();
            }
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
      if (superseded || _disposed) {
        throw StateError('Screen-share intent was superseded.');
      }
      _logPreparation('connecting authenticated peer');

      final coordinator = runtime.lanShareModule.coordinator;
      final network = coordinator.nativeTransferCoordinator;
      if (network == null) throw StateError('Network receiver is not ready.');
      final prepared = await network.prepareRealtimeConnection(
        peerId: peerId,
        discovery: coordinator.viewModel?.peerStateFor(peerId)?.discovery,
      );
      if (prepared is SdkFailure<void>) {
        throw StateError(prepared.error.message);
      }
      if (superseded || _disposed) {
        throw StateError('Screen-share intent was superseded.');
      }
      _logPreparation('starting native session');

      final realtimeId = _newHexIdentity();
      session = runtime.realtimeClient.createSession(
        realtimeId: realtimeId,
        peerId: peerId,
      );
      final startResult = await session.start();
      if (startResult is SdkFailure<void>) {
        throw StateError(startResult.error.message);
      }
      if (superseded || _disposed) {
        throw StateError('Screen-share intent was superseded.');
      }
      await waitForScreenShareSessionIdentity(
        session,
        cancelled: _disposedSignal.future,
      );
      if (superseded || _disposed) {
        throw StateError('Screen-share intent was superseded.');
      }
      _logPreparation('opening consent route');
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
        codecMode: selectedSource.codecMode,
        operationId: operationId,
        mode: AppScreenShareRouteMode.send,
        startOutgoing: true,
        arbitration: arbitration,
      );
      final operation = sessions.open(
        arguments,
        runtime.realtimeMediaResources,
      );
      handedOff = true;
      lease = null;
      try {
        routeActive = true;
        final navigation = navigatorKey.currentState!.pushNamed(
          AppShellRouteNames.screenShare,
          arguments: arguments,
        );
        await navigation;
      } catch (_) {
        await operation.stop();
        rethrow;
      }
      // The App session owner keeps sharing when its presentation route pops.
      lease = null;
    } finally {
      if (session != null && !handedOff && acquired) {
        // Only failures before App-owner adoption are cleaned by the entry.
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
      if (acquired && !handedOff) {
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
    if (!context.mounted) return null;
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
      builder: (context) => AppScreenShareSourcePicker(
        options: [for (final selected in options) selected.option],
        onSelected: (option, codecMode) {
          final selected = options.firstWhere(
            (candidate) => candidate.option.opaqueId == option.opaqueId,
          );
          Navigator.pop(
            context,
            _SelectedScreenShareSource(
              nativeSource: selected.nativeSource,
              option: selected.option,
              codecMode: codecMode,
            ),
          );
        },
      ),
    );
  }

  void dispose() => unawaited(close());

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_disposed) return;
    _disposed = true;
    _disposedSignal.complete();
    if (_ownsSessions) {
      await sessions.close();
      sessions.dispose();
    }
    if (_ownsArbitration) arbitration.dispose();
  }

  void _logPreparation(String phase) => runtime.logger.log(
    LogRecord(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      source: 'ScreenShareEntryCoordinator',
      message: 'Screen-share preparation: $phase',
    ),
  );

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
    this.codecMode = RealtimeMediaCodecMode.hardware,
  });

  final ScreenCaptureSource nativeSource;
  final ScreenShareSourceOption option;
  final RealtimeMediaCodecMode codecMode;
}
