import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:app_ui/app_ui.dart';
import 'realtime_media_feature_adapters.dart';
import 'screen_share_route_arguments.dart';
import 'screen_share_operation.dart';
import 'screen_share_sessions.dart';
import 'screen_share_video_page.dart';
export 'screen_share_media_coordinator.dart';
export 'screen_share_route_arguments.dart';
export 'screen_share_sessions.dart';

/// Route scope for the App Shell's explicit screen-share route.
final class AppScreenShareRouteScope extends StatefulWidget {
  const AppScreenShareRouteScope({
    required this.arguments,
    required this.resources,
    required this.sessions,
    this.capabilities,
    this.presenter,
    super.key,
  });

  final AppScreenShareRouteArguments arguments;
  final AppRealtimeMediaResources resources;
  final AppScreenShareSessions sessions;
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
  late final AppScreenShareOperation _operation;
  @override
  void initState() {
    super.initState();
    _operation = widget.sessions.attach(
      widget.arguments,
      widget.resources,
      capabilities: widget.capabilities,
    );
  }

  @override
  void dispose() {
    widget.sessions.detach(_operation);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPageSurface(
    child: FutureBuilder<void>(
      future: _operation.initialization,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: AppBar(title: const Text('Screen sharing')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || _operation.controller == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Screen sharing')),
            body: Center(
              child: Text(
                'Screen sharing unavailable (${_errorCode(snapshot.error)}).',
              ),
            ),
          );
        }
        final controller = _operation.controller!;
        return AnimatedBuilder(
          animation: _operation,
          builder: (context, _) {
            final operation = controller.snapshot;
            final remoteSurface = _operation.media?.remoteSurface;
            final presenter =
                widget.presenter ?? const AppTextureRemoteVideoPresenter();
            return AppScreenShareVideoPage(
              annotation: _operation.annotationInteractive
                  ? _operation.annotation
                  : null,
              videoSize: _operation.media!.remoteVideoSize,
              autoEnterFullscreen: operation.role == ScreenShareRole.receiver,
              enableViewerControls:
                  remoteSurface != null &&
                  !operation.isTerminal &&
                  !_operation.finished,
              onStop:
                  (!operation.isTerminal || _operation.cleanupFailed) &&
                      !_operation.stopping &&
                      !_operation.finished
                  ? _operation.stop
                  : null,
              video: remoteSurface == null
                  ? const Center(
                      child: Icon(Icons.screen_share_outlined, size: 48),
                    )
                  : presenter.build(context, remoteSurface),
              controls: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (operation.state == ScreenShareOperationState.idle &&
                      widget.arguments.mode == AppScreenShareRouteMode.send &&
                      widget.arguments.source != null)
                    FilledButton.icon(
                      onPressed: () => controller.startOutgoing(
                        operationId: widget.arguments.operationId,
                      ),
                      icon: const Icon(Icons.screen_share_outlined),
                      label: const Text('Start sharing'),
                    ),
                  if (_operation.finished && !operation.isTerminal)
                    const Text('Screen sharing stopped')
                  else
                    ScreenShareConsentView(
                      controller: controller,
                      showIncomingActions:
                          !widget.arguments.acceptIncomingOnOpen,
                    ),
                  if (operation.state == ScreenShareOperationState.failed &&
                      _operation.media?.failureCode != null)
                    Text(
                      _failureDescription(
                        context,
                        _operation.media!.failureCode!,
                      ),
                    ),
                  if ((!operation.isTerminal || _operation.cleanupFailed) &&
                      !_operation.finished &&
                      operation.state != ScreenShareOperationState.idle) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _operation.stopping ? null : _operation.stop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(
                        _operation.cleanupFailed
                            ? 'Retry stopping screen share'
                            : 'Stop screen share',
                      ),
                    ),
                  ],
                ],
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

String _failureDescription(BuildContext context, RealtimeMediaErrorCode code) {
  final chinese = Localizations.localeOf(context).languageCode == 'zh';
  return chinese ? '屏幕共享错误：${code.name}' : 'Screen-share error: ${code.name}';
}
