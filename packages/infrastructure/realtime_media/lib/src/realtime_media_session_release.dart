part of 'realtime_media_session.dart';

extension RealtimeMediaSessionRelease on RealtimeMediaSessionController {
  /// Releases an endpoint lease; repeating a completed release is safe.
  Future<void> release([RealtimeMediaEndpoint? endpoint]) {
    if (endpoint != null) return _releaseSingleEndpoint(endpoint);
    return _releaseController();
  }

  Future<void> _releaseSingleEndpoint(RealtimeMediaEndpoint endpoint) async {
    if (endpoint.state == RealtimeMediaEndpointState.released) return;
    final terminalRelease = _terminalRelease;
    if (terminalRelease != null) {
      await terminalRelease;
      return;
    }
    _ensureEndpointIdentity(endpoint);
    await _releaseEndpoint(endpoint);
    if (_terminalRelease == null &&
        state != RealtimeMediaSessionState.released &&
        (state != RealtimeMediaSessionState.failed || _endpoints.isEmpty)) {
      state = RealtimeMediaSessionState.ready;
    }
  }

  Future<void> _releaseController() {
    final terminalRelease = _terminalRelease;
    if (terminalRelease != null) return terminalRelease;
    if (state == RealtimeMediaSessionState.released) {
      return Future<void>.value();
    }

    final completion = Completer<void>();
    _terminalRelease = completion.future;
    state = RealtimeMediaSessionState.stopping;
    unawaited(_releaseAllEndpoints(completion));
    return completion.future;
  }

  Future<void> _releaseAllEndpoints(Completer<void> completion) async {
    RealtimeMediaException? firstFailure;
    final endpointsToRelease = _endpoints.values.toList();
    try {
      await _waitForPendingStarts();
      firstFailure = _lateStartCleanupFailure;
      _lateStartCleanupFailure = null;
      for (final lease in endpointsToRelease) {
        try {
          await _releaseEndpoint(lease);
        } on RealtimeMediaException catch (error) {
          firstFailure ??= error;
        }
      }
    } catch (_) {
      firstFailure ??= const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint cleanup failed.',
      );
    }
    // A retryable native release leaves its endpoint in [_endpoints]. Keep
    // the controller failed (and the release entry point open) until a later
    // stop/release call can retry that lease. A detach error alone does not
    // block finalization when the subsequent native release succeeded.
    final hasRetainedLeases = _endpoints.isNotEmpty;
    if (hasRetainedLeases) {
      state = RealtimeMediaSessionState.failed;
    } else {
      state = RealtimeMediaSessionState.released;
    }
    _terminalRelease = null;
    if (firstFailure != null) {
      completion.completeError(firstFailure);
    } else {
      completion.complete();
    }
  }

  Future<void> _releaseAcquiredEndpoint(RealtimeMediaEndpoint endpoint) async {
    try {
      await _releaseEndpoint(endpoint);
    } on RealtimeMediaException catch (error) {
      // The endpoint is already in [_endpoints], so a retryable failure can
      // be reclaimed by the next controller-level stop/release attempt.
      if (_terminalRelease != null) {
        _lateStartCleanupFailure ??= error;
      }
      rethrow;
    }
  }

  /// Stops this session and releases every endpoint lease it owns.
  ///
  /// Successful stopping is terminal for this controller's immutable
  /// realtime generation. A retryable cleanup failure leaves the controller
  /// failed so a later call can retry the retained leases. It is deliberately
  /// an idempotent lifecycle alias for a controller-level [release], while
  /// [release] with an endpoint retains the narrower lease cleanup operation.
  Future<void> stop() => release();

  /// Disposes this controller without taking ownership of its NetworkRuntime.
  ///
  /// This is safe before [start] and is idempotent after [stop].
  Future<void> dispose() => stop();

  Future<void> _releaseEndpoint(RealtimeMediaEndpoint endpoint) {
    if (endpoint.state == RealtimeMediaEndpointState.released) {
      return Future<void>.value();
    }
    final existingRelease = _endpointReleases[endpoint.id];
    if (existingRelease != null) return existingRelease;

    final completion = Completer<void>();
    final operation = completion.future;
    _endpointReleases[endpoint.id] = operation;
    unawaited(_releaseEndpointLease(endpoint, completion));
    return operation;
  }

  Future<void> _releaseEndpointLease(
    RealtimeMediaEndpoint endpoint,
    Completer<void> completion,
  ) async {
    RealtimeMediaException? failure;
    RemoteVideoSurface? detachedSurface;
    var nativeLeaseFinalized = !endpoint.isAttached;
    if (endpoint.isAttached) {
      try {
        await backend.detach(
          endpointId: endpoint.id,
          identity: endpoint.identity,
        );
        detachedSurface = endpoint.surface;
        endpoint.source = null;
        endpoint.surface = null;
        endpoint.state = RealtimeMediaEndpointState.detached;
      } on RealtimeMediaException catch (error) {
        failure = error;
      } catch (_) {
        failure = const RealtimeMediaException(
          RealtimeMediaErrorCode.backendFailure,
          'Native endpoint detach failed.',
        );
      }
    }
    try {
      await backend.release(
        endpointId: endpoint.id,
        identity: endpoint.identity,
      );
      nativeLeaseFinalized = true;
    } on RealtimeMediaException catch (error) {
      failure ??= error;
      nativeLeaseFinalized = _releaseFinalizesLease(error);
    } catch (_) {
      failure ??= const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint release failed.',
      );
      nativeLeaseFinalized = false;
    }

    if (nativeLeaseFinalized) {
      endpoint.source = null;
      // Keep the released capability observable to callers, matching the
      // endpoint contract, while not treating it as attached on a retry.
      endpoint.surface ??= detachedSurface;
      endpoint.surface?.release();
      endpoint.state = RealtimeMediaEndpointState.released;
      _endpoints.remove(endpoint.id);
      discardAdaptationController(endpoint.id);
    } else {
      // The native lease is still owned by this controller. Retain its ID and
      // mark the endpoint failed so a later release call can retry cleanup.
      endpoint.state = RealtimeMediaEndpointState.failed;
      state = RealtimeMediaSessionState.failed;
    }
    _endpointReleases.remove(endpoint.id);
    if (failure != null) {
      completion.completeError(failure);
    } else {
      completion.complete();
    }
  }

  bool _releaseFinalizesLease(RealtimeMediaException error) =>
      error.code == RealtimeMediaErrorCode.staleEndpoint ||
      error.code == RealtimeMediaErrorCode.sessionReleased;

  void _beginStart() {
    if (_pendingStartCount == 0) {
      _pendingStartsSettled = Completer<void>();
    }
    _pendingStartCount += 1;
  }

  void _finishStart() {
    _pendingStartCount -= 1;
    if (_pendingStartCount != 0) return;

    _pendingStartsSettled!.complete();
    if (_terminalRelease == null &&
        state == RealtimeMediaSessionState.starting) {
      state = RealtimeMediaSessionState.ready;
    }
  }

  Future<void> _waitForPendingStarts() async {
    while (_pendingStartCount > 0) {
      await _pendingStartsSettled!.future;
    }
  }
}
