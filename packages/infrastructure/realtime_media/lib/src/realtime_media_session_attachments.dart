part of 'realtime_media_session.dart';

extension RealtimeMediaSessionAttachments on RealtimeMediaSessionController {
  /// Associates a send endpoint with an opaque platform source descriptor.
  Future<void> attachCaptureSource(
    RealtimeMediaEndpoint endpoint,
    ScreenCaptureSource source,
  ) async {
    _ensureEndpoint(endpoint, expectedDirection: RealtimeMediaDirection.send);
    if (endpoint.isAttached) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one attached source or surface.',
      );
    }
    if (!_pendingAttachments.add(endpoint.id)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one pending source or surface attachment.',
      );
    }
    try {
      await backend.attachCaptureSource(
        endpointId: endpoint.id,
        identity: endpoint.identity,
        source: source,
      );
      if (!_canCommitAttachment(endpoint)) {
        await _cleanupLateAttachment(
          endpointId: endpoint.id,
          identity: endpoint.identity,
          releaseEndpoint: !_isLiveEndpoint(endpoint),
        );
        throw _attachmentCommitFailure(endpoint);
      }
      endpoint.source = source;
      endpoint.state = RealtimeMediaEndpointState.attached;
    } on RealtimeMediaException {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      rethrow;
    } catch (_) {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native source attachment failed.',
      );
    } finally {
      _pendingAttachments.remove(endpoint.id);
    }
  }

  /// Associates a receive endpoint with an opaque renderer capability.
  Future<RemoteVideoSurface> attachRemoteVideoSurface(
    RealtimeMediaEndpoint endpoint,
  ) async {
    _ensureEndpoint(
      endpoint,
      expectedDirection: RealtimeMediaDirection.receive,
    );
    if (endpoint.isAttached) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one attached source or surface.',
      );
    }
    if (!_pendingAttachments.add(endpoint.id)) {
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.duplicateAttach,
        'An endpoint can have one pending source or surface attachment.',
      );
    }
    RemoteVideoSurface? surface;
    try {
      surface = await backend.attachRemoteVideoSurface(
        endpointId: endpoint.id,
        identity: endpoint.identity,
      );
      if (!_canCommitAttachment(endpoint) ||
          surface.endpointId != endpoint.id ||
          !surface.identity.matches(endpoint.identity)) {
        await _cleanupLateAttachment(
          endpointId: endpoint.id,
          identity: endpoint.identity,
          surface: surface,
          releaseEndpoint: !_isLiveEndpoint(endpoint),
        );
        if (!_canCommitAttachment(endpoint)) {
          throw _attachmentCommitFailure(endpoint);
        }
        // A malformed native capability may already have allocated a
        // renderer. Best-effort detach it before failing closed; the returned
        // opaque capability is also marked released so it cannot be reused by
        // a caller that retained the bad result.
        _markFailed(endpoint);
        throw const RealtimeMediaException(
          RealtimeMediaErrorCode.backendFailure,
          'Native bridge returned a surface for another endpoint generation.',
        );
      }
      endpoint.surface = surface;
      endpoint.state = RealtimeMediaEndpointState.attached;
      return surface;
    } on RealtimeMediaException {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      rethrow;
    } catch (_) {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native surface attachment failed.',
      );
    } finally {
      _pendingAttachments.remove(endpoint.id);
    }
  }

  /// Detaches a currently attached source or surface without ending the lease.
  Future<void> detach(RealtimeMediaEndpoint endpoint) async {
    _ensureEndpoint(endpoint);
    if (!endpoint.isAttached) return;
    try {
      await backend.detach(
        endpointId: endpoint.id,
        identity: endpoint.identity,
      );
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      endpoint.source = null;
      endpoint.surface?.release();
      endpoint.surface = null;
      endpoint.state = RealtimeMediaEndpointState.detached;
    } on RealtimeMediaException {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      rethrow;
    } catch (_) {
      if (!_isLiveEndpoint(endpoint)) {
        throw _attachmentCommitFailure(endpoint);
      }
      _markFailed(endpoint);
      throw const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint detach failed.',
      );
    }
  }

  Future<void> _cleanupLateAttachment({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
    RemoteVideoSurface? surface,
    required bool releaseEndpoint,
  }) async {
    try {
      await backend.detach(endpointId: endpointId, identity: identity);
    } catch (_) {
      // Keep the lifecycle error deterministic; controller release retries the
      // endpoint-level cleanup when the lease is still owned.
    }
    surface?.release();
    if (!releaseEndpoint) return;
    try {
      await backend.release(endpointId: endpointId, identity: identity);
    } catch (_) {
      // The terminal release caller owns the primary cleanup result.
    }
  }
}
