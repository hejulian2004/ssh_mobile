part of 'realtime.dart';

final class _RealtimeSession implements RealtimeSession {
  _RealtimeSession({
    required this._client,
    required this.realtimeId,
    required this.peerId,
  });

  final RealtimeClientImpl _client;
  RealtimeSessionState _state = RealtimeSessionState.idle;
  RealtimeAudioState _audioState = RealtimeAudioState.unavailable;
  int _revision = 0;
  int? _generation;
  String? _sharedSessionInstanceId;
  bool _awaitingGenerationAdvance = false;
  Future<SdkResult<void>>? _startFuture;
  Future<SdkResult<void>>? _stopFuture;
  bool _stopCommandCompleted = false;
  bool _releaseRequested = false;
  bool _authoritativeTerminal = false;
  bool _disposed = false;
  final StreamController<RealtimeConsent> _consents =
      StreamController<RealtimeConsent>.broadcast();
  final StreamController<RealtimeSnapshot> _snapshots =
      StreamController<RealtimeSnapshot>.broadcast();
  RealtimeSnapshot? _currentSnapshot;

  @override
  final String realtimeId;

  @override
  final String peerId;

  @override
  RealtimeSessionState get state => _state;

  @override
  int get revision => _revision;

  @override
  int? get generation => _generation;

  @override
  String? get sharedSessionInstanceId => _sharedSessionInstanceId;

  @override
  RealtimeSessionToken? get mediaToken {
    final generation = _generation;
    if (generation == null || generation <= 0) return null;
    return RealtimeSessionToken(
      realtimeId: realtimeId,
      peerId: peerId,
      generation: generation,
    );
  }

  @override
  RealtimeAudioState get audioState => _audioState;

  @override
  RealtimeSnapshot? get currentSnapshot => _currentSnapshot;

  @override
  Stream<RealtimeSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<RealtimeConsent> get consentEvents => _consents.stream;

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) {
    _ensureUsable();
    return _client._sendConsent(this, consent);
  }

  @override
  Future<SdkResult<void>> start() {
    _ensureUsable();
    final existing = _startFuture;
    if (existing != null) return existing;
    if (_state == RealtimeSessionState.starting ||
        _state == RealtimeSessionState.negotiating ||
        _state == RealtimeSessionState.restarting ||
        _state == RealtimeSessionState.connected) {
      return Future<SdkResult<void>>.value(const SdkSuccess<void>(null));
    }
    // A fresh start() begins a new native connection generation whose
    // signaling revision restarts from a low value (native creates a new
    // WebRTC peer). Reset the recorded revision so the new generation's low
    // revisions are not mistaken for stale events from the previous session.
    _revision = 0;
    // The next native start creates a new cross-device session instance. Do
    // not let delayed consent from the previous instance remain admissible
    // while the new native state event is still in flight.
    _sharedSessionInstanceId = null;
    _awaitingGenerationAdvance = _generation != null;
    _stopCommandCompleted = false;
    _releaseRequested = false;
    _authoritativeTerminal = false;
    _state = RealtimeSessionState.starting;
    final future = _startInternal();
    _startFuture = future;
    future.then<void>(
      (_) {
        if (identical(_startFuture, future)) _startFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_startFuture, future)) _startFuture = null;
      },
    );
    return future;
  }

  Future<SdkResult<void>> _startInternal() async {
    final result = await _client._start(this);
    if (_disposed) return result;
    if (result is SdkFailure<void>) {
      _state = RealtimeSessionState.failed;
    }
    return result;
  }

  @override
  Future<SdkResult<void>> stop() {
    _ensureUsable();
    final existing = _stopFuture;
    if (existing != null) return existing;
    if (_state == RealtimeSessionState.idle ||
        _state == RealtimeSessionState.stopped) {
      return Future<SdkResult<void>>.value(const SdkSuccess<void>(null));
    }
    if (_stopCommandCompleted) {
      return Future<SdkResult<void>>.value(const SdkSuccess<void>(null));
    }
    final future = _stopInternal();
    _stopFuture = future;
    future.then<void>(
      (_) {
        if (identical(_stopFuture, future)) _stopFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_stopFuture, future)) _stopFuture = null;
      },
    );
    return future;
  }

  Future<SdkResult<void>> _stopInternal() async {
    final result = await _client._stop(this);
    if (_disposed) return result;
    if (result is SdkFailure<void>) {
      _state = RealtimeSessionState.failed;
    } else {
      // The command result only confirms native command completion. The
      // authoritative stopped state arrives through the closed state event.
      _stopCommandCompleted = true;
    }
    return result;
  }

  /// Requests release without pretending that a command result is a terminal
  /// native lifecycle event. The registry entry remains present until the
  /// authoritative stopped/failed event is folded by [_applyState].
  Future<void> _requestRelease() async {
    if (_disposed) return;
    _releaseRequested = true;
    if (_authoritativeTerminal) {
      await _finalizeRelease();
      return;
    }
    // Release is intentionally bounded by the caller's lifecycle. The stop
    // command may be in flight or may never produce a terminal event; the
    // registry is finalized only by the authoritative native event below.
    unawaited(_issueReleaseStop());
  }

  Future<void> _issueReleaseStop() async {
    try {
      await stop();
    } catch (_) {
      // The release remains pending. Runtime/client disposal is the final
      // force-cleanup owner when native cannot produce a terminal event.
    }
    if (_authoritativeTerminal) await _finalizeRelease();
  }

  bool _applyState(
    RealtimeSessionState state,
    NetworkError? error, {
    int revision = 0,
    int? generation,
    String? sharedSessionInstanceId,
  }) {
    if (_disposed) return false;
    if (generation != null) {
      if (generation <= 0) return false;
      final currentGeneration = _generation;
      if (_awaitingGenerationAdvance &&
          currentGeneration != null &&
          generation <= currentGeneration) {
        return false;
      }
      if (currentGeneration != null && generation < currentGeneration) {
        return false;
      }
      if (currentGeneration == null || generation > currentGeneration) {
        _generation = generation;
        _revision = 0;
        _awaitingGenerationAdvance = false;
      }
    }
    // Revision reconciliation (ADR-029): a strictly lower revision is a stale
    // snapshot/event and must not roll back a newer state — including a stale
    // `failed`/error event. Equal revisions are idempotent reapplications and
    // never advance the revision. revision == 0 is the legacy/unspecified
    // marker: it always applies its state but never advances `_revision`.
    if (revision > 0 && _revision > 0 && revision < _revision) return false;
    if (sharedSessionInstanceId != null &&
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(sharedSessionInstanceId)) {
      return false;
    }
    _state = error == null ? state : RealtimeSessionState.failed;
    if (state == RealtimeSessionState.stopped ||
        state == RealtimeSessionState.failed ||
        error != null) {
      _authoritativeTerminal = true;
    }
    if (revision > _revision) _revision = revision;
    if (sharedSessionInstanceId != null) {
      _sharedSessionInstanceId = sharedSessionInstanceId;
    }
    if (_state == RealtimeSessionState.stopped ||
        _state == RealtimeSessionState.failed) {
      _stopCommandCompleted = false;
      _sharedSessionInstanceId = null;
    }
    final snapshot = RealtimeSnapshot(
      realtimeId: realtimeId,
      peerId: peerId,
      state: _state,
      revision: _revision,
      error: error,
      generation: _generation,
      sharedSessionInstanceId: _sharedSessionInstanceId,
    );
    _currentSnapshot = snapshot;
    _snapshots.add(snapshot);
    if (_releaseRequested && _authoritativeTerminal) {
      unawaited(_finalizeRelease());
    }
    return true;
  }

  void _applySnapshot(RealtimeSnapshot snapshot) {
    if (_disposed) return;
    _applyState(
      snapshot.state,
      snapshot.error,
      revision: snapshot.revision,
      generation: snapshot.generation,
      sharedSessionInstanceId: snapshot.sharedSessionInstanceId,
    );
  }

  void _applyAudioState(RealtimeAudioState state) {
    if (_disposed) return;
    _audioState = state;
  }

  void _applyConsent(RealtimeConsent consent) {
    if (_disposed || !consent.isFresh(DateTime.now())) return;
    if (consent.realtimeId != realtimeId) return;
    if (consent.sharedSessionInstanceId != _sharedSessionInstanceId) return;
    _consents.add(consent);
  }

  Future<void> _dispose({bool force = false}) async {
    if (_disposed) return;
    if (!force && !_authoritativeTerminal) {
      _releaseRequested = true;
      return;
    }
    final shouldStop =
        _state != RealtimeSessionState.idle &&
        _state != RealtimeSessionState.stopped;
    _disposed = true;
    _client._remove(this);
    if (shouldStop) {
      // Disposal must not wait for a command-result timeout. The backend is
      // disposed immediately after all sessions have requested their stop;
      // that cancellation completes any in-flight command futures.
      final stopFuture = _client._stop(this, allowDisposed: true);
      unawaited(
        stopFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    _state = RealtimeSessionState.stopped;
    await _consents.close();
    await _snapshots.close();
  }

  Future<void> _finalizeRelease() => _dispose(force: true);

  void _ensureUsable() {
    if (_disposed) throw const SdkClientDisposedException();
  }
}
