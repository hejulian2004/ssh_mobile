import 'realtime_media_adaptation.dart';
import 'realtime_media_endpoint.dart';
import 'realtime_media_error.dart';
import 'realtime_media_session.dart';

/// Optional native capability for keyframe recovery and bounded adaptation.
///
/// Implementations remain native owners. The Dart contract carries only a
/// bounded decision and endpoint identity, never media payloads.
abstract interface class RealtimeMediaRecoveryBackend {
  Future<void> requestKeyframe({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });

  Future<void> applyAdaptation({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required RealtimeMediaAdaptationDecision decision,
  });
}

/// Prevents a packet-loss burst from creating an unbounded keyframe request
/// storm. Native owners should apply the same limit at their recovery boundary.
final class RealtimeMediaKeyframeRequestLimiter {
  RealtimeMediaKeyframeRequestLimiter({
    this.minimumInterval = const Duration(seconds: 1),
  }) {
    if (minimumInterval <= Duration.zero) {
      throw ArgumentError.value(minimumInterval, 'minimumInterval');
    }
  }

  final Duration minimumInterval;
  DateTime? _lastRequest;

  bool allow([DateTime? now]) {
    final current = now ?? DateTime.now();
    final last = _lastRequest;
    if (last != null && current.difference(last) < minimumInterval) {
      return false;
    }
    _lastRequest = current;
    return true;
  }
}

extension RealtimeMediaSessionQos on RealtimeMediaSessionController {
  /// Requests one native keyframe, subject to the caller's limiter.
  Future<void> requestKeyframe({
    required RealtimeMediaEndpoint endpoint,
    RealtimeMediaKeyframeRequestLimiter? limiter,
  }) async {
    // The public stats path performs the controller ownership, generation and
    // terminal-state checks before an optional native recovery capability is
    // reached.  This keeps recovery requests fail-closed for stale leases.
    await stats(endpoint);
    if (limiter != null && !limiter.allow()) return;
    final recovery = backend;
    if (recovery is! RealtimeMediaRecoveryBackend) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native keyframe recovery is unavailable.',
      );
    }
    await (recovery as RealtimeMediaRecoveryBackend).requestKeyframe(
      endpointId: endpoint.id,
      identity: endpoint.identity,
    );
  }

  /// Reads one bounded snapshot, chooses a target, and lets the native owner
  /// apply it without changing queue capacity.
  Future<RealtimeMediaAdaptationDecision> adapt(
    RealtimeMediaEndpoint endpoint, {
    RealtimeMediaAdaptationPolicy policy =
        const RealtimeMediaAdaptationPolicy(),
  }) async {
    final decision = policy.decide(await stats(endpoint));
    final recovery = backend;
    if (recovery is! RealtimeMediaRecoveryBackend) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native media adaptation is unavailable.',
      );
    }
    await (recovery as RealtimeMediaRecoveryBackend).applyAdaptation(
      endpointId: endpoint.id,
      identity: endpoint.identity,
      decision: decision,
    );
    return decision;
  }
}
