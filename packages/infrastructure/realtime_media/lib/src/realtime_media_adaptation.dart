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

/// Stateful, bounded adaptation controller for a low-frequency stats poll.
///
/// The stateless [RealtimeMediaAdaptationPolicy] is useful when a caller only
/// needs one recommendation. Platform owners should use this controller when
/// polling over time: congestion must be sustained for three seconds before a
/// degradation step, and healthy conditions must be sustained for ten seconds
/// before recovering one step. The controller stores only bounded targets and
/// timestamps; it never queues media or retains a frame payload.
final class RealtimeMediaAdaptationController {
  RealtimeMediaAdaptationController({
    this.policy = const RealtimeMediaAdaptationPolicy(),
    this.congestionHold = const Duration(seconds: 3),
    this.recoveryHold = const Duration(seconds: 10),
  }) {
    if (congestionHold <= Duration.zero) {
      throw ArgumentError.value(congestionHold, 'congestionHold');
    }
    if (recoveryHold <= Duration.zero) {
      throw ArgumentError.value(recoveryHold, 'recoveryHold');
    }
  }

  final RealtimeMediaAdaptationPolicy policy;
  final Duration congestionHold;
  final Duration recoveryHold;

  DateTime? _congestionSince;
  DateTime? _healthySince;
  DateTime? _lastCongestionStep;
  DateTime? _lastNow;
  int _level = 0;
  int _bitrateKbps = 0;
  int _nominalWidth = 0;
  int _nominalHeight = 0;

  /// Chooses one bounded target from a low-frequency snapshot.
  ///
  /// [now] is injectable for deterministic tests and host-clock monotonicity
  /// is enforced by clamping backwards timestamps to the previous sample.
  RealtimeMediaAdaptationDecision decide(
    RealtimeMediaStats stats, {
    DateTime? now,
  }) {
    final current = _monotonicNow(now ?? DateTime.now());
    final nominal = policy.decide(
      RealtimeMediaStats(width: stats.width, height: stats.height),
    );
    if (nominal.width > 0 && (_level == 0 || _nominalWidth == 0)) {
      _nominalWidth = nominal.width;
      _nominalHeight = nominal.height;
    }
    if (_bitrateKbps == 0) {
      _bitrateKbps = policy.maxBitrateKbps;
    }

    final lossRatio = stats.packetsReceived > 0
        ? stats.packetsLost * 100 / stats.packetsReceived
        : stats.packetsLost > 0
        ? 100
        : 0;
    final queuePressure =
        stats.queueCapacity > 0 && stats.queueDepth >= stats.queueCapacity;
    final congested =
        lossRatio >= 5 ||
        stats.jitterMs >= 80 ||
        stats.rttMs >= 250 ||
        queuePressure;
    final severe = lossRatio >= 10 || stats.rttMs >= 400;
    final healthy =
        lossRatio < 2 &&
        stats.jitterMs < 80 &&
        stats.rttMs < 150 &&
        stats.queueCapacity > 0 &&
        stats.queueDepth < stats.queueCapacity;

    if (congested) {
      _healthySince = null;
      _congestionSince ??= current;
      final heldLongEnough =
          current.difference(_congestionSince!) >= congestionHold;
      final canStep =
          _lastCongestionStep == null ||
          current.difference(_lastCongestionStep!) >= congestionHold;
      if (heldLongEnough && canStep) {
        if (severe) {
          _level = 2;
        } else if (_level < 2) {
          _level += 1;
        }
        _bitrateKbps = _degradeBitrate(_bitrateKbps);
        _lastCongestionStep = current;
        return _decision(
          reason: RealtimeMediaAdaptationReason.congestion,
          stats: stats,
        );
      }
      return _decision(
        reason: RealtimeMediaAdaptationReason.congestion,
        stats: stats,
      );
    }

    _congestionSince = null;
    _lastCongestionStep = null;
    if (healthy) {
      _healthySince ??= current;
      if (current.difference(_healthySince!) >= recoveryHold && _level > 0) {
        _level -= 1;
        _bitrateKbps = _recoverBitrate(_bitrateKbps);
        _healthySince = current;
        return _decision(
          reason: RealtimeMediaAdaptationReason.recovery,
          stats: stats,
        );
      }
    } else {
      _healthySince = null;
    }
    return _decision(
      reason: _level == 0
          ? RealtimeMediaAdaptationReason.steady
          : RealtimeMediaAdaptationReason.recovery,
      stats: stats,
    );
  }

  DateTime _monotonicNow(DateTime value) {
    final previous = _lastNow;
    final current = previous != null && value.isBefore(previous)
        ? previous
        : value;
    _lastNow = current;
    return current;
  }

  int _degradeBitrate(int current) =>
      (current * 3 ~/ 4).clamp(policy.minBitrateKbps, policy.maxBitrateKbps);

  int _recoverBitrate(int current) =>
      (current * 4 ~/ 3).clamp(policy.minBitrateKbps, policy.maxBitrateKbps);

  RealtimeMediaAdaptationDecision _decision({
    required RealtimeMediaAdaptationReason reason,
    required RealtimeMediaStats stats,
  }) {
    final dimensions = switch (_level) {
      2 => (
        _nominalWidth == 0 ? 1280 : _nominalWidth.clamp(1, 1280),
        _nominalHeight == 0 ? 720 : _nominalHeight.clamp(1, 720),
      ),
      _ => (
        _nominalWidth == 0
            ? (stats.width <= 0 ? 0 : stats.width.clamp(1, 1920))
            : _nominalWidth,
        _nominalHeight == 0
            ? (stats.height <= 0 ? 0 : stats.height.clamp(1, 1080))
            : _nominalHeight,
      ),
    };
    final framerate = _level == 0
        ? policy.maxFramerate
        : (policy.maxFramerate * 2 ~/ 3).clamp(
            policy.minFramerate,
            policy.maxFramerate,
          );
    return RealtimeMediaAdaptationDecision(
      bitrateKbps: _bitrateKbps,
      framerate: framerate,
      width: dimensions.$1,
      height: dimensions.$2,
      reason: reason,
    );
  }
}
