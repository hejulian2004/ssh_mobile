import 'dart:async';

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';

import 'realtime_media_feature_adapters.dart';
import 'screen_share_media_coordinator.dart';
import 'screen_share_feature_adapters.dart';

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
    this.source,
    this.mode = AppScreenShareRouteMode.receive,
    this.startOutgoing = false,
  });

  final RealtimeSession session;
  final String localPeerId;
  final ScreenCaptureSource? source;
  final AppScreenShareRouteMode mode;
  final bool startOutgoing;
}

/// Route scope for the App Shell's explicit screen-share route.
final class AppScreenShareRouteScope extends StatefulWidget {
  const AppScreenShareRouteScope({
    required this.arguments,
    required this.resources,
    this.capabilities,
    super.key,
  });

  final AppScreenShareRouteArguments arguments;
  final AppRealtimeMediaResources resources;
  final AppScreenSharePlatformCapabilities? capabilities;

  @override
  State<AppScreenShareRouteScope> createState() =>
      _AppScreenShareRouteScopeState();
}

final class _AppScreenShareRouteScopeState
    extends State<AppScreenShareRouteScope> {
  AppScreenShareMediaCoordinator? _mediaCoordinator;
  late final Future<void> _initialization;
  ScreenShareController? _controller;
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
    await _controller!.setMediaReady(true);
    if (_routeDisposed) {
      _controller!.dispose();
      return;
    }
    if (widget.arguments.startOutgoing) {
      await _controller!.startOutgoing();
    }
  }

  @override
  void dispose() {
    _routeDisposed = true;
    unawaited(_disposeRoute());
    super.dispose();
  }

  Future<void> _disposeRoute() async {
    final controller = _controller;
    if (controller != null) {
      try {
        await controller.cancel();
      } catch (_) {
        // Route disposal remains best effort; the coordinator retains any
        // retryable native lease for its own cleanup path.
      }
      controller.dispose();
    }
    final mediaCoordinator = _mediaCoordinator;
    if (mediaCoordinator != null) {
      await mediaCoordinator.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ScreenShareConsentView(controller: controller),
                    if (widget.arguments.mode == AppScreenShareRouteMode.send &&
                        operation.state == ScreenShareOperationState.idle &&
                        widget.arguments.source != null) ...<Widget>[
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: controller.startOutgoing,
                        child: const Text('Request screen share'),
                      ),
                    ],
                    if (!operation.isTerminal &&
                        operation.state !=
                            ScreenShareOperationState.idle) ...<Widget>[
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: controller.cancel,
                        child: const Text('Stop screen share'),
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
  );
}

String _errorCode(Object? error) => error is RealtimeMediaException
    ? error.code.name
    : RealtimeMediaErrorCode.backendFailure.name;
