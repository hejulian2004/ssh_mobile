import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:realtime_media/realtime_media.dart';

/// Route-owned observations of an attached native media worker.
/// A missing snapshot is retryable; a typed worker failure is terminal.
final class AppScreenShareMediaMonitor {
  AppScreenShareMediaMonitor({
    required this.readStats,
    required this.isCurrent,
    required this.onFailure,
    required this.direction,
    this.logger,
    this.onStats,
  }) {
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_sample());
    });
  }

  final Future<RealtimeMediaStats> Function() readStats;
  final bool Function() isCurrent;
  final void Function(RealtimeMediaErrorCode) onFailure;
  final RealtimeMediaDirection direction;
  final AppLogger? logger;
  final void Function(RealtimeMediaStats)? onStats;
  Timer? _timer;
  bool _disposed = false;
  bool _sampling = false;

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  bool get _live => !_disposed && isCurrent();

  Future<void> _sample() async {
    if (_sampling || _disposed) return;
    if (!_live) {
      dispose();
      return;
    }
    _sampling = true;
    try {
      final stats = await readStats();
      if (!_live) return;
      onStats?.call(stats);
      _log(
        LogLevel.info,
        'progress: size=${stats.width}x${stats.height} '
        'captured=${stats.framesCaptured} sent=${stats.framesSent} '
        'received=${stats.packetsReceived} decoded=${stats.framesDecoded} '
        'rendered=${stats.framesRendered} dropped=${stats.framesDropped} '
        'rtpSent=${stats.packetsSent} queue=${stats.queueDepth} '
        'keyframes=${stats.keyframeRequests}',
      );
    } catch (error) {
      if (!_live) return;
      final code = error is RealtimeMediaException
          ? error.code
          : RealtimeMediaErrorCode.backendFailure;
      _log(LogLevel.warning, 'failed: ${code.name}');
      if (_isWorkerFailure(code)) {
        dispose();
        onFailure(code);
      }
    } finally {
      _sampling = false;
    }
  }

  void _log(LogLevel level, String observation) {
    logger?.log(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        source: 'AppScreenShareMediaMonitor',
        message: 'Screen-share media ${direction.name} $observation',
      ),
    );
  }

  static bool _isWorkerFailure(RealtimeMediaErrorCode code) => switch (code) {
    RealtimeMediaErrorCode.encoderFailed ||
    RealtimeMediaErrorCode.encoderUnavailable ||
    RealtimeMediaErrorCode.decoderFailed ||
    RealtimeMediaErrorCode.decoderUnavailable ||
    RealtimeMediaErrorCode.captureSourceEnded ||
    RealtimeMediaErrorCode.permissionDenied ||
    RealtimeMediaErrorCode.frameRejected ||
    RealtimeMediaErrorCode.recreateRequired => true,
    _ => false,
  };
}
