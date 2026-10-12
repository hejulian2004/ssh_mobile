// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart';

import 'lan_peer_trust.dart';
import 'lan_network_models.dart';
import 'lan_share_models.dart';
import 'lan_storage_service.dart';
import 'lan_transfer_protocol.dart';
import 'lan_transfer_service.dart';

part 'lan_native_transfer_validation.dart';
part 'lan_native_transfer_responses.dart';
part 'lan_native_transfer_events.dart';

/// Owns the complete Network V2 binary-transfer orchestration for LAN Share.
///
/// The coordinator is intentionally the only feature object that knows how to
/// turn an authenticated LAN capability snapshot or persistent Relay authorization
/// into native peer connectivity. View models receive a result and an event stream;
/// they never hold a facade, peer configuration, capability cache, or native-port cache.
final class LanNativeTransferCoordinator {
  LanNativeTransferCoordinator({
    required LanTransferService transferService,
    required NetworkFacade networkFacade,
    required LanNativePeerPolicyPort policyPort,
    required LanStorageService storageService,
    this.offerTimeout = defaultOfferTimeout,
  }) : _transferService = transferService,
       _networkFacade = networkFacade,
       _policyPort = policyPort,
       _storageService = storageService {
    _networkSubscription = _networkFacade.events.listen(
      _handleNetworkEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (!_events.isClosed) _events.addError(error, stackTrace);
      },
    );
  }

  /// 默认传入传输申请超时时间（25 秒）。
  static const defaultOfferTimeout = Duration(seconds: 25);

  /// Authenticated LAN HTTPS capability/control service.
  final LanTransferService _transferService;

  /// App-scope Network V2 facade borrowed for the coordinator lifetime.
  final NetworkFacade _networkFacade;

  /// Authority port for native peer policy and trust reconciliation.
  final LanNativePeerPolicyPort _policyPort;

  /// Storage service for disk space pre-flight validation.
  final LanStorageService _storageService;

  /// Time after which an unanswered incoming offer is rejected.
  final Duration offerTimeout;

  final _incomingOffers = StreamController<IncomingTransferOffer>.broadcast();
  final _events = StreamController<SdkEvent>.broadcast();
  final _routeStateController =
      StreamController<Map<String, LanPeerRouteState>>.broadcast();

  final Map<String, IncomingTransferOffer> _pendingOffers = {};
  final Map<String, Timer> _offerTimers = {};
  final Map<String, bool> _committedDecisions = {};
  final Map<String, _IncomingDecisionOperation> _decisionOperations = {};
  final Map<String, LanPeerRouteState> _routeStates = {};

  StreamSubscription<SdkEvent>? _networkSubscription;
  bool _disposed = false;

  /// Native offers that still require one user decision.
  Stream<IncomingTransferOffer> get incomingOffers => _incomingOffers.stream;

  /// Native transfer progress/completion/failure and other V2 events.
  Stream<SdkEvent> get events => _events.stream;

  /// Stream of projected route states for trusted peers.
  Stream<Map<String, LanPeerRouteState>> get routeStates =>
      _routeStateController.stream;

  /// Current snapshot of route states.
  Map<String, LanPeerRouteState> get currentRouteStates =>
      Map<String, LanPeerRouteState>.unmodifiable(_routeStates);

  /// Reconciles paired identity and prepares the authenticated signaling carrier.
  Future<NetworkResult<void>> prepareRealtimeConnection({
    required String peerId,
    LanDiscoveredPeer? discovery,
  }) => _prepareRealtimeConnection(peerId, discovery);

  /// Sends one regular file through Network V2 only.
  ///
  /// Supports both direct LAN connections (when [discovery] is present) and
  /// offline Relay transfers (when [discovery] is null and Relay is authorized).
  Future<NetworkResult<TransferSession>> sendFile({
    required String peerId,
    required String transferId,
    required String filePath,
    LanDiscoveredPeer? discovery,
  }) async {
    if (_disposed) {
      return _failure(
        code: NetworkErrorCode.cancelled,
        message: 'Native transfer coordinator is disposed.',
        operation: NetworkOperation.sendFile,
        peerId: peerId,
      );
    }

    final file = File(filePath);
    final validation = await _validateSourceFile(file, peerId);
    if (validation != null) return validation;

    final policyResult = await _policyPort.getPeerPolicy(peerId);
    if (policyResult is NetworkFailure<LanPeerPolicySnapshot>) {
      return NetworkFailure<TransferSession>(policyResult.error);
    }
    final policy = (policyResult as NetworkSuccess<LanPeerPolicySnapshot>).data;
    if (!policy.isTrusted) {
      return _failure(
        code: NetworkErrorCode.authenticationFailed,
        message: policy.runtimeBlocked
            ? 'Peer is runtime-blocked due to inconsistent native state.'
            : 'Peer trust is unavailable.',
        operation: NetworkOperation.sendFile,
        peerId: peerId,
      );
    }
    final trust = policy.trust!;

    // Pairing and runtime generations are independent. A peer can have a
    // durable trust record while the current native generation has not yet
    // received its registration (for example when the user starts a
    // transfer immediately after pairing). Reconcile before any route or
    // connect attempt so QUIC authentication never races registration.
    final reconcileResult = await _policyPort.reconcilePersistedTrust(trust);
    if (reconcileResult is NetworkFailure<void>) {
      return NetworkFailure<TransferSession>(reconcileResult.error);
    }

    if (discovery != null) {
      final capability = await _fetchCapabilities(discovery, trust);
      if (capability is NetworkFailure<_NativeCapability>) {
        if (trust.authorization.relay &&
            _canFallbackToRelay(capability.error.code)) {
          return _fallbackToRelay(
            peerId: peerId,
            transferId: transferId,
            file: file,
          );
        }
        await _policyPort.invalidateDirectEndpoint(peerId);
        return NetworkFailure<TransferSession>(capability.error);
      }

      final snapshot = (capability as NetworkSuccess<_NativeCapability>).data;
      final endpoint = _formatEndpoint(discovery.ip, snapshot.nativePort);

      final registerResult = await _policyPort.updateDirectEndpoint(
        peerId,
        endpoint,
      );
      if (registerResult is NetworkFailure<void>) {
        if (trust.authorization.relay &&
            _canFallbackToRelay(registerResult.error.code)) {
          return _fallbackToRelay(
            peerId: peerId,
            transferId: transferId,
            file: file,
          );
        }
        await _policyPort.invalidateDirectEndpoint(peerId);
        return NetworkFailure<TransferSession>(registerResult.error);
      }

      final connectResult = await _connect(peerId);
      if (connectResult is NetworkFailure<void>) {
        if (trust.authorization.relay &&
            _canFallbackToRelay(connectResult.error.code)) {
          return _fallbackToRelay(
            peerId: peerId,
            transferId: transferId,
            file: file,
          );
        }
        await _policyPort.invalidateDirectEndpoint(peerId);
        return NetworkFailure<TransferSession>(connectResult.error);
      }

      return _transfer(peerId: peerId, transferId: transferId, file: file);
    } else {
      // Offline send path (no discovery candidate)
      if (!trust.authorization.relay) {
        return _failure(
          code: NetworkErrorCode.noRoute,
          message: 'Peer is not in local network and Relay is not authorized.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      return _fallbackToRelay(
        peerId: peerId,
        transferId: transferId,
        file: file,
      );
    }
  }

  Future<NetworkResult<TransferSession>> _fallbackToRelay({
    required String peerId,
    required String transferId,
    required File file,
  }) async {
    final invalidationResult = await _policyPort.invalidateDirectEndpoint(
      peerId,
    );
    if (invalidationResult is NetworkFailure<void>) {
      return NetworkFailure<TransferSession>(invalidationResult.error);
    }

    final policyResult = await _policyPort.getPeerPolicy(peerId);
    if (policyResult is NetworkFailure<LanPeerPolicySnapshot>) {
      return NetworkFailure<TransferSession>(policyResult.error);
    }
    final policy = (policyResult as NetworkSuccess<LanPeerPolicySnapshot>).data;
    if (!policy.isTrusted ||
        policy.runtimeBlocked ||
        policy.revoked ||
        policy.trust?.authorization.relay != true) {
      return _failure(
        code: NetworkErrorCode.noRoute,
        message:
            'Peer is not trusted, runtime-blocked, or Relay is not authorized.',
        operation: NetworkOperation.sendFile,
        peerId: peerId,
      );
    }

    final connectResult = await _connect(peerId);
    if (connectResult is NetworkFailure<void>) {
      return NetworkFailure<TransferSession>(connectResult.error);
    }
    return _transfer(peerId: peerId, transferId: transferId, file: file);
  }

  Future<NetworkResult<void>> _connect(String peerId) async {
    try {
      return await _networkFacade.connectPeer(
        peerId,
        communicationClass: CommunicationClass.bulkTransfer,
      );
    } catch (error) {
      return NetworkFailure<void>(
        lanNetworkError(
          error,
          operation: NetworkOperation.connect,
          peerId: peerId,
        ),
      );
    }
  }

  Future<NetworkResult<TransferSession>> _transfer({
    required String peerId,
    required String transferId,
    required File file,
  }) async {
    try {
      return await _networkFacade.transferFile(
        transferId: transferId,
        peerId: peerId,
        filePath: file.absolute.path,
        communicationClass: CommunicationClass.bulkTransfer,
      );
    } catch (error) {
      return NetworkFailure<TransferSession>(
        lanNetworkError(
          error,
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        ),
      );
    }
  }

  /// Accepts a native offer only when the peer still has complete trust and route authorization.
  Future<NetworkResult<void>> accept(IncomingTransferOffer offer) =>
      _respond(offer, accept: true);

  /// Rejects a native offer. Repeated identical decisions are idempotent.
  Future<NetworkResult<void>> reject(IncomingTransferOffer offer) =>
      _respond(offer, accept: false);

  /// Explicitly revokes trust and removes the native peer configuration.
  Future<NetworkResult<void>> removeTrustedPeer(String deviceId) async {
    if (_disposed) {
      return _failure(
        code: NetworkErrorCode.cancelled,
        message: 'Native transfer coordinator is disposed.',
        operation: NetworkOperation.removePeer,
        peerId: deviceId,
      );
    }
    try {
      return await _policyPort.removeTrust(deviceId);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.removePeer,
          peerId: deviceId,
        ),
      );
    }
  }

  /// Sets the persistent and native Relay authorization for a trusted peer.
  Future<NetworkResult<void>> setRelayAuthorization({
    required String peerId,
    required bool enabled,
  }) async {
    try {
      return await _policyPort.setRelayAuthorization(peerId, enabled);
    } catch (error) {
      return NetworkFailure<void>(
        lanNetworkError(
          error,
          operation: NetworkOperation.upsertPeer,
          peerId: peerId,
        ),
      );
    }
  }

  /// Queries the current policy snapshot for a peer.
  Future<NetworkResult<LanPeerPolicySnapshot>> getPeerPolicy(String peerId) =>
      _policyPort.getPeerPolicy(peerId);

  /// Closes subscriptions and offer timers without disposing the App facade.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _offerTimers.values) {
      timer.cancel();
    }
    _offerTimers.clear();
    _pendingOffers.clear();
    _decisionOperations.clear();
    _committedDecisions.clear();
    _routeStates.clear();
    await _networkSubscription?.cancel();
    await _incomingOffers.close();
    await _routeStateController.close();
    await _events.close();
  }

  static Uint8List _decodePublicKey(Object? value) {
    if (value is! String) {
      throw const FormatException('Native capability key is missing.');
    }
    final decoded = base64.decode(value);
    if (decoded.length != 32) {
      throw const FormatException('Native capability key is invalid.');
    }
    return Uint8List.fromList(decoded);
  }

  static String _normalizeHost(String rawHost) {
    final host = rawHost.trim();
    if (host.startsWith('[') && host.endsWith(']')) {
      return host.substring(1, host.length - 1);
    }
    if (host.isEmpty ||
        host.length > 253 ||
        RegExp(r'[\x00-\x20/@?#\\\[\]]').hasMatch(host)) {
      throw const FormatException('LAN peer address is invalid.');
    }
    return host;
  }

  static String _formatEndpoint(String rawHost, int port) {
    final host = _normalizeHost(rawHost);
    return host.contains(':') ? '[$host]:$port' : '$host:$port';
  }

  static bool _canFallbackToRelay(NetworkErrorCode code) => switch (code) {
    NetworkErrorCode.noRoute ||
    NetworkErrorCode.peerOffline ||
    NetworkErrorCode.timeout ||
    NetworkErrorCode.pathLost ||
    NetworkErrorCode.quicError ||
    NetworkErrorCode.ioError => true,
    _ => false,
  };

  static NetworkFailure<T> _failure<T>({
    required NetworkErrorCode code,
    required String message,
    required NetworkOperation operation,
    String? peerId,
  }) => NetworkFailure<T>(
    NetworkError(
      code: code,
      message: message,
      operation: operation,
      peerId: peerId,
    ),
  );
}

final class _NativeCapability {
  const _NativeCapability(this.nativePort);

  final int nativePort;
}

final class _IncomingDecisionOperation {
  const _IncomingDecisionOperation({
    required this.accept,
    required this.future,
  });

  final bool accept;
  final Future<NetworkResult<void>> future;
}
