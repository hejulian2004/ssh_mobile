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
        state != RealtimeMediaSessionState.released) {
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
    try {
      await _waitForPendingStarts();
      firstFailure = _lateStartCleanupFailure;
      for (final lease in _endpoints.values.toList()) {
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
    } finally {
      state = RealtimeMediaSessionState.released;
    }
    if (firstFailure != null) {
      completion.completeError(firstFailure);
    } else {
      completion.complete();
    }
  }

  /// Stops this session and releases every endpoint lease it owns.
  ///
  /// Stopping is terminal for this controller's immutable realtime generation.
  /// It is deliberately an idempotent lifecycle alias for a controller-level
  /// [release], while [release] with an endpoint retains the narrower lease
  /// cleanup operation.
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
    try {
      if (endpoint.isAttached) {
        try {
          await backend.detach(
            endpointId: endpoint.id,
            identity: endpoint.identity,
          );
        } on RealtimeMediaException catch (error) {
          failure = error;
        } catch (_) {
          failure = const RealtimeMediaException(
            RealtimeMediaErrorCode.backendFailure,
            'Native endpoint detach failed.',
          );
        }
      }
    } catch (_) {
      failure ??= const RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint cleanup failed.',
      );
    } finally {
      try {
        await backend.release(
          endpointId: endpoint.id,
          identity: endpoint.identity,
        );
      } on RealtimeMediaException catch (error) {
        failure ??= error;
      } catch (_) {
        failure ??= const RealtimeMediaException(
          RealtimeMediaErrorCode.backendFailure,
          'Native endpoint release failed.',
        );
      }
      endpoint.source = null;
      endpoint.surface?.release();
      endpoint.state = RealtimeMediaEndpointState.released;
      _endpoints.remove(endpoint.id);
      _endpointReleases.remove(endpoint.id);
    }
    if (failure != null) {
      completion.completeError(failure);
    } else {
      completion.complete();
    }
  }

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

  Future<void> _releaseEndpointAcquiredDuringStop(
    RealtimeMediaEndpointId endpointId,
    RealtimeMediaEndpointIdentity identity,
  ) async {
    try {
      await backend.release(endpointId: endpointId, identity: identity);
    } on RealtimeMediaException catch (error) {
      if (_terminalRelease != null) {
        _lateStartCleanupFailure ??= error;
      }
      rethrow;
    } catch (_) {
      const failure = RealtimeMediaException(
        RealtimeMediaErrorCode.backendFailure,
        'Native endpoint cleanup after a stopped start failed.',
      );
      if (_terminalRelease != null) {
        _lateStartCleanupFailure ??= failure;
      }
      throw failure;
    }
  }
}
