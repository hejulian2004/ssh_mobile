import 'dart:async';

import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

const _defaultMaxPendingCommands = 32;
const _defaultCommandResultTimeout = Duration(seconds: 30);

/// App Shell adapter from the Runtime-owned native Realtime gateway to the
/// high-level network_sdk session contract.
///
/// Native owns PeerConnection, SDP, ICE, signaling, sockets, and media
/// resources. This adapter correlates queue tickets with typed command results,
/// maps lifecycle events, and never forwards native signaling to a Feature.
final class AppRealtimeSessionBackend
    implements RealtimeSessionBackend, RealtimeConsentBackend {
  AppRealtimeSessionBackend({
    required this._networkRuntime,
    this.maxPendingCommands = _defaultMaxPendingCommands,
    this.commandResultTimeout = _defaultCommandResultTimeout,
  }) : assert(maxPendingCommands > 0),
       assert(commandResultTimeout > Duration.zero);

  final NetworkRuntime _networkRuntime;
  final int maxPendingCommands;
  final Duration commandResultTimeout;
  final StreamController<RealtimeBackendEvent> _events =
      StreamController<RealtimeBackendEvent>.broadcast();
  final Map<String, _PendingRealtimeCommand> _pendingCommands =
      <String, _PendingRealtimeCommand>{};
  NetworkRealtimeGateway? _gateway;
  Future<NetworkRealtimeGateway>? _gatewayFuture;
  StreamSubscription<NativeNetworkEvent>? _nativeSubscription;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  Stream<RealtimeBackendEvent> get events => _events.stream;

  @override
  Future<SdkResult<void>> sendConsent({
    required String peerId,
    required RealtimeConsent consent,
  }) async {
    _ensureUsable();
    final gateway = await _ensureGateway();
    if (gateway is! NetworkRealtimeConsentGateway) {
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Native gateway does not support screen-share consent.',
        operation: NetworkOperation.send,
        peerId: peerId,
      );
    }
    final revision = _nextConsentRevision(consent.realtimeId);
    final payload = NativeNetworkProtocol.encodeScreenShareConsent(
      NativeScreenShareConsent(
        schemaVersion: consent.schemaVersion,
        operationId: consent.operationId,
        realtimeId: consent.realtimeId,
        generation: consent.generation,
        issuedAtMs: consent.issuedAtMs,
        expiresAtMs: consent.expiresAtMs,
        decision: NativeScreenShareConsentDecision.values.firstWhere(
          (value) => value.wireValue == consent.decision.wireValue,
        ),
        senderPeerId: consent.senderPeerId,
        purpose: NativeScreenShareConsentPurpose.values.firstWhere(
          (value) => value.wireValue == consent.purpose.wireValue,
        ),
        media: NativeScreenShareMediaKind.values.firstWhere(
          (value) => value.wireValue == consent.media.wireValue,
        ),
        requiresAcceptance: consent.requiresAcceptance,
        actionRevision: consent.actionRevision,
      ),
    );
    return _sendCommand(
      operation: NetworkOperation.send,
      peerId: peerId,
      send: (_) =>
          (gateway as NetworkRealtimeConsentGateway).sendScreenShareConsent(
            realtimeId: consent.realtimeId,
            peerId: peerId,
            revision: revision,
            payload: payload,
          ),
    );
  }

  @override
  Future<SdkResult<void>> start({
    required String realtimeId,
    required String peerId,
  }) => _sendCommand(
    operation: NetworkOperation.connect,
    peerId: peerId,
    send: (gateway) => gateway.start(realtimeId: realtimeId, peerId: peerId),
  );

  @override
  Future<SdkResult<void>> stop({required String realtimeId}) => _sendCommand(
    operation: NetworkOperation.disconnect,
    send: (gateway) => gateway.stop(realtimeId: realtimeId),
  );

  Future<SdkResult<void>> _sendCommand({
    required NetworkOperation operation,
    required NativeCommandTicket Function(NetworkRealtimeGateway gateway) send,
    String? peerId,
  }) async {
    _ensureUsable();
    if (_pendingCommands.length >= maxPendingCommands) {
      return _pendingCapacityFailure(operation: operation, peerId: peerId);
    }
    final gateway = await _ensureGateway();
    _ensureUsable();
    if (_pendingCommands.length >= maxPendingCommands) {
      return _pendingCapacityFailure(operation: operation, peerId: peerId);
    }

    final ticket = send(gateway);
    final queueResult = _mapQueueStatus(
      ticket.queueStatus,
      operation: operation,
      peerId: peerId,
    );
    if (queueResult is SdkFailure<void>) return queueResult;

    final pending = _PendingRealtimeCommand(
      operation: operation,
      peerId: peerId,
      completer: Completer<SdkResult<void>>(),
    );
    _pendingCommands[ticket.commandId] = pending;
    pending.timer = Timer(commandResultTimeout, () {
      final current = _pendingCommands.remove(ticket.commandId);
      if (!identical(current, pending) || pending.completer.isCompleted) return;
      pending.completer.complete(
        _failure(
          code: NetworkErrorCode.timeout,
          message: 'Native Realtime command result timed out.',
          operation: operation,
          peerId: peerId,
        ),
      );
    });
    return pending.completer.future;
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    if (_disposed) return Future<void>.value();
    _disposed = true;
    _cancelPendingCommands();
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<NetworkRealtimeGateway> _ensureGateway() {
    final current = _gateway;
    if (current != null) return Future<NetworkRealtimeGateway>.value(current);
    final existing = _gatewayFuture;
    if (existing != null) return existing;

    late final Future<NetworkRealtimeGateway> future;
    future = _networkRuntime.openRealtimeGateway();
    _gatewayFuture = future;
    future.then<void>(
      (gateway) {
        if (!identical(_gatewayFuture, future) || _disposed) return;
        _gatewayFuture = null;
        _gateway = gateway;
        _nativeSubscription = gateway.events.listen(_onNativeEvent);
      },
      onError: (Object _, StackTrace _) {
        if (identical(_gatewayFuture, future)) _gatewayFuture = null;
      },
    );
    return future;
  }

  void _onNativeEvent(NativeNetworkEvent event) {
    if (_disposed) return;
    switch (event) {
      case NativeRealtimeStateChangedEvent(
        :final realtimeId,
        :final peerId,
        :final state,
        :final revision,
        :final generation,
        :final error,
      ):
        _events.add(
          RealtimeSessionStateChangedEvent(
            realtimeId: realtimeId,
            peerId: peerId,
            state: _mapState(state),
            revision: revision,
            generation: generation,
            error: error == null ? null : _mapError(error),
          ),
        );
      case NativeRealtimeSnapshotEvent(
        :final realtimeId,
        :final peerId,
        :final state,
        :final revision,
        :final generation,
        :final error,
      ):
        // 快照在 session 存在前到达时由 SDK coordinator 忽略；这里只做类型映射。
        _events.add(
          RealtimeSnapshotBackendEvent(
            RealtimeSnapshot(
              realtimeId: realtimeId,
              peerId: peerId,
              state: _mapState(state),
              revision: revision,
              generation: generation,
              error: error == null ? null : _mapError(error),
            ),
          ),
        );
      case NativeRealtimeSignalEvent event
          when event.kind == NativeRealtimeSignalKind.screenShareConsent &&
              event.consent != null:
        final consent = event.consent!;
        try {
          _events.add(
            RealtimeConsentBackendEvent(
              RealtimeConsent(
                schemaVersion: consent.schemaVersion,
                operationId: consent.operationId,
                realtimeId: consent.realtimeId,
                generation: consent.generation,
                issuedAt: DateTime.fromMillisecondsSinceEpoch(
                  consent.issuedAtMs,
                ),
                expiresAt: DateTime.fromMillisecondsSinceEpoch(
                  consent.expiresAtMs,
                ),
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
              ),
            ),
          );
        } on Object {
          // Native decoding is fail-closed; keep this adapter defensive if a
          // future decoder returns an unknown enum value.
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
      _failure(
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

  Future<void> _disposeResources() async {
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    final pendingGateway = _gatewayFuture;
    if (pendingGateway != null) {
      try {
        await pendingGateway;
      } catch (_) {
        // A failed lazy open has no subscription to cancel.
      }
    }
    _gateway = null;
    _gatewayFuture = null;
    await _events.close();
  }

  final Map<String, int> _consentRevisions = <String, int>{};

  int _nextConsentRevision(String realtimeId) {
    final next = (_consentRevisions[realtimeId] ?? 0) + 1;
    _consentRevisions[realtimeId] = next;
    return next;
  }

  void _ensureUsable() {
    if (_disposed) throw const SdkClientDisposedException();
  }

  void _cancelPendingCommands() {
    final pendingCommands = _pendingCommands.values.toList();
    _pendingCommands.clear();
    for (final pending in pendingCommands) {
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          _failure(
            code: NetworkErrorCode.cancelled,
            message: 'Realtime backend was disposed.',
            operation: pending.operation,
            peerId: pending.peerId,
          ),
        );
      }
    }
  }

  static SdkResult<void> _mapQueueStatus(
    NativeOperationStatus status, {
    required NetworkOperation operation,
    String? peerId,
  }) => switch (status) {
    NativeOperationStatus.success => const SdkSuccess<void>(null),
    NativeOperationStatus.invalidArgument => _failure(
      code: NetworkErrorCode.invalidArgument,
      message: 'Realtime command arguments were rejected.',
      operation: operation,
      peerId: peerId,
    ),
    NativeOperationStatus.stopped => _failure(
      code: NetworkErrorCode.cancelled,
      message: 'Native network runtime is stopped.',
      operation: operation,
      peerId: peerId,
    ),
    NativeOperationStatus.failure => _failure(
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
    NativeOperationStatus.frameRejected => _failure(
      code: NetworkErrorCode.ioError,
      message: 'Native Realtime command returned an unexpected media status.',
      operation: operation,
      peerId: peerId,
    ),
  };

  static SdkFailure<void> _pendingCapacityFailure({
    required NetworkOperation operation,
    String? peerId,
  }) => _failure(
    code: NetworkErrorCode.ioError,
    message: 'Too many Realtime commands are awaiting native results.',
    operation: operation,
    peerId: peerId,
  );

  static SdkFailure<void> _failure({
    required NetworkErrorCode code,
    required String message,
    required NetworkOperation operation,
    String? peerId,
    RetryDisposition retryDisposition = RetryDisposition.unspecified,
    int retryAfterSeconds = 0,
  }) => SdkFailure<void>(
    NetworkError(
      code: code,
      message: message,
      operation: operation,
      peerId: peerId,
      retryDisposition: retryDisposition,
      retryAfterSeconds: retryAfterSeconds,
    ),
  );

  static RealtimeSessionState _mapState(
    NativeRealtimeSessionState state,
  ) => switch (state) {
    NativeRealtimeSessionState.unspecified => RealtimeSessionState.idle,
    NativeRealtimeSessionState.negotiating => RealtimeSessionState.negotiating,
    NativeRealtimeSessionState.connected => RealtimeSessionState.connected,
    NativeRealtimeSessionState.restarting => RealtimeSessionState.restarting,
    NativeRealtimeSessionState.closed => RealtimeSessionState.stopped,
    NativeRealtimeSessionState.failed => RealtimeSessionState.failed,
  };

  static NetworkError _mapError(NativeNetworkError error) => NetworkError(
    code: NetworkErrorCode.fromWire(error.code),
    message: error.message,
    peerId: error.peerId,
    retryDisposition: RetryDisposition.fromWire(
      error.retryDisposition.wireValue,
    ),
    retryAfterSeconds: error.retryAfterSeconds,
  );
}

final class _PendingRealtimeCommand {
  _PendingRealtimeCommand({
    required this.operation,
    required this.peerId,
    required this.completer,
  });

  final NetworkOperation operation;
  final String? peerId;
  final Completer<SdkResult<void>> completer;
  Timer? timer;
}
