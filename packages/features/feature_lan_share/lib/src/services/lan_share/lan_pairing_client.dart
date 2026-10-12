part of 'lan_transfer_service.dart';

extension LanPairingClient on LanTransferService {
  /// Terminates PIN verification without removing existing trust or runtime.
  void cancelPairingAuthentication(String peerId) {
    _peerPairingEpochs[peerId] = (_peerPairingEpochs[peerId] ?? 0) + 1;
    _discardReciprocalPairing(peerId);
    _pendingPairingHandshakes.removeWhere(
      (_, entry) => entry.senderDeviceId == peerId,
    );
    for (final client
        in _pairingHttpClients[peerId]?.toList() ?? <HttpClient>[]) {
      client.close(force: true);
    }
  }

  /// 发送 V2 握手请求，并校验配对 PIN 响应。
  ///
  /// 单方向成功返回 [LanPairingHandshakeProgress.waitingForPeer]，
  /// 双方证明指向同一对端后才返回 [LanPairingHandshakeProgress.paired]。
  Future<NetworkResult<LanPairingHandshakeProgress>> sendHandshake(
    LanDiscoveredPeer device,
    String pin,
    String localAlias, {
    bool isInitiator = true,
  }) {
    if (_outboundPairingOperations[device.deviceId]?.isNotEmpty == true) {
      return Future.value(
        NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.invalidState,
            message: 'PIN verification is already connecting.',
            operation: NetworkOperation.sendHandshake,
            peerId: device.deviceId,
          ),
        ),
      );
    }
    final operation = _sendHandshake(
      device,
      pin,
      localAlias,
      isInitiator: isInitiator,
    );
    final pending = _outboundPairingOperations.putIfAbsent(
      device.deviceId,
      () => {},
    );
    pending.add(operation);
    return operation.whenComplete(() {
      pending.remove(operation);
      if (pending.isEmpty) {
        _outboundPairingOperations.remove(device.deviceId);
        _pairingHttpClients.remove(device.deviceId);
      }
    });
  }

  Future<NetworkResult<LanPairingHandshakeProgress>> _sendHandshake(
    LanDiscoveredPeer device,
    String pin,
    String localAlias, {
    bool isInitiator = true,
  }) async {
    final generation = _peerPairingEpochs[device.deviceId] ?? 0;
    Object? lastError;
    for (int attempt = 1; attempt <= 3; attempt++) {
      if (_closing ||
          _closed ||
          generation != (_peerPairingEpochs[device.deviceId] ?? 0)) {
        return _cancelledPairing(device.deviceId);
      }
      try {
        final result = await _sendHandshakeAttempt(
          device,
          pin,
          localAlias,
          isInitiator: isInitiator,
        );
        return result;
      } on _HandshakeConfirmStarted catch (started) {
        if (generation != (_peerPairingEpochs[device.deviceId] ?? 0)) {
          return _cancelledPairing(device.deviceId);
        }
        // The peer may already have stored this attempt's tokens.
        return NetworkFailure(
          lanNetworkError(
            started.cause,
            operation: NetworkOperation.sendHandshake,
            peerId: device.deviceId,
          ),
        );
      } catch (e) {
        lastError = lanNetworkError(
          e,
          operation: NetworkOperation.sendHandshake,
          peerId: device.deviceId,
        );
      }

      if (_closing ||
          _closed ||
          generation != (_peerPairingEpochs[device.deviceId] ?? 0)) {
        return _cancelledPairing(device.deviceId);
      }

      if (attempt < 3) {
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }

    if (lastError is NetworkError) {
      return NetworkFailure(lastError);
    }
    return NetworkFailure(
      NetworkError(
        code: NetworkErrorCode.ioError,
        message: 'LAN handshake failed.',
        operation: NetworkOperation.sendHandshake,
        peerId: device.deviceId,
      ),
    );
  }

  /// 执行一次 V2 配对握手尝试。
  Future<NetworkResult<LanPairingHandshakeProgress>> _sendHandshakeAttempt(
    LanDiscoveredPeer device,
    String pin,
    String localAlias, {
    required bool isInitiator,
  }) async {
    final epoch = _peerPairingEpochs[device.deviceId] ?? 0;
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.invalidArgument,
          message: 'LAN pairing PIN format is invalid.',
          operation: NetworkOperation.sendHandshake,
          peerId: device.deviceId,
        ),
      );
    }
    final url = _lanEndpoint(device, '/api/lan/handshake');
    final nonce = LanPairingCrypto.randomToken();
    final localFingerprint =
        (await securityService.getLocalCertificateFingerprint(
          currentDeviceId,
        )).toLowerCase();
    final localX25519PublicKey = await securityService
        .getStaticX25519PublicKeyBytes();
    final providedLocalNetworkIdentityPublicKey =
        await networkIdentityPublicKeyProvider?.call();
    if (providedLocalNetworkIdentityPublicKey == null ||
        providedLocalNetworkIdentityPublicKey.length != 32) {
      throw StateError('LAN network identity is unavailable.');
    }
    final localNetworkIdentityPublicKey = Uint8List.fromList(
      providedLocalNetworkIdentityPublicKey,
    );
    if (_closing ||
        _closed ||
        epoch != (_peerPairingEpochs[device.deviceId] ?? 0)) {
      return _cancelledPairing(device.deviceId);
    }
    final localInboundAccessToken = securityService.createPairingAccessToken();
    final clientContext = LanPairingCrypto.clientContext(
      senderDeviceId: currentDeviceId,
      targetDeviceId: device.deviceId,
      nonce: nonce,
      alias: localAlias,
      os: Platform.operatingSystem,
      port: activePort,
      isInitiator: isInitiator,
      senderCertFingerprint: localFingerprint,
      senderX25519PublicKey: localX25519PublicKey,
      senderNetworkIdentityPublicKey: localNetworkIdentityPublicKey,
      senderInboundAccessTokenHash: LanPairingCrypto.accessTokenHash(
        localInboundAccessToken,
      ),
    );
    final clientKeys = List<LanPairingEphemeralKeyPair>.generate(
      LanPairingCrypto.maxServerOffers,
      (slot) => LanPairingCrypto.generateClientKeyPair(
        pin: pin,
        clientContext: clientContext,
        slot: slot,
      ),
      growable: false,
    );
    final encodedClientPublicValues = clientKeys
        .map((keys) => base64.encode(keys.publicValue))
        .toList(growable: false);
    final stopwatch = Stopwatch()..start();

    final beginClient = await _createHttpClient(
      peerDeviceId: device.deviceId,
      allowUntrusted: true,
    );
    final clients = _pairingHttpClients.putIfAbsent(device.deviceId, () => {});
    clients.add(beginClient);
    late final _AcceptedPairingOffer acceptedOffer;
    try {
      if (epoch != (_peerPairingEpochs[device.deviceId] ?? 0)) {
        return _cancelledPairing(device.deviceId);
      }
      final request = await beginClient
          .postUrl(url)
          .timeout(const Duration(seconds: 4));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'protocolVersion': LanPairingCrypto.protocolVersion,
          'phase': 'begin',
          'deviceId': currentDeviceId,
          'targetDeviceId': device.deviceId,
          'alias': localAlias,
          'os': Platform.operatingSystem,
          'port': activePort,
          'isInitiator': isInitiator,
          'nonce': nonce,
          'certFingerprint': localFingerprint,
          'x25519PubKey': base64UrlEncode(localX25519PublicKey),
          'networkIdentityPubKey': base64UrlEncode(
            localNetworkIdentityPublicKey,
          ),
          'inboundAccessTokenHash': LanPairingCrypto.accessTokenHash(
            localInboundAccessToken,
          ),
          'clientPublicValues': encodedClientPublicValues,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final json = await readBoundedJsonResponse(response);
      if (response.statusCode != HttpStatus.ok) {
        throw lanHttpException(
          statusCode: response.statusCode,
          body: json,
          operation: NetworkOperation.sendHandshake,
          peerId: device.deviceId,
          fallbackMessage: 'LAN pairing challenge was rejected.',
        );
      }
      if (json['protocolVersion'] != LanPairingCrypto.protocolVersion) {
        throw LanNetworkException(
          'LAN pairing challenge protocol is invalid.',
          code: NetworkErrorCode.invalidArgument,
          operation: NetworkOperation.sendHandshake,
          peerId: device.deviceId,
          statusCode: response.statusCode,
        );
      }
      final serverFingerprint = json['certFingerprint'];
      final encodedServerX25519Key = json['x25519PubKey'];
      final encodedServerNetworkIdentityKey = json['networkIdentityPubKey'];
      final validForMs = json['validForMs'];
      final offers = json['offers'];
      if (serverFingerprint is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(serverFingerprint) ||
          encodedServerX25519Key is! String ||
          encodedServerNetworkIdentityKey is! String ||
          validForMs is! int ||
          validForMs <= 0 ||
          validForMs > LanPairingCrypto.credentialTtlMillis ||
          stopwatch.elapsedMilliseconds > validForMs ||
          offers is! List<dynamic> ||
          offers.isEmpty ||
          offers.length > LanPairingCrypto.maxServerOffers) {
        throw const FormatException('Invalid LAN pairing challenge');
      }
      final normalizedFingerprint = serverFingerprint.toLowerCase();
      final serverX25519PublicKey = LanPairingCrypto.decodePublicKey(
        encodedServerX25519Key,
        'server X25519 public key',
      );
      final serverNetworkIdentityPublicKey = LanPairingCrypto.decodePublicKey(
        encodedServerNetworkIdentityKey,
        'server network identity public key',
      );
      final advertisedFingerprint =
          (await securityService.getPeerCertificateFingerprint(
            device.deviceId,
          ))?.toLowerCase();
      if (advertisedFingerprint != null &&
          advertisedFingerprint.isNotEmpty &&
          advertisedFingerprint != normalizedFingerprint) {
        throw const FormatException('LAN pairing certificate changed');
      }
      _AcceptedPairingOffer? selected;
      for (final rawOffer in offers) {
        if (rawOffer is! Map<String, dynamic>) continue;
        final candidate = await _acceptPairingOffer(
          rawOffer,
          clientKeys: clientKeys,
          clientContext: clientContext,
          serverFingerprint: normalizedFingerprint,
          serverX25519PublicKey: serverX25519PublicKey,
          serverNetworkIdentityPublicKey: serverNetworkIdentityPublicKey,
        );
        if (candidate != null) {
          selected = candidate;
          break;
        }
      }
      if (selected == null) {
        return NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.authenticationFailed,
            message: 'LAN pairing authentication failed.',
            operation: NetworkOperation.sendHandshake,
            peerId: device.deviceId,
          ),
        );
      }
      acceptedOffer = selected;
    } finally {
      beginClient.close(force: true);
      clients.remove(beginClient);
    }

    final confirmClient = await _createHttpClient(
      peerDeviceId: device.deviceId,
      expectedFingerprint: acceptedOffer.certFingerprint,
    );
    clients.add(confirmClient);
    var confirmSent = false;
    try {
      if (epoch != (_peerPairingEpochs[device.deviceId] ?? 0)) {
        return _cancelledPairing(device.deviceId);
      }
      final request = await confirmClient
          .postUrl(url)
          .timeout(const Duration(seconds: 4));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      final credentialAssociatedData =
          LanPairingCrypto.credentialAssociatedData(
            handshakeId: acceptedOffer.handshakeId,
            nonce: nonce,
            issuerDeviceId: currentDeviceId,
            recipientDeviceId: device.deviceId,
          );
      final encryptedInboundCredential =
          await LanPairingCrypto.encryptCredential(
            {'inboundAccessToken': localInboundAccessToken},
            acceptedOffer.sessionSecrets.sessionKey,
            associatedData: credentialAssociatedData,
          );
      request.write(
        jsonEncode({
          'protocolVersion': LanPairingCrypto.protocolVersion,
          'phase': 'confirm',
          'handshakeId': acceptedOffer.handshakeId,
          'deviceId': currentDeviceId,
          'targetDeviceId': device.deviceId,
          'nonce': nonce,
          'credential': encryptedInboundCredential,
          'clientProof': LanPairingCrypto.createClientProof(
            acceptedOffer.sessionSecrets,
          ),
        }),
      );
      confirmSent = true;
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final json = await readBoundedJsonResponse(response);
      if (response.statusCode != HttpStatus.ok) {
        // Only an explicit proof failure drops the opposite direction.
        // A stale confirm leaves that proof in place on the peer.
        if (json['discardPairingProofs'] == true) {
          _discardReciprocalPairing(device.deviceId);
        }
        throw lanHttpException(
          statusCode: response.statusCode,
          body: json,
          operation: NetworkOperation.sendHandshake,
          peerId: device.deviceId,
          fallbackMessage: 'LAN pairing confirmation was rejected.',
        );
      }
      final encryptedCredential = json['credential'];
      if (encryptedCredential is! String || encryptedCredential.isEmpty) {
        throw const FormatException(
          'Pairing response omitted its encrypted credential',
        );
      }
      final associatedData = LanPairingCrypto.credentialAssociatedData(
        handshakeId: acceptedOffer.handshakeId,
        nonce: nonce,
        issuerDeviceId: device.deviceId,
        recipientDeviceId: currentDeviceId,
      );
      final credential = await LanPairingCrypto.decryptCredential(
        encryptedCredential,
        acceptedOffer.sessionSecrets.sessionKey,
        associatedData: associatedData,
      );
      final requestHash = LanPairingCrypto.requestHash(clientContext);
      final validatedCredential = _validatePairingCredential(
        credential,
        expectedNonce: nonce,
        expectedHandshakeId: acceptedOffer.handshakeId,
        expectedRequestHash: requestHash,
        expectedIssuerDeviceId: device.deviceId,
        expectedRecipientDeviceId: currentDeviceId,
        elapsed: stopwatch.elapsed,
      );
      if (validatedCredential.certFingerprint.toLowerCase() !=
          acceptedOffer.certFingerprint) {
        throw const FormatException('LAN pairing certificate changed');
      }
      if (!_constantTimeBytesEqual(
            validatedCredential.x25519PublicKey,
            acceptedOffer.serverX25519PublicKey,
          ) ||
          !_constantTimeBytesEqual(
            validatedCredential.networkIdentityPublicKey,
            acceptedOffer.serverNetworkIdentityPublicKey,
          )) {
        throw const FormatException('LAN pairing identity changed');
      }
      // Tokens stay in memory until the opposite PIN direction verifies the
      // same peer. Network timeouts above do not reach this write.
      final proof = LanPairingDirectionProof(
        peerDeviceId: device.deviceId,
        initiatorDeviceId: currentDeviceId,
        certificateFingerprint: acceptedOffer.certFingerprint,
        x25519PublicKey: validatedCredential.x25519PublicKey,
        networkIdentityPublicKey: validatedCredential.networkIdentityPublicKey,
        inboundAccessToken: localInboundAccessToken,
        outboundAccessToken: validatedCredential.accessToken,
        alias: device.alias,
        ip: device.ip,
        controlPort: device.controlPort,
        os: device.os,
        notedAt: DateTime.now(),
      );
      if (_closing ||
          _closed ||
          epoch != (_peerPairingEpochs[device.deviceId] ?? 0)) {
        return _cancelledPairing(device.deviceId);
      }
      final update = _reciprocalPairing.noteOutbound(proof);
      try {
        final progress = await _applyReciprocalUpdate(
          update: update,
          observed: proof,
        );
        if (progress == null) {
          return NetworkFailure(
            NetworkError(
              code: NetworkErrorCode.authenticationFailed,
              message: 'LAN pairing authentication failed.',
              operation: NetworkOperation.sendHandshake,
              peerId: device.deviceId,
            ),
          );
        }
        return NetworkSuccess(progress);
      } on StateError {
        _discardReciprocalPairing(device.deviceId);
        return NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.identityConflict,
            message:
                'The device certificate changed. Unpair the device before re-pairing.',
            operation: NetworkOperation.sendHandshake,
            peerId: device.deviceId,
          ),
        );
      }
    } catch (error) {
      if (confirmSent) throw _HandshakeConfirmStarted(error);
      rethrow;
    } finally {
      confirmClient.close(force: true);
      clients.remove(confirmClient);
    }
  }
}
