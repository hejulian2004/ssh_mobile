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

  Future<NetworkResult<TransferSession>?> _validateSourceFile(
    File file,
    String peerId,
  ) async {
    try {
      if (!await file.exists()) {
        return _failure(
          code: NetworkErrorCode.ioError,
          message: 'Source file is unavailable.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        return _failure(
          code: NetworkErrorCode.invalidArgument,
          message: 'Only regular files can be sent through Network V2.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      final name = file.uri.pathSegments.isEmpty
          ? ''
          : file.uri.pathSegments.last;
      if (name.isEmpty || name == '.' || name == '..') {
        return _failure(
          code: NetworkErrorCode.invalidArgument,
          message: 'Source file name is invalid.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      return null;
    } catch (error) {
      return _failure(
        code: NetworkErrorCode.ioError,
        message: 'Source file cannot be inspected.',
        operation: NetworkOperation.sendFile,
        peerId: peerId,
      );
    }
  }

  Future<NetworkResult<_NativeCapability>> _fetchCapabilities(
    LanDiscoveredPeer device,
    LanPeerTrustRecord trust,
  ) async {
    HttpClient? client;
    try {
      client = await _transferService.createHttpClientForPeer(
        device.deviceId,
        expectedFingerprint: trust.certificateFingerprint,
      );
      final host = _normalizeHost(device.ip);
      final request = await client
          .getUrl(
            Uri(
              scheme: 'https',
              host: host,
              port: device.controlPort,
              path: '/api/lan/capabilities',
            ),
          )
          .timeout(const Duration(seconds: 4));
      request.followRedirects = false;
      request.headers.set('x-device-id', _transferService.currentDeviceId);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${trust.outboundAccessToken}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final body = await _transferService.readBoundedJsonResponse(response);
      if (response.statusCode != HttpStatus.ok) {
        throw lanHttpException(
          statusCode: response.statusCode,
          body: body,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
          fallbackMessage: 'LAN capability query failed.',
        );
      }
      final protocolVersion = body['protocolVersion'];
      if (protocolVersion != LanControlProtocol.version) {
        throw LanNetworkException(
          'Unsupported LAN Control protocol version: $protocolVersion (expected ${LanControlProtocol.version})',
          code: NetworkErrorCode.protocolMismatch,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
        );
      }
      if (body['e2eEncryption'] != true || body['quicFileTransfer'] != true) {
        throw const LanNetworkException(
          'Recipient native file transfer is unavailable.',
          code: NetworkErrorCode.noRoute,
          operation: NetworkOperation.fetchCapabilities,
        );
      }
      final x25519 = _decodePublicKey(body['x25519PubKey']);
      final identity = _decodePublicKey(body['networkIdentityPubKey']);
      if (!listEquals(x25519, trust.x25519PublicKey) ||
          !listEquals(identity, trust.networkIdentityPublicKey)) {
        throw LanNetworkException(
          'Recipient identity conflicts with the paired trust record.',
          code: NetworkErrorCode.identityConflict,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
        );
      }
      final nativePort = (body['quicPort'] as num?)?.toInt();
      if (nativePort == null || nativePort < 1 || nativePort > 65535) {
        throw LanNetworkException(
          'Recipient native transfer endpoint is unavailable.',
          code: NetworkErrorCode.noRoute,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
        );
      }
      return NetworkSuccess(_NativeCapability(nativePort));
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.fetchCapabilities,
          peerId: device.deviceId,
        ),
      );
    } finally {
      client?.close();
    }
  }

  Future<NetworkResult<void>> _respond(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    if (_disposed) {
      return _failure(
        code: NetworkErrorCode.cancelled,
        message: 'Native transfer coordinator is disposed.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }
    _pendingOffers[offer.transferId] ??= offer;
    final committed = _committedDecisions[offer.transferId];
    if (committed != null) {
      if (committed == accept) return const NetworkSuccess<void>(null);
      return _failure(
        code: NetworkErrorCode.invalidArgument,
        message: 'Incoming transfer already has a different decision.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    final inFlight = _decisionOperations[offer.transferId];
    if (inFlight != null) {
      if (inFlight.accept == accept) {
        return inFlight.future;
      }
      return _failure(
        code: NetworkErrorCode.invalidState,
        message: 'A conflicting decision is currently in flight.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    final completer = Completer<NetworkResult<void>>();
    _decisionOperations[offer.transferId] = _IncomingDecisionOperation(
      accept: accept,
      future: completer.future,
    );

    try {
      final result = await _executeRespond(offer, accept: accept);
      if (identical(
        _decisionOperations[offer.transferId]?.future,
        completer.future,
      )) {
        _decisionOperations.remove(offer.transferId);
      }
      completer.complete(result);
      return result;
    } catch (error) {
      final failure = NetworkFailure<void>(
        lanNetworkError(
          error,
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        ),
      );
      if (identical(
        _decisionOperations[offer.transferId]?.future,
        completer.future,
      )) {
        _decisionOperations.remove(offer.transferId);
      }
      completer.complete(failure);
      return failure;
    } finally {
      if (identical(
        _decisionOperations[offer.transferId]?.future,
        completer.future,
      )) {
        _decisionOperations.remove(offer.transferId);
      }
    }
  }

  Future<NetworkResult<void>> _executeRespond(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    final policyResult = await _policyPort.getPeerPolicy(offer.peerId);
    if (policyResult is NetworkFailure<LanPeerPolicySnapshot>) {
      final nativeRes = await _respondNative(offer, accept: false);
      if (nativeRes is NetworkSuccess<void>) {
        _committedDecisions[offer.transferId] = false;
        _pendingOffers.remove(offer.transferId);
        _offerTimers.remove(offer.transferId)?.cancel();
      }
      return NetworkFailure<void>(policyResult.error);
    }
    final policy = (policyResult as NetworkSuccess<LanPeerPolicySnapshot>).data;
    if (!policy.isTrusted ||
        !isIncomingRouteAuthorized(
          policy.trust!.authorization,
          offer.routeType,
        )) {
      final nativeRes = await _respondNative(offer, accept: false);
      if (nativeRes is NetworkSuccess<void>) {
        _committedDecisions[offer.transferId] = false;
        _pendingOffers.remove(offer.transferId);
        _offerTimers.remove(offer.transferId)?.cancel();
      }
      return _failure(
        code: NetworkErrorCode.authenticationFailed,
        message:
            'Incoming transfer peer is not trusted or route is unauthorized.',
        operation: NetworkOperation.respondToIncoming,
        peerId: offer.peerId,
      );
    }

    if (accept) {
      final hasSpace = await _storageService.hasSufficientSpace(offer.fileSize);
      if (!hasSpace) {
        final nativeRes = await _respondNative(offer, accept: false);
        if (nativeRes is NetworkSuccess<void>) {
          _committedDecisions[offer.transferId] = false;
          _pendingOffers.remove(offer.transferId);
          _offerTimers.remove(offer.transferId)?.cancel();
        }
        return _failure(
          code: NetworkErrorCode.resourceLimit,
          message: 'Insufficient storage space for incoming transfer.',
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        );
      }
    }

    final nativeResult = await _respondNative(offer, accept: accept);
    if (nativeResult is NetworkSuccess<void>) {
      _committedDecisions[offer.transferId] = accept;
      _pendingOffers.remove(offer.transferId);
      _offerTimers.remove(offer.transferId)?.cancel();
    }
    return nativeResult;
  }

  Future<NetworkResult<void>> _respondNative(
    IncomingTransferOffer offer, {
    required bool accept,
  }) async {
    try {
      return await _networkFacade.respondToIncomingTransfer(
        transferId: offer.transferId,
        accept: accept,
      );
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.respondToIncoming,
          peerId: offer.peerId,
        ),
      );
    }
  }

  Future<void> _expireOffer(IncomingTransferOffer offer) async {
    if (_disposed) return;
    final inFlight = _decisionOperations[offer.transferId];
    if (inFlight != null) {
      try {
        await inFlight.future;
      } catch (_) {}
    }
    if (!_disposed &&
        !_committedDecisions.containsKey(offer.transferId) &&
        _pendingOffers.containsKey(offer.transferId)) {
      await reject(offer);
    }
  }

  void _handleNetworkEvent(SdkEvent event) {
    if (_disposed) return;
    if (event case final IncomingTransferOffer offer) {
      unawaited(_processIncomingOffer(offer));
    }
    _updateRouteStateFromEvent(event);
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> _processIncomingOffer(IncomingTransferOffer offer) async {
    if (_disposed) return;
    final policyResult = await _policyPort.getPeerPolicy(offer.peerId);
    if (policyResult is NetworkFailure<LanPeerPolicySnapshot>) {
      await _respondNative(offer, accept: false);
      return;
    }
    final policy = (policyResult as NetworkSuccess<LanPeerPolicySnapshot>).data;
    if (!policy.isTrusted ||
        !isIncomingRouteAuthorized(
          policy.trust!.authorization,
          offer.routeType,
        )) {
      await _respondNative(offer, accept: false);
      return;
    }

    if (_committedDecisions.containsKey(offer.transferId)) {
      return;
    }
    final isNewOffer = !_pendingOffers.containsKey(offer.transferId);
    _pendingOffers[offer.transferId] = offer;
    _offerTimers[offer.transferId] ??= Timer(offerTimeout, () {
      unawaited(_expireOffer(offer));
    });
    if (isNewOffer && !_incomingOffers.isClosed) {
      _incomingOffers.add(offer);
    }
  }

  void _updateRouteStateFromEvent(SdkEvent event) {
    var changed = false;
    if (event case final PeerStateChanged stateEvent) {
      final current =
          _routeStates[stateEvent.peerId] ?? const LanPeerRouteState();
      final isOnline = stateEvent.state == PeerConnectionState.connected;
      final activeRoute = isOnline
          ? stateEvent.routeType
          : NetworkRouteType.unspecified;
      final updated = current.copyWith(
        activeRoute: activeRoute,
        directAvailable:
            stateEvent.routeType == NetworkRouteType.quicDirect ||
                stateEvent.routeType == NetworkRouteType.lan
            ? isOnline
            : current.directAvailable,
        relayAvailable: stateEvent.routeType == NetworkRouteType.relay
            ? isOnline
            : current.relayAvailable,
      );
      _routeStates[stateEvent.peerId] = updated;
      changed = true;
    } else if (event case final RouteChanged routeEvent) {
      final snap = routeEvent.snapshot;
      final current = _routeStates[snap.peerId] ?? const LanPeerRouteState();
      final isDirect =
          snap.routeType == NetworkRouteType.quicDirect ||
          snap.routeType == NetworkRouteType.lan;
      final isRelay = snap.routeType == NetworkRouteType.relay;
      final updated = current.copyWith(
        activeRoute: snap.routeType,
        endpoint: snap.endpoint,
        directAvailable: isDirect ? true : current.directAvailable,
        relayAvailable: isRelay ? true : current.relayAvailable,
      );
      _routeStates[snap.peerId] = updated;
      changed = true;
    } else if (event case final RelayStateChanged relayEvent) {
      if (relayEvent.state != RelayConnectionState.connected) {
        for (final entry in _routeStates.entries) {
          if (entry.value.relayAvailable) {
            _routeStates[entry.key] = entry.value.copyWith(
              relayAvailable: false,
            );
            changed = true;
          }
        }
      }
    } else if (event case final PeerPresenceChanged presenceEvent) {
      final current =
          _routeStates[presenceEvent.peerId] ?? const LanPeerRouteState();
      final isOnline =
          presenceEvent.state == PeerPresenceState.online ||
          presenceEvent.state == PeerPresenceState.updated;
      final updated = current.copyWith(relayAvailable: isOnline);
      _routeStates[presenceEvent.peerId] = updated;
      changed = true;
    } else if (event case final PeerPresenceSnapshot snapshotEvent) {
      final snapshotPeerIds = <String>{};
      for (final peer in snapshotEvent.peers) {
        snapshotPeerIds.add(peer.peerId);
        final current = _routeStates[peer.peerId] ?? const LanPeerRouteState();
        final isOnline =
            peer.state == PeerPresenceState.online ||
            peer.state == PeerPresenceState.updated;
        _routeStates[peer.peerId] = current.copyWith(relayAvailable: isOnline);
      }
      for (final entry in _routeStates.entries) {
        if (!snapshotPeerIds.contains(entry.key) &&
            entry.value.relayAvailable) {
          _routeStates[entry.key] = entry.value.copyWith(relayAvailable: false);
        }
      }
      changed = true;
    }

    if (changed && !_routeStateController.isClosed) {
      _routeStateController.add(
        Map<String, LanPeerRouteState>.unmodifiable(_routeStates),
      );
    }
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
