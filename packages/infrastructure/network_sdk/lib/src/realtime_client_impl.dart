part of 'realtime.dart';

/// SDK coordinator that maps one backend event stream to many sessions.
final class RealtimeClientImpl implements RealtimeClient {
  RealtimeClientImpl({required RealtimeSessionBackend backend})
    : _backend = backend {
    _backendSubscription = backend.events.listen(_onBackendEvent);
  }

  final RealtimeSessionBackend _backend;
  final Map<String, _RealtimeSession> _sessions = <String, _RealtimeSession>{};
  final StreamController<RealtimeIncomingSessionOffer> _incomingOffers =
      StreamController<RealtimeIncomingSessionOffer>.broadcast();
  late final StreamSubscription<RealtimeBackendEvent> _backendSubscription;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  Stream<RealtimeIncomingSessionOffer> get incomingOffers =>
      _incomingOffers.stream;

  @override
  RealtimeSession createSession({
    required String realtimeId,
    required String peerId,
  }) {
    _ensureUsable();
    _validateRealtimeId(realtimeId);
    if (peerId.trim().isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'Peer ID must not be empty.');
    }
    if (_sessions.containsKey(realtimeId)) {
      throw StateError('Realtime session already exists: $realtimeId');
    }
    final session = _RealtimeSession(
      client: this,
      realtimeId: realtimeId,
      peerId: peerId,
    );
    _sessions[realtimeId] = session;
    return session;
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    if (_disposed) return Future<void>.value();
    _disposed = true;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  @override
  Future<void> releaseSession(RealtimeSession session) async {
    _ensureUsable();
    if (session is! _RealtimeSession || !identical(session._client, this)) {
      return;
    }
    await session._requestRelease();
  }

  @override
  Future<SdkResult<RealtimeSession>> claimIncomingSession(
    RealtimeIncomingSessionOffer offer,
  ) async {
    _ensureUsable();
    final backend = _backend;
    if (backend is! RealtimeIncomingSessionBackend) {
      return SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Incoming Realtime offers are unavailable on this backend.',
          operation: NetworkOperation.connect,
          peerId: offer.authenticatedPeerId,
        ),
      );
    }
    final incomingBackend = backend as RealtimeIncomingSessionBackend;
    if (_sessions.containsKey(offer.realtimeId)) {
      return SdkFailure(
        NetworkError(
          code: NetworkErrorCode.staleOperation,
          message: 'Realtime session already exists for this offer.',
          operation: NetworkOperation.connect,
          peerId: offer.authenticatedPeerId,
        ),
      );
    }
    final session = createSession(
      realtimeId: offer.realtimeId,
      peerId: offer.authenticatedPeerId,
    );
    final result = await incomingBackend.claimIncomingOffer(
      offer: offer,
      session: session,
    );
    if (result is SdkFailure<void>) {
      // The native provisional backend has already rolled back its exact
      // responder generation on claim/Answer failure. This is the one
      // bounded rollback path that may force-remove the pre-registered SDK
      // object; public releaseSession remains authoritative-terminal only.
      await (session as _RealtimeSession)._dispose(force: true);
      return SdkFailure(result.error);
    }
    return SdkSuccess<RealtimeSession>(session);
  }

  @override
  Future<SdkResult<void>> rejectIncomingOffer(
    RealtimeIncomingSessionOffer offer,
  ) async {
    _ensureUsable();
    final backend = _backend;
    if (backend is! RealtimeIncomingSessionBackend) {
      return SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Incoming Realtime offers are unavailable on this backend.',
          operation: NetworkOperation.send,
          peerId: offer.authenticatedPeerId,
        ),
      );
    }
    final incomingBackend = backend as RealtimeIncomingSessionBackend;
    return incomingBackend.rejectIncomingOffer(offer);
  }

  @override
  Future<void> discardIncomingOffer(RealtimeIncomingSessionOffer offer) async {
    _ensureUsable();
    final backend = _backend;
    if (backend is RealtimeIncomingSessionBackend) {
      await (backend as RealtimeIncomingSessionBackend).discardIncomingOffer(
        offer,
      );
    }
  }

  Future<void> _disposeResources() async {
    for (final session in _sessions.values.toList()) {
      await session._dispose(force: true);
    }
    _sessions.clear();
    await _backendSubscription.cancel();
    await _incomingOffers.close();
    await _backend.dispose();
  }

  void _onBackendEvent(RealtimeBackendEvent event) {
    switch (event) {
      case RealtimeSessionStateChangedEvent(:final realtimeId, :final peerId):
        final session = _sessions[realtimeId];
        if (session == null || session.peerId != peerId) return;
        session._applyState(
          event.state,
          event.error,
          revision: event.revision,
          generation: event.generation,
          sharedSessionInstanceId: event.sharedSessionInstanceId,
        );
      case RealtimeSnapshotBackendEvent(:final snapshot):
        final session = _sessions[snapshot.realtimeId];
        if (session == null || session.peerId != snapshot.peerId) return;
        session._applySnapshot(snapshot);
      case RealtimeAudioStateChangedEvent(:final realtimeId, :final peerId):
        final session = _sessions[realtimeId];
        if (session == null || session.peerId != peerId) return;
        session._applyAudioState(event.state);
      case RealtimeConsentBackendEvent(:final consent):
        final session = _sessions[consent.realtimeId];
        if (session == null || session.peerId != consent.senderPeerId) return;
        session._applyConsent(consent);
      case RealtimeIncomingSessionOfferBackendEvent(:final offer):
        if (!_isValidIncomingOffer(offer)) return;
        _incomingOffers.add(offer);
    }
  }

  bool _isValidIncomingOffer(RealtimeIncomingSessionOffer offer) {
    if (offer.offerId.isEmpty ||
        offer.claimToken.isEmpty ||
        offer.authenticatedPeerId.isEmpty ||
        offer.request.decision != RealtimeConsentDecision.request ||
        offer.request.realtimeId != offer.realtimeId ||
        offer.request.senderPeerId != offer.authenticatedPeerId ||
        offer.request.sharedSessionInstanceId !=
            offer.sharedSessionInstanceId ||
        !offer.request.isFresh(DateTime.now())) {
      return false;
    }
    return offer.bindingExpiresAt.isAfter(DateTime.now());
  }

  Future<SdkResult<void>> _start(_RealtimeSession session) async {
    _ensureUsable();
    return _backend.start(
      realtimeId: session.realtimeId,
      peerId: session.peerId,
    );
  }

  Future<SdkResult<void>> _stop(
    _RealtimeSession session, {
    bool allowDisposed = false,
  }) async {
    if (!allowDisposed) _ensureUsable();
    return _backend.stop(realtimeId: session.realtimeId);
  }

  Future<SdkResult<void>> _sendConsent(
    _RealtimeSession session,
    RealtimeConsent consent,
  ) async {
    _ensureUsable();
    if (consent.realtimeId != session.realtimeId) {
      return SdkFailure(
        NetworkError(
          code: NetworkErrorCode.staleOperation,
          message: 'Consent does not match the active Realtime session.',
          operation: NetworkOperation.send,
          peerId: session.peerId,
        ),
      );
    }
    if (consent.sharedSessionInstanceId != session.sharedSessionInstanceId) {
      return SdkFailure(
        NetworkError(
          code: NetworkErrorCode.staleOperation,
          message:
              'Consent does not match the active Realtime session instance.',
          operation: NetworkOperation.send,
          peerId: session.peerId,
        ),
      );
    }
    final backend = _backend;
    if (backend is! RealtimeConsentBackend) {
      return SdkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'Realtime consent is unavailable on this backend.',
          operation: NetworkOperation.send,
          peerId: session.peerId,
        ),
      );
    }
    return (backend as RealtimeConsentBackend).sendConsent(
      peerId: session.peerId,
      consent: consent,
    );
  }

  void _remove(_RealtimeSession session) {
    if (identical(_sessions[session.realtimeId], session)) {
      _sessions.remove(session.realtimeId);
    }
  }

  void _ensureUsable() {
    if (_disposed) throw const SdkClientDisposedException();
  }
}

void _validateRealtimeId(String value) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw ArgumentError.value(
      value,
      'realtimeId',
      'Realtime ID must be 16-byte lowercase hexadecimal.',
    );
  }
}
