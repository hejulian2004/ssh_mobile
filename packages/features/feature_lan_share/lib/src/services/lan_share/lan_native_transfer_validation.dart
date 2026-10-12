part of 'lan_native_transfer_coordinator.dart';

extension LanNativeTransferValidation on LanNativeTransferCoordinator {
  Future<NetworkResult<void>> _prepareRealtimeConnection(
    String peerId,
    LanDiscoveredPeer? discovery,
  ) async {
    NetworkFailure<void> failure(NetworkErrorCode code, String message) =>
        NetworkFailure<void>(
          NetworkError(
            code: code,
            message: message,
            operation: NetworkOperation.connect,
            peerId: peerId,
          ),
        );
    if (_disposed) {
      return failure(
        NetworkErrorCode.cancelled,
        'Network coordinator is disposed.',
      );
    }
    if (discovery != null && discovery.deviceId != peerId) {
      return failure(
        NetworkErrorCode.invalidArgument,
        'Discovery identity does not match the selected peer.',
      );
    }
    final result = await _policyPort.getPeerPolicy(peerId);
    if (result is NetworkFailure<LanPeerPolicySnapshot>) {
      return NetworkFailure<void>(result.error);
    }
    final policy = (result as NetworkSuccess<LanPeerPolicySnapshot>).data;
    if (!policy.isTrusted || policy.runtimeBlocked || policy.revoked) {
      return failure(
        NetworkErrorCode.authenticationFailed,
        'Paired peer identity is unavailable.',
      );
    }
    final trust = policy.trust!;
    final reconcile = await _policyPort.reconcilePersistedTrust(trust);
    if (reconcile is NetworkFailure<void>) return reconcile;
    if (discovery != null) {
      if (!trust.authorization.localDirect) {
        return failure(
          NetworkErrorCode.noRoute,
          'Direct access is not authorized.',
        );
      }
      final capability = await _fetchCapabilities(discovery, trust);
      if (capability is NetworkFailure<_NativeCapability>) {
        await _policyPort.invalidateDirectEndpoint(peerId);
        return NetworkFailure<void>(capability.error);
      }
      final snapshot = (capability as NetworkSuccess<_NativeCapability>).data;
      final resolved = _transferService.resolvePeer(discovery);
      final updated = await _policyPort.updateDirectEndpoint(
        peerId,
        LanNativeTransferCoordinator._formatEndpoint(
          resolved.ip,
          snapshot.nativePort,
        ),
      );
      if (updated is NetworkFailure<void>) return updated;
    } else if (!trust.authorization.relay &&
        _routeStates[peerId]?.directAvailable != true) {
      return failure(
        NetworkErrorCode.noRoute,
        'No authenticated route is available.',
      );
    }
    try {
      return await _networkFacade.connectPeer(
        peerId,
        communicationClass: CommunicationClass.reliableMessage,
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

  Future<NetworkResult<TransferSession>?> _validateSourceFile(
    File file,
    String peerId,
  ) async {
    try {
      if (!await file.exists()) {
        return LanNativeTransferCoordinator._failure(
          code: NetworkErrorCode.ioError,
          message: 'Source file is unavailable.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        return LanNativeTransferCoordinator._failure(
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
        return LanNativeTransferCoordinator._failure(
          code: NetworkErrorCode.invalidArgument,
          message: 'Source file name is invalid.',
          operation: NetworkOperation.sendFile,
          peerId: peerId,
        );
      }
      return null;
    } catch (error) {
      return LanNativeTransferCoordinator._failure(
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
      device = _transferService.resolvePeer(device);
      client = await _transferService.createHttpClientForPeer(
        device.deviceId,
        expectedFingerprint: trust.certificateFingerprint,
      );
      final host = LanNativeTransferCoordinator._normalizeHost(device.ip);
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
      final x25519 = LanNativeTransferCoordinator._decodePublicKey(
        body['x25519PubKey'],
      );
      final identity = LanNativeTransferCoordinator._decodePublicKey(
        body['networkIdentityPubKey'],
      );
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
      final mappedPort = _transferService.resolveNativePort(device, nativePort);
      if (mappedPort == null) {
        throw const LanNetworkException(
          'Recipient native port mapping is stale.',
          code: NetworkErrorCode.noRoute,
          operation: NetworkOperation.fetchCapabilities,
        );
      }
      return NetworkSuccess(_NativeCapability(mappedPort));
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
}
