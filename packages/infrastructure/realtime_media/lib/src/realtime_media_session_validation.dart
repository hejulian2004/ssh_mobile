part of 'realtime_media_session.dart';

extension RealtimeMediaSessionValidation on RealtimeMediaSessionController {
  /// Obtains low-frequency counters without exposing media payloads.
  Future<RealtimeMediaStats> stats(RealtimeMediaEndpoint endpoint) async {
    _ensureEndpoint(endpoint);
    try {
      return await backend.readStats(
        endpointId: endpoint.id,
        identity: endpoint.identity,
      );
    } catch (_) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint statistics are unavailable.',
      );
    }
  }

  RealtimeMediaEndpointIdentity _identity(RealtimeMediaDirection direction) =>
      RealtimeMediaEndpointIdentity(
        realtimeId: realtimeId,
        peerId: peerId,
        generation: generation,
        direction: direction,
      );

  void _ensureSessionCanStart() {
    if (_terminalRelease != null ||
        state == RealtimeMediaSessionState.stopping ||
        state == RealtimeMediaSessionState.released) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.sessionReleased,
        'The media session controller is stopping or has been released.',
      );
    }
    if (state == RealtimeMediaSessionState.failed) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.failedState,
        'The media session controller is failed.',
      );
    }
  }

  void _ensureEndpoint(
    RealtimeMediaEndpoint endpoint, {
    RealtimeMediaDirection? expectedDirection,
  }) {
    if (endpoint.state == RealtimeMediaEndpointState.released) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.useAfterRelease,
        'The endpoint lease has been released.',
      );
    }
    if (_terminalRelease != null ||
        state == RealtimeMediaSessionState.stopping ||
        state == RealtimeMediaSessionState.released) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.sessionReleased,
        'The media session controller is stopping or has been released.',
      );
    }
    _ensureEndpointIdentity(endpoint);
    if (endpoint.state == RealtimeMediaEndpointState.failed ||
        state == RealtimeMediaSessionState.failed) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.failedState,
        'The endpoint or its session is failed.',
      );
    }
    if (expectedDirection != null &&
        endpoint.identity.direction != expectedDirection) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.invalidDirection,
        'The endpoint direction does not permit this attachment.',
      );
    }
  }

  void _ensureEndpointIdentity(RealtimeMediaEndpoint endpoint) {
    final current = _endpoints[endpoint.id];
    if (!identical(current, endpoint) ||
        endpoint.identity.realtimeId != realtimeId ||
        endpoint.identity.peerId != peerId ||
        endpoint.identity.generation != generation) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.staleEndpoint,
        'The endpoint belongs to another realtime generation.',
      );
    }
  }

  void _markFailed(RealtimeMediaEndpoint endpoint) {
    endpoint.state = RealtimeMediaEndpointState.failed;
    state = RealtimeMediaSessionState.failed;
  }

  bool _isLiveEndpoint(RealtimeMediaEndpoint endpoint) =>
      identical(_endpoints[endpoint.id], endpoint) &&
      endpoint.state != RealtimeMediaEndpointState.released &&
      _terminalRelease == null &&
      state != RealtimeMediaSessionState.stopping &&
      state != RealtimeMediaSessionState.released;

  bool _canCommitAttachment(RealtimeMediaEndpoint endpoint) =>
      _isLiveEndpoint(endpoint) && !endpoint.isAttached;

  RealtimeMediaException _attachmentCommitFailure(
    RealtimeMediaEndpoint endpoint,
  ) {
    if (_terminalRelease != null ||
        state == RealtimeMediaSessionState.stopping ||
        state == RealtimeMediaSessionState.released) {
      return const RealtimeMediaException(
        RealtimeMediaErrorCode.sessionReleased,
        'The media session controller is stopping or has been released.',
      );
    }
    if (endpoint.state == RealtimeMediaEndpointState.released ||
        !identical(_endpoints[endpoint.id], endpoint)) {
      return const RealtimeMediaException(
        RealtimeMediaErrorCode.useAfterRelease,
        'The endpoint lease has been released.',
      );
    }
    if (endpoint.isAttached) {
      return const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one attached source or surface.',
      );
    }
    if (endpoint.state == RealtimeMediaEndpointState.failed ||
        state == RealtimeMediaSessionState.failed) {
      return const RealtimeMediaException(
        RealtimeMediaErrorCode.failedState,
        'The endpoint or its session is failed.',
      );
    }
    return const RealtimeMediaException(
      RealtimeMediaErrorCode.staleEndpoint,
      'The endpoint belongs to another realtime generation.',
    );
  }
}
