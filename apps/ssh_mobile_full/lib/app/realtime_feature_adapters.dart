import 'dart:async';

import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

part 'realtime_feature_adapters_events.dart';

const _defaultMaxPendingCommands = 32;
const _defaultCommandResultTimeout = Duration(seconds: 30);

/// App Shell adapter from the Runtime-owned native Realtime gateway to the
/// high-level network_sdk session contract.
///
/// Native owns PeerConnection, SDP, ICE, signaling, sockets, and media
/// resources. This adapter correlates queue tickets with typed command results,
/// maps lifecycle events, and never forwards native signaling to a Feature.
final class AppRealtimeSessionBackend
    implements
        RealtimeSessionBackend,
        RealtimeConsentBackend,
        RealtimeIncomingSessionBackend {
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
        sharedSessionInstanceId: consent.sharedSessionInstanceId,
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
  Future<SdkResult<void>> claimIncomingOffer({
    required RealtimeIncomingSessionOffer offer,
    required RealtimeSession session,
  }) async {
    _ensureUsable();
    final gateway = await _ensureGateway();
    if (gateway is! NetworkRealtimeIncomingOfferGateway) {
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message:
            'Native gateway does not support incoming screen-share offers.',
        operation: NetworkOperation.connect,
        peerId: offer.authenticatedPeerId,
      );
    }
    return _sendCommand(
      operation: NetworkOperation.connect,
      peerId: offer.authenticatedPeerId,
      send: (_) => gateway.claimIncomingRealtimeOffer(
        realtimeId: offer.realtimeId,
        peerId: session.peerId,
        claimToken: offer.claimToken,
      ),
    );
  }

  @override
  Future<SdkResult<void>> rejectIncomingOffer(
    RealtimeIncomingSessionOffer offer,
  ) async {
    _ensureUsable();
    final gateway = await _ensureGateway();
    if (gateway is! NetworkRealtimeIncomingOfferGateway) {
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message:
            'Native gateway does not support incoming screen-share offers.',
        operation: NetworkOperation.send,
        peerId: offer.authenticatedPeerId,
      );
    }
    return _sendCommand(
      operation: NetworkOperation.send,
      peerId: offer.authenticatedPeerId,
      send: (_) => gateway.rejectIncomingRealtimeOffer(
        realtimeId: offer.realtimeId,
        peerId: offer.authenticatedPeerId,
        claimToken: offer.claimToken,
      ),
    );
  }

  @override
  Future<void> discardIncomingOffer(RealtimeIncomingSessionOffer offer) async {
    _ensureUsable();
    final gateway = await _ensureGateway();
    if (gateway is! NetworkRealtimeIncomingOfferGateway) return;
    await _sendCommand(
      operation: NetworkOperation.disconnect,
      peerId: offer.authenticatedPeerId,
      send: (_) => gateway.discardIncomingRealtimeOffer(
        realtimeId: offer.realtimeId,
        peerId: offer.authenticatedPeerId,
        claimToken: offer.claimToken,
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
      return _realtimePendingCapacityFailure(
        operation: operation,
        peerId: peerId,
      );
    }
    final gateway = await _ensureGateway();
    _ensureUsable();
    if (_pendingCommands.length >= maxPendingCommands) {
      return _realtimePendingCapacityFailure(
        operation: operation,
        peerId: peerId,
      );
    }

    final ticket = send(gateway);
    final queueResult = _mapRealtimeQueueStatus(
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
