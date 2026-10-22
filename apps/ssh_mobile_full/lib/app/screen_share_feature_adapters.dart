import 'package:app_core/app_core.dart';
import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';

/// Adapts the App-owned Realtime session to the Feature's consent port.
///
/// The Feature receives only typed metadata. The session, native runtime and
/// signaling transport remain owned by App Shell/SDK.
final class AppScreenShareConsentPort implements ScreenShareConsentPort {
  const AppScreenShareConsentPort(this.session);

  final RealtimeSession session;

  @override
  Stream<RealtimeConsent> get consents => session.consentEvents;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) =>
      session.sendConsent(consent);
}

/// Callback-based bridge for App/platform media owners.
///
/// App composition supplies callbacks that operate on the opaque native media
/// owner. This class deliberately has no endpoint, frame, texture, FFI or
/// WebRTC API of its own, keeping the Feature boundary testable.
final class AppScreenShareMediaPort implements ScreenShareMediaPort {
  AppScreenShareMediaPort({
    required this.events,
    required this.onStartCapture,
    required this.onStartViewer,
    required this.onStop,
    this.logger,
  });

  final AppLogger? logger;
  @override
  final Stream<ScreenShareMediaEvent> events;
  final Future<void> Function({
    required String operationId,
    required String realtimeId,
    required int generation,
  })
  onStartCapture;
  final Future<void> Function({
    required String operationId,
    required String realtimeId,
    required int generation,
  })
  onStartViewer;
  final Future<void> Function({
    required String operationId,
    required String realtimeId,
    required int generation,
  })
  onStop;

  @override
  Future<void> startCapture({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) => _run(
    'capture',
    () => onStartCapture(
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
    ),
  );

  @override
  Future<void> startViewer({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) => _run(
    'viewer',
    () => onStartViewer(
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
    ),
  );

  @override
  Future<void> stop({
    required String operationId,
    required String realtimeId,
    required int generation,
  }) => _run(
    'stop',
    () => onStop(
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
    ),
  );

  Future<void> _run(String phase, Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      final code = error is RealtimeMediaException
          ? error.code
          : RealtimeMediaErrorCode.backendFailure;
      logger?.log(
        LogRecord(
          timestamp: DateTime.now(),
          level: LogLevel.warning,
          source: 'AppScreenShareMediaPort',
          message: 'Screen-share media $phase failed: ${code.name}',
        ),
      );
      rethrow;
    }
  }
}
