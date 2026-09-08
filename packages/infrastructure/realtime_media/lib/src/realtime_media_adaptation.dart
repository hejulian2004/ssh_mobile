import 'realtime_media_stats.dart';

/// Why a bounded adaptation decision was produced.
enum RealtimeMediaAdaptationReason { steady, congestion, recovery }

/// Explicit sender target selected from one low-frequency native snapshot.
final class RealtimeMediaAdaptationDecision {
  const RealtimeMediaAdaptationDecision({
    required this.bitrateKbps,
    required this.framerate,
    required this.width,
    required this.height,
    required this.reason,
  });

  final int bitrateKbps;
  final int framerate;
  final int width;
  final int height;
  final RealtimeMediaAdaptationReason reason;
}

/// Stateless, bounded adaptation policy.
///
/// It only recommends a finite target; the native owner applies it while
/// preserving the three-frame queue invariant. It never queues or stores
/// encoded frames in Dart.
final class RealtimeMediaAdaptationPolicy {
  const RealtimeMediaAdaptationPolicy({
    this.minBitrateKbps = 256,
    this.maxBitrateKbps = 3 * 1024,
    this.minFramerate = 5,
    this.maxFramerate = 15,
  }) : assert(minBitrateKbps > 0),
       assert(maxBitrateKbps >= minBitrateKbps),
       assert(minFramerate > 0),
       assert(maxFramerate >= minFramerate);

  final int minBitrateKbps;
  final int maxBitrateKbps;
  final int minFramerate;
  final int maxFramerate;

  RealtimeMediaAdaptationDecision decide(RealtimeMediaStats stats) {
    final dimensions = _boundedDimensions(stats.width, stats.height);
    final lossRatio = stats.packetsReceived > 0
        ? stats.packetsLost * 100 / stats.packetsReceived
        : stats.packetsLost > 0
        ? 100
        : 0;
    final congested =
        lossRatio >= 5 ||
        stats.jitterMs >= 80 ||
        stats.rttMs >= 250 ||
        stats.queueDepth >= 3;
    final recovering =
        !congested && (stats.framesRecovered > 0 || stats.keyframeRequests > 0);
    if (congested) {
      return RealtimeMediaAdaptationDecision(
        bitrateKbps: (maxBitrateKbps ~/ 2).clamp(
          minBitrateKbps,
          maxBitrateKbps,
        ),
        framerate: (maxFramerate ~/ 2).clamp(minFramerate, maxFramerate),
        width: dimensions.$1,
        height: dimensions.$2,
        reason: RealtimeMediaAdaptationReason.congestion,
      );
    }
    if (recovering) {
      return RealtimeMediaAdaptationDecision(
        bitrateKbps: (maxBitrateKbps * 3 ~/ 4).clamp(
          minBitrateKbps,
          maxBitrateKbps,
        ),
        framerate: (maxFramerate * 3 ~/ 4).clamp(minFramerate, maxFramerate),
        width: dimensions.$1,
        height: dimensions.$2,
        reason: RealtimeMediaAdaptationReason.recovery,
      );
    }
    return RealtimeMediaAdaptationDecision(
      bitrateKbps: maxBitrateKbps,
      framerate: maxFramerate,
      width: dimensions.$1,
      height: dimensions.$2,
      reason: RealtimeMediaAdaptationReason.steady,
    );
  }

  (int, int) _boundedDimensions(int width, int height) {
    if (width <= 0 || height <= 0) return (0, 0);
    final boundedWidth = width.clamp(1, 1920);
    final boundedHeight = height.clamp(1, 1080);
    return (boundedWidth, boundedHeight);
  }
}
