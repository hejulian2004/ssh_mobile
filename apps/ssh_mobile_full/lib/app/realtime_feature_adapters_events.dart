part of 'realtime_feature_adapters.dart';

extension on AppRealtimeSessionBackend {
  void _onNativeEvent(NativeNetworkEvent event) {
    if (_disposed) return;
    switch (event) {
      case NativeRealtimeStateChangedEvent(
        :final realtimeId,
        :final peerId,
        :final state,
        :final revision,
        :final generation,
        :final sharedSessionInstanceId,
        :final error,
      ):
        _events.add(
          RealtimeSessionStateChangedEvent(
            realtimeId: realtimeId,
            peerId: peerId,
            state: _mapRealtimeState(state),
            revision: revision,
            generation: generation,
            sharedSessionInstanceId: sharedSessionInstanceId,
            error: error == null ? null : _mapRealtimeError(error),
          ),
        );
      case NativeRealtimeSnapshotEvent(
        :final realtimeId,
        :final peerId,
        :final state,
        :final revision,
        :final generation,
        :final sharedSessionInstanceId,
        :final error,
      ):
        // SDK claim path pre-registers the responder before native can emit this
        // event. A genuinely unknown session is still ignored by the SDK
        // registry, preserving fail-closed lifecycle routing.
        _events.add(
          RealtimeSnapshotBackendEvent(
            RealtimeSnapshot(
              realtimeId: realtimeId,
              peerId: peerId,
              state: _mapRealtimeState(state),
              revision: revision,
              generation: generation,
              sharedSessionInstanceId: sharedSessionInstanceId,
              error: error == null ? null : _mapRealtimeError(error),
            ),
          ),
        );
      case NativeRealtimeSignalEvent event
          when event.kind == NativeRealtimeSignalKind.screenShareConsent &&
              event.consent != null:
        final consent = event.consent!;
        try {
          _events.add(
            RealtimeConsentBackendEvent(_mapRealtimeConsent(consent)),
          );
        } on Object {
          // Native decoding is fail-closed; keep this adapter defensive if a
          // future decoder returns an unknown enum value.
          return;
        }
      case NativeRealtimeIncomingSessionOfferEvent event:
        try {
          _events.add(
            RealtimeIncomingSessionOfferBackendEvent(
              RealtimeIncomingSessionOffer(
                offerId: event.offerId,
                claimToken: event.claimToken,
                realtimeId: event.realtimeId,
                authenticatedPeerId: event.authenticatedPeerId,
                sharedSessionInstanceId: event.sharedSessionInstanceId,
                bindingExpiresAt: DateTime.fromMillisecondsSinceEpoch(
                  event.bindingExpiresAtMs,
                ),
                request: _mapRealtimeConsent(event.request),
              ),
            ),
          );
        } on Object {
          return;
        }
      case NativeCommandResultEvent event:
        _completeCommand(event);
      case NativePeerStateChangedEvent():
      case NativeRealtimeSignalEvent():
      case NativeSshStreamDataReceivedEvent():
      case NativeSshStreamClosedEvent():
      // Command acceptance and SDP/ICE signaling are native concerns. The
      // session state and snapshot events are the only lifecycle sources.
      // SSH stream data/closed events are consumed by the SSH connector.
      default:
        // Transfer, Relay, channel, presence, and future native events are
        // consumed by their owning adapter; this realtime adapter ignores
        // them without claiming ownership.
        return;
    }
  }

  void _completeCommand(NativeCommandResultEvent event) {
    final pending = _pendingCommands.remove(event.commandId);
    if (pending == null || _disposed) return;
    pending.timer?.cancel();
    if (event.accepted) {
      pending.completer.complete(const SdkSuccess<void>(null));
      return;
    }
    pending.completer.complete(
      AppRealtimeSessionBackend._failure(
        code: event.error == null
            ? NetworkErrorCode.ioError
            : NetworkErrorCode.fromWire(event.error!.code),
        message:
            event.error?.message ?? 'Native Realtime command was rejected.',
        operation: pending.operation,
        peerId: event.error?.peerId ?? pending.peerId,
        retryDisposition: event.error == null
            ? RetryDisposition.unspecified
            : RetryDisposition.fromWire(
                event.error!.retryDisposition.wireValue,
              ),
        retryAfterSeconds: event.error?.retryAfterSeconds ?? 0,
      ),
    );
  }
}

SdkResult<void> _mapRealtimeQueueStatus(
  NativeOperationStatus status, {
  required NetworkOperation operation,
  String? peerId,
}) => switch (status) {
  NativeOperationStatus.success => const SdkSuccess<void>(null),
  NativeOperationStatus.invalidArgument => AppRealtimeSessionBackend._failure(
    code: NetworkErrorCode.invalidArgument,
    message: 'Realtime command arguments were rejected.',
    operation: operation,
    peerId: peerId,
  ),
  NativeOperationStatus.stopped => AppRealtimeSessionBackend._failure(
    code: NetworkErrorCode.cancelled,
    message: 'Native network runtime is stopped.',
    operation: operation,
    peerId: peerId,
  ),
  NativeOperationStatus.failure => AppRealtimeSessionBackend._failure(
    code: NetworkErrorCode.ioError,
    message: 'Native Realtime command was not queued.',
    operation: operation,
    peerId: peerId,
  ),
  // These statuses belong to the dedicated realtime-media ABI. They are
  // not expected from the generic command queue, so fail closed if a
  // native implementation ever leaks one through this path.
  NativeOperationStatus.unknownSession ||
  NativeOperationStatus.staleGeneration ||
  NativeOperationStatus.staleEndpoint ||
  NativeOperationStatus.directionMismatch ||
  NativeOperationStatus.duplicateEndpoint ||
  NativeOperationStatus.driverUnavailable ||
  NativeOperationStatus.peerMismatch ||
  NativeOperationStatus.frameRejected => AppRealtimeSessionBackend._failure(
    code: NetworkErrorCode.ioError,
    message: 'Native Realtime command returned an unexpected media status.',
    operation: operation,
    peerId: peerId,
  ),
};

SdkFailure<void> _realtimePendingCapacityFailure({
  required NetworkOperation operation,
  String? peerId,
}) => AppRealtimeSessionBackend._failure(
  code: NetworkErrorCode.ioError,
  message: 'Too many Realtime commands are awaiting native results.',
  operation: operation,
  peerId: peerId,
);

RealtimeSessionState _mapRealtimeState(NativeRealtimeSessionState state) =>
    switch (state) {
      NativeRealtimeSessionState.unspecified => RealtimeSessionState.idle,
      NativeRealtimeSessionState.negotiating =>
        RealtimeSessionState.negotiating,
      NativeRealtimeSessionState.connected => RealtimeSessionState.connected,
      NativeRealtimeSessionState.restarting => RealtimeSessionState.restarting,
      NativeRealtimeSessionState.closed => RealtimeSessionState.stopped,
      NativeRealtimeSessionState.failed => RealtimeSessionState.failed,
    };

RealtimeConsent _mapRealtimeConsent(NativeScreenShareConsent consent) =>
    RealtimeConsent(
      schemaVersion: consent.schemaVersion,
      operationId: consent.operationId,
      realtimeId: consent.realtimeId,
      sharedSessionInstanceId: consent.sharedSessionInstanceId,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(consent.issuedAtMs),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(consent.expiresAtMs),
      decision: RealtimeConsentDecision.values.firstWhere(
        (value) => value.wireValue == consent.decision.wireValue,
      ),
      senderPeerId: consent.senderPeerId,
      purpose: RealtimeConsentPurpose.values.firstWhere(
        (value) => value.wireValue == consent.purpose.wireValue,
      ),
      media: RealtimeConsentMedia.values.firstWhere(
        (value) => value.wireValue == consent.media.wireValue,
      ),
      requiresAcceptance: consent.requiresAcceptance,
      actionRevision: consent.actionRevision,
    );

NetworkError _mapRealtimeError(NativeNetworkError error) => NetworkError(
  code: NetworkErrorCode.fromWire(error.code),
  message: error.message,
  peerId: error.peerId,
  retryDisposition: RetryDisposition.fromWire(error.retryDisposition.wireValue),
  retryAfterSeconds: error.retryAfterSeconds,
);
