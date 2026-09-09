import 'dart:async';

import 'realtime_media_adaptation.dart';
import 'realtime_media_endpoint.dart';
import 'realtime_media_error.dart';
import 'realtime_media_state.dart';
import 'realtime_media_stats.dart';
import 'remote_video_surface.dart';
import 'screen_capture_source.dart';

part 'realtime_media_session_attachments.dart';
part 'realtime_media_session_release.dart';
part 'realtime_media_session_validation.dart';

/// Narrow platform bridge. Implementations own native media resources.
abstract interface class RealtimeMediaBackend {
  Future<RealtimeMediaEndpointId> start(RealtimeMediaEndpointIdentity identity);

  Future<void> attachCaptureSource({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    required ScreenCaptureSource source,
  });

  Future<RemoteVideoSurface> attachRemoteVideoSurface({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });

  Future<void> detach({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });

  Future<void> release({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });

  /// Reads a low-frequency, payload-free snapshot for one active endpoint.
  ///
  /// Statistics are observational: an unavailable snapshot does not change a
  /// capture or renderer lifecycle that may still be healthy.
  Future<RealtimeMediaStats> readStats({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });
}

/// Owns endpoint leases for one `(realtimeId, peerId, generation)` binding.
final class RealtimeMediaSessionController {
  RealtimeMediaSessionController({
    required this.backend,
    required String realtimeId,
    required String peerId,
    required this.generation,
  }) : realtimeId = _validateRealtimeId(realtimeId),
       peerId = _validatePeerId(peerId) {
    if (generation <= 0) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
  }

  final RealtimeMediaBackend backend;
  final String realtimeId;
  final String peerId;
  final int generation;
  final Map<RealtimeMediaEndpointId, RealtimeMediaEndpoint> _endpoints =
      <RealtimeMediaEndpointId, RealtimeMediaEndpoint>{};
  final Map<RealtimeMediaEndpointId, Future<void>> _endpointReleases =
      <RealtimeMediaEndpointId, Future<void>>{};
  final Set<RealtimeMediaEndpointId> _pendingAttachments =
      <RealtimeMediaEndpointId>{};
  final Map<RealtimeMediaEndpointId, RealtimeMediaAdaptationController>
  _adaptationControllers =
      <RealtimeMediaEndpointId, RealtimeMediaAdaptationController>{};

  /// Returns the stateful QoS controller owned by one endpoint lease.
  ///
  /// The controller stores only bounded counters/timestamps. It is kept on
  /// the session so repeated stats polls use interval deltas instead of
  /// restarting a cumulative-loss policy on every call.
  RealtimeMediaAdaptationController adaptationControllerForEndpoint(
    RealtimeMediaEndpointId endpointId, {
    RealtimeMediaAdaptationPolicy? policy,
  }) => _adaptationControllers[endpointId] ??=
      RealtimeMediaAdaptationController(policy: policy);

  /// Drops QoS state once the native endpoint lease is finalized.
  void discardAdaptationController(RealtimeMediaEndpointId endpointId) {
    _adaptationControllers.remove(endpointId);
  }

  Future<void>? _terminalRelease;
  Completer<void>? _pendingStartsSettled;
  int _pendingStartCount = 0;
  RealtimeMediaException? _lateStartCleanupFailure;

  RealtimeMediaSessionState state = RealtimeMediaSessionState.idle;

  /// Acquires one native endpoint lease for the supplied direction.
  Future<RealtimeMediaEndpoint> start(RealtimeMediaDirection direction) async {
    _ensureSessionCanStart();
    state = RealtimeMediaSessionState.starting;
    _beginStart();
    final identity = _identity(direction);
    try {
      final endpointId = await backend.start(identity);
      if (_endpoints.containsKey(endpointId)) {
        state = RealtimeMediaSessionState.failed;
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.backendFailure,
          'Native bridge returned a duplicate endpoint ID.',
        );
      }
      // From the moment native returns an ID, this controller must own a
      // record for the lease, even when stop/release already won the race.
      final endpoint = RealtimeMediaEndpoint.lease(
        id: endpointId,
        identity: identity,
      );
      _endpoints[endpointId] = endpoint;
      if (_terminalRelease != null ||
          state == RealtimeMediaSessionState.stopping ||
          state == RealtimeMediaSessionState.released) {
        await _releaseAcquiredEndpoint(endpoint);
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.sessionReleased,
          'The media session controller is stopping or has been released.',
        );
      }
      if (state == RealtimeMediaSessionState.failed) {
        await _releaseAcquiredEndpoint(endpoint);
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.failedState,
          'The media session controller is failed.',
        );
      }
      return endpoint;
    } on RealtimeMediaException {
      if (_terminalRelease == null &&
          state != RealtimeMediaSessionState.stopping &&
          state != RealtimeMediaSessionState.released) {
        state = RealtimeMediaSessionState.failed;
      }
      rethrow;
    } catch (_) {
      if (_terminalRelease == null) {
        state = RealtimeMediaSessionState.failed;
      }
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint acquisition failed.',
      );
    } finally {
      _finishStart();
    }
  }
}

String _validateRealtimeId(String value) => _validate(value, 'realtime ID');

String _validatePeerId(String value) => _validate(value, 'peer ID');

String _validate(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw ArgumentError.value(value, name, 'must contain 1 to 128 characters');
  }
  return normalized;
}
