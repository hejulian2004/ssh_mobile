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

  Future<void> _dispose() async {
    if (_disposed) return;
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

  void _ensureUsable() {
    if (_disposed) throw const SdkClientDisposedException();
  }
}
