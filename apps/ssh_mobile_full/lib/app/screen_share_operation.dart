import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';
import 'realtime_media_feature_adapters.dart';
import 'screen_share_annotation_binding.dart';
import 'screen_share_media_coordinator.dart';
import 'screen_share_feature_adapters.dart';
import 'screen_share_route_arguments.dart';

/// App-owned operation; presentation routes borrow it and never stop it on pop.
final class AppScreenShareOperation extends ChangeNotifier {
  final AppScreenShareRouteArguments arguments;
  final AppRealtimeMediaResources resources;
  final AppScreenSharePlatformCapabilities? capabilities;
  AppScreenShareMediaCoordinator? _mediaCoordinator;
  late final Future<void> _initialization;
  ScreenShareController? _controller;
  AppScreenShareAnnotationBinding? _annotation;
  StreamSubscription<RealtimeSnapshot>? _readinessSubscription;
  Future<void> _readinessUpdate = Future<void>.value();
  bool? _appliedMediaReadiness;
  bool _closed = false;
  bool _finished = false;
  bool _notifierDisposed = false;
  bool _cleanupFailed = false;
  Future<void>? _terminalCleanup;
  Future<void>? _closeFuture;
  Future<void>? _stopFuture;

  Future<void> get initialization => _initialization;
  ScreenShareController? get controller => _controller;
  ScreenShareAnnotationSession? get annotation => _annotation?.session;
  bool get annotationInteractive => _annotation?.interactive ?? false;
  AppScreenShareMediaCoordinator? get media => _mediaCoordinator;
  bool get finished => _finished;
  bool get stopping => _stopFuture != null;
  bool get cleanupFailed => _cleanupFailed;

  AppScreenShareOperation({
    required this.arguments,
    required this.resources,
    this.capabilities,
  }) {
    try {
      _mediaCoordinator = AppScreenShareMediaCoordinator(
        session: arguments.session,
        resources: resources,
        capabilities:
            capabilities ??
            appScreenSharePlatformCapabilitiesFor(resources.backend),
        source: arguments.source,
        codecMode: arguments.codecMode,
        admitOperation: (operationId) =>
            arguments.arbitration?.activate(
              remotePeerId: arguments.session.peerId,
              initiatorPeerId:
                  _controller?.snapshot.role == ScreenShareRole.sender
                  ? arguments.localPeerId
                  : arguments.session.peerId,
              operationId: operationId,
            ) ??
            true,
      );
      _initialization = _initialize().catchError(_failInitialization);
    } catch (error, stackTrace) {
      _initialization = _failInitialization(error, stackTrace);
    }
  }

  Future<Never> _failInitialization(Object error, StackTrace stackTrace) async {
    try {
      await close();
    } catch (_) {}
    Error.throwWithStackTrace(error, stackTrace);
  }

  Future<void> _initialize() async {
    if (arguments.startOutgoing &&
        arguments.mode != AppScreenShareRouteMode.send) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.invalidArgument,
        'Only a sending screen-share route can start outgoing.',
      );
    }
    final token = arguments.session.mediaToken;
    if (token == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native Realtime generation is not available.',
      );
    }
    final sharedSessionInstanceId = arguments.session.sharedSessionInstanceId;
    if (sharedSessionInstanceId == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Shared Realtime session instance is not available.',
      );
    }
    _controller = ScreenShareController(
      consentPort: AppScreenShareConsentPort(arguments.session),
      mediaPort: _mediaCoordinator!.port,
      realtimeId: token.realtimeId,
      sharedSessionInstanceId: sharedSessionInstanceId,
      generation: token.generation,
      localPeerId: arguments.localPeerId,
      remotePeerId: arguments.session.peerId,
    );
    _controller!.addListener(_onOperationChanged);
    final initialRequest = arguments.initialIncomingRequest;
    if (initialRequest != null) {
      _controller!.seedIncomingRequest(initialRequest);
    }
    if (_closed) {
      _controller!.dispose();
      return;
    }
    _annotation = AppScreenShareAnnotationBinding(
      realtime: arguments.session,
      operation: _controller!,
      snapshot: () => _controller!.snapshot,
      frameSize: arguments.mode == AppScreenShareRouteMode.send
          ? _mediaCoordinator!.captureFrameSize
          : _mediaCoordinator!.remoteVideoSize,
      overlay: arguments.mode == AppScreenShareRouteMode.send
          ? resources.guidanceOverlay
          : null,
      onChanged: () {
        if (!_notifierDisposed && !_closed) notifyListeners();
      },
    );
    _annotation!.start();
    await _mediaCoordinator!.prepare(
      capture: arguments.mode == AppScreenShareRouteMode.send,
    );
    if (_closed) {
      _controller!.dispose();
      return;
    }
    _startReadinessObservation();
    if (_closed) {
      _controller!.dispose();
      return;
    }
    if (arguments.startOutgoing) {
      await _controller!.startOutgoing(operationId: arguments.operationId);
    } else if (arguments.acceptIncomingOnOpen &&
        arguments.initialIncomingRequest != null) {
      // The global incoming host is the user decision point. Once it has
      // claimed the native provisional binding, this operation sends the typed
      // ACCEPT immediately; transport Connected remains a separate media gate.
      await _controller!.acceptIncoming();
    }
  }

  void _onOperationChanged() {
    if (!_closed) notifyListeners();
    final operation = _controller!.snapshot;
    if (_closed ||
        !operation.isTerminal ||
        operation.operationId == null ||
        _terminalCleanup != null) {
      return;
    }
    final cleanup = _finishOperation(operation);
    _terminalCleanup = cleanup;
    unawaited(
      cleanup.catchError((_) {
        _cleanupFailed = true;
        if (!_notifierDisposed) notifyListeners();
      }),
    );
  }

  Future<void> _finishOperation(ScreenShareOperationSnapshot operation) async {
    await _mediaCoordinator!.port.stop(
      operationId: operation.operationId!,
      realtimeId: operation.realtimeId,
      generation: operation.generation,
    );
    await arguments.sessionLease?.stopAndRelease();
    _releaseArbitration();
    _finished = true;
    if (!_closed) notifyListeners();
  }

  void _releaseArbitration() {
    final operation = _controller?.snapshot;
    final id = operation?.operationId ?? arguments.operationId;
    if (id == null) return;
    final sender =
        operation?.role == ScreenShareRole.sender ||
        (operation?.role == null &&
            arguments.mode == AppScreenShareRouteMode.send);
    arguments.arbitration?.release(
      remotePeerId: arguments.session.peerId,
      initiatorPeerId: sender
          ? arguments.localPeerId
          : arguments.session.peerId,
      operationId: id,
    );
  }

  Future<void> _disposeOwnedResources() async {
    _annotation?.dispose();
    _annotation = null;
    await _readinessSubscription?.cancel();
    _readinessSubscription = null;
    try {
      await _readinessUpdate;
    } catch (_) {}
    final controller = _controller;
    final mediaCoordinator = _mediaCoordinator;
    final lease = arguments.sessionLease;
    if (arguments.mode == AppScreenShareRouteMode.send) {
      if (controller != null) {
        controller.dispose();
      }
      if (mediaCoordinator != null) {
        try {
          await mediaCoordinator.dispose();
        } catch (_) {}
      }
      if (lease != null) {
        try {
          await lease.stopAndRelease();
        } catch (_) {}
      }
      return;
    }
    if (controller != null) {
      controller.dispose();
    }
    if (lease != null) {
      try {
        await lease.stopAndRelease();
      } catch (_) {}
    }
    if (mediaCoordinator != null) {
      try {
        await mediaCoordinator.dispose();
      } catch (_) {}
    }
  }

  void _startReadinessObservation() {
    final session = arguments.session;
    _readinessSubscription = session.snapshots.listen((_) {
      _enqueueReadinessSync();
    });
    // Read, subscribe, then read again. The second check closes the window in
    // which native can publish Connected between the first read and listen().
    _enqueueReadinessSync();
    _enqueueReadinessSync();
  }

  void _enqueueReadinessSync() {
    _readinessUpdate = _readinessUpdate.then((_) async {
      if (_closed || _controller == null) return;
      final token = arguments.session.mediaToken;
      final snapshot = arguments.session.currentSnapshot;
      final state = snapshot?.state ?? arguments.session.state;
      final generation = snapshot?.generation ?? arguments.session.generation;
      final sharedSessionInstanceId =
          snapshot?.sharedSessionInstanceId ??
          arguments.session.sharedSessionInstanceId;
      final controller = _controller!;
      if (state == RealtimeSessionState.stopped ||
          state == RealtimeSessionState.failed ||
          (generation != null && generation != controller.generation) ||
          (sharedSessionInstanceId != null &&
              sharedSessionInstanceId != controller.sharedSessionInstanceId)) {
        _mediaCoordinator!.reportTransportLost(controller.snapshot);
        return;
      }
      final ready =
          state == RealtimeSessionState.connected &&
          token != null &&
          generation == token.generation &&
          sharedSessionInstanceId == arguments.session.sharedSessionInstanceId;
      if (_appliedMediaReadiness == ready) return;
      await _controller!.setMediaReady(ready);
      _appliedMediaReadiness = ready;
    });
  }

  /// An explicit local stop, separate from detaching a viewer page.
  Future<void> stop() => _stopFuture ??= _stop().whenComplete(() {
    _stopFuture = null;
    if (!_notifierDisposed) notifyListeners();
  });
  Future<void> _stop() async {
    if (!_closed) notifyListeners();
    if (_closed || _finished) return;
    try {
      await _controller?.cancel().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Explicit Stop must still release local resources if signaling stalls.
    }
    if (_finished) return;
    final snapshot = _controller?.snapshot;
    try {
      if (snapshot?.operationId == null) {
        await close();
      } else {
        if (_terminalCleanup == null || _cleanupFailed) {
          _cleanupFailed = false;
          _terminalCleanup = _finishOperation(snapshot!);
        }
        await _terminalCleanup;
      }
    } catch (_) {
      // A failed native release remains owned and blocks the next operation.
      // Explicit retry may finish it; page detach cannot discard the owner.
      _cleanupFailed = true;
    }
  }

  /// App shutdown or retirement after a terminal operation.
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closed = true;
    final controller = _controller;
    controller?.removeListener(_onOperationChanged);
    try {
      try {
        if (_stopFuture == null) {
          await controller?.cancel().timeout(const Duration(seconds: 5));
        }
      } catch (_) {}
      controller?.dispose();
      try {
        await _terminalCleanup;
      } catch (_) {}
      await _disposeOwnedResources();
    } finally {
      _finished = true;
      _releaseArbitration();
      if (!_notifierDisposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _notifierDisposed = true;
    super.dispose();
  }
}
