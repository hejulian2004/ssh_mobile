import 'dart:async';

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:app_ui/app_ui.dart';

import 'realtime_media_feature_adapters.dart';
import 'screen_share_media_coordinator.dart';
import 'screen_share_feature_adapters.dart';
import 'screen_share_session_lease.dart';

export 'screen_share_media_coordinator.dart';

/// Media role selected by the App Shell screen-share route.
enum AppScreenShareRouteMode { send, receive }

/// Strongly typed arguments for the App Shell screen-share route.
///
/// The caller supplies the App-owned Realtime session and the local peer
/// identity. A capture source is required only when the route is used to send
/// a screen; incoming-only routes can omit it.
final class AppScreenShareRouteArguments {
  const AppScreenShareRouteArguments({
    required this.session,
    required this.localPeerId,
    this.sessionLease,
    this.operationId,
    this.initialIncomingRequest,
    this.source,
    this.sourceOption,
    this.mode = AppScreenShareRouteMode.receive,
    this.startOutgoing = false,
    this.acceptIncomingOnOpen = false,
  });

  final RealtimeSession session;
  final AppScreenShareSessionLease? sessionLease;
  final String localPeerId;
  final String? operationId;
  final RealtimeConsent? initialIncomingRequest;
  final ScreenCaptureSource? source;
  final ScreenShareSourceOption? sourceOption;
  final AppScreenShareRouteMode mode;
  final bool startOutgoing;
  final bool acceptIncomingOnOpen;
}

/// Route scope for the App Shell's explicit screen-share route.
final class AppScreenShareRouteScope extends StatefulWidget {
  const AppScreenShareRouteScope({
    required this.arguments,
    required this.resources,
    this.capabilities,
    this.presenter,
    super.key,
  });

  final AppScreenShareRouteArguments arguments;
  final AppRealtimeMediaResources resources;
  final AppScreenSharePlatformCapabilities? capabilities;
  final AppRemoteVideoPresenter? presenter;

  @override
  State<AppScreenShareRouteScope> createState() =>
      _AppScreenShareRouteScopeState();
}

/// App/platform presentation boundary for the opaque native video surface.
abstract interface class AppRemoteVideoPresenter {
  Widget build(BuildContext context, RemoteVideoSurface surface);
}

/// Default Flutter texture presenter for Windows and Android native surfaces.
///
/// Only the App/platform layer interprets the platform presentation id; the
/// Feature receives no surface or native handle.
final class AppTextureRemoteVideoPresenter implements AppRemoteVideoPresenter {
  const AppTextureRemoteVideoPresenter();

  @override
  Widget build(BuildContext context, RemoteVideoSurface surface) {
    final textureId = int.tryParse(surface.id.value);
    if (textureId == null || textureId < 0) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: Text('Remote video surface unavailable.')),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(child: Texture(textureId: textureId)),
    );
  }
}

final class _AppScreenShareRouteScopeState
    extends State<AppScreenShareRouteScope> {
  AppScreenShareMediaCoordinator? _mediaCoordinator;
  late final Future<void> _initialization;
  ScreenShareController? _controller;
  StreamSubscription<RealtimeSnapshot>? _readinessSubscription;
  Future<void> _readinessUpdate = Future<void>.value();
  bool? _appliedMediaReadiness;
  bool _routeDisposed = false;

  @override
  void initState() {
    super.initState();
    try {
      _mediaCoordinator = AppScreenShareMediaCoordinator(
        session: widget.arguments.session,
        resources: widget.resources,
        capabilities:
            widget.capabilities ??
            appScreenSharePlatformCapabilitiesFor(widget.resources.backend),
        source: widget.arguments.source,
      );
      _initialization = _initialize();
    } catch (error, stackTrace) {
      _initialization = Future<void>.error(error, stackTrace);
    }
  }

  Future<void> _initialize() async {
    if (widget.arguments.startOutgoing &&
        widget.arguments.mode != AppScreenShareRouteMode.send) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.invalidArgument,
        'Only a sending screen-share route can start outgoing.',
      );
    }
    final token = widget.arguments.session.mediaToken;
    if (token == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native Realtime generation is not available.',
      );
    }
    final sharedSessionInstanceId =
        widget.arguments.session.sharedSessionInstanceId;
    if (sharedSessionInstanceId == null) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Shared Realtime session instance is not available.',
      );
    }
    _controller = ScreenShareController(
      consentPort: AppScreenShareConsentPort(widget.arguments.session),
      mediaPort: _mediaCoordinator!.port,
      realtimeId: token.realtimeId,
      sharedSessionInstanceId: sharedSessionInstanceId,
      generation: token.generation,
      localPeerId: widget.arguments.localPeerId,
      remotePeerId: widget.arguments.session.peerId,
    );
    final initialRequest = widget.arguments.initialIncomingRequest;
    if (initialRequest != null) {
      _controller!.seedIncomingRequest(initialRequest);
    }
    if (_routeDisposed) {
      _controller!.dispose();
      return;
    }
    await _mediaCoordinator!.prepare(
      capture: widget.arguments.mode == AppScreenShareRouteMode.send,
    );
    if (_routeDisposed) {
      _controller!.dispose();
      return;
    }
    _startReadinessObservation();
    if (_routeDisposed) {
      _controller!.dispose();
      return;
    }
    if (widget.arguments.startOutgoing) {
      await _controller!.startOutgoing(
        operationId: widget.arguments.operationId,
      );
    } else if (widget.arguments.acceptIncomingOnOpen &&
        widget.arguments.initialIncomingRequest != null) {
      // The global incoming host is the user decision point. Once it has
      // claimed the native provisional binding, the route sends the typed
      // ACCEPT immediately; transport Connected remains a separate media gate.
      await _controller!.acceptIncoming();
    }
  }

  @override
  void dispose() {
    _routeDisposed = true;
    final controller = _controller;
    if (controller != null) {
      // Start the business cancellation before the first async teardown
      // await, then synchronously cancel its expiry timer/subscriptions. The
      // media coordinator and session lease still finish the owned cleanup in
      // [_disposeRoute].
      try {
        unawaited(controller.cancel().catchError((_) {}));
      } catch (_) {}
      controller.dispose();
    }
    unawaited(_disposeRoute());
    super.dispose();
  }

  Future<void> _disposeRoute() async {
    await _readinessSubscription?.cancel();
    _readinessSubscription = null;
    try {
      await _readinessUpdate;
    } catch (_) {}
    final controller = _controller;
    final mediaCoordinator = _mediaCoordinator;
    final lease = widget.arguments.sessionLease;
    if (widget.arguments.mode == AppScreenShareRouteMode.send) {
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
    final session = widget.arguments.session;
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
      if (_routeDisposed || _controller == null) return;
      final token = widget.arguments.session.mediaToken;
      final snapshot = widget.arguments.session.currentSnapshot;
      final state = snapshot?.state ?? widget.arguments.session.state;
      final generation =
          snapshot?.generation ?? widget.arguments.session.generation;
      final sharedSessionInstanceId =
          snapshot?.sharedSessionInstanceId ??
          widget.arguments.session.sharedSessionInstanceId;
      final ready =
          state == RealtimeSessionState.connected &&
          token != null &&
          generation == token.generation &&
          sharedSessionInstanceId ==
              widget.arguments.session.sharedSessionInstanceId;
      if (_appliedMediaReadiness == ready) return;
      await _controller!.setMediaReady(ready);
      _appliedMediaReadiness = ready;
    });
  }

  @override
  Widget build(BuildContext context) => AppPageSurface(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Screen sharing')),
      body: FutureBuilder<void>(
        future: _initialization,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || _controller == null) {
            return Center(
              child: Text(
                'Screen sharing unavailable (${_errorCode(snapshot.error)}).',
              ),
            );
          }
          final controller = _controller!;
          return AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final operation = controller.snapshot;
              final remoteSurface = _mediaCoordinator?.remoteSurface;
              final presenter =
                  widget.presenter ?? const AppTextureRemoteVideoPresenter();
              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: <Widget>[
                      Expanded(
                        child: remoteSurface == null
                            ? Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.black12,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.screen_share_outlined,
                                    size: 48,
                                  ),
                                ),
                              )
                            : presenter.build(context, remoteSurface),
                      ),
                      const SizedBox(height: 12),
                      if (operation.state == ScreenShareOperationState.idle &&
                          widget.arguments.mode ==
                              AppScreenShareRouteMode.send &&
                          widget.arguments.source != null)
                        FilledButton.icon(
                          onPressed: () => controller.startOutgoing(
                            operationId: widget.arguments.operationId,
                          ),
                          icon: const Icon(Icons.screen_share_outlined),
                          label: const Text('Start sharing'),
                        ),
                      ScreenShareConsentView(
                        controller: controller,
                        showIncomingActions:
                            !widget.arguments.acceptIncomingOnOpen,
                      ),
                      if (!operation.isTerminal &&
                          operation.state !=
                              ScreenShareOperationState.idle) ...<Widget>[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: controller.cancel,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Stop screen share'),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

String _errorCode(Object? error) => error is RealtimeMediaException
    ? error.code.name
    : RealtimeMediaErrorCode.backendFailure.name;
