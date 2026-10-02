// LAN Control Protocol V2 客户端的配对、元数据和撤回操作。
// Binary files are sent by LanNativeTransferCoordinator through Network V2.
// 使用 part 文件与服务端实现分离，确保源码低于仓库 1000 行维护上限。

part of 'lan_transfer_service.dart';

/// 保存服务端返回且已通过绑定校验的配对凭据。
class _ValidatedPairingCredential {
  final String accessToken;
  final String certFingerprint;
  final String status;
  final Uint8List x25519PublicKey;
  final Uint8List networkIdentityPublicKey;

  const _ValidatedPairingCredential({
    required this.accessToken,
    required this.certFingerprint,
    required this.status,
    required this.x25519PublicKey,
    required this.networkIdentityPublicKey,
  });
}

/// 保存通过 SRP/TLS 校验且绑定 V2 静态身份的配对 offer。
class _AcceptedPairingOffer {
  final String handshakeId;
  final LanPairingSessionSecrets sessionSecrets;
  final String certFingerprint;
  final Uint8List serverX25519PublicKey;
  final Uint8List serverNetworkIdentityPublicKey;

  const _AcceptedPairingOffer({
    required this.handshakeId,
    required this.sessionSecrets,
    required this.certFingerprint,
    required this.serverX25519PublicKey,
    required this.serverNetworkIdentityPublicKey,
  });
}

final class _HandshakeConfirmStarted implements Exception {
  const _HandshakeConfirmStarted(this.cause);

  final Object cause;
}

bool _constantTimeBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

extension LanTransferClientApi on LanTransferService {
  Uri _lanEndpoint(LanDiscoveredPeer device, String path) {
    final rawHost = device.ip.trim();
    final host = rawHost.startsWith('[') && rawHost.endsWith(']')
        ? rawHost.substring(1, rawHost.length - 1)
        : rawHost;
    if (host.isEmpty ||
        host.length > 253 ||
        RegExp(r'[\x00-\x20/@?#\\\[\]]').hasMatch(host)) {
      throw const FormatException('LAN peer address is invalid.');
    }
    return Uri(
      scheme: 'https',
      host: host,
      port: device.controlPort,
      path: path,
    );
  }

  /// 创建配置为连接一个已配对对端的 HTTP 客户端。
  Future<HttpClient> createHttpClientForPeer(
    String peerDeviceId, {
    String? expectedFingerprint,
  }) {
    return _createHttpClient(
      peerDeviceId: peerDeviceId,
      expectedFingerprint: expectedFingerprint,
    );
  }

  /// 读取并限制 JSON 响应大小，不向上层暴露原始服务端细节。
  Future<Map<String, dynamic>> readBoundedJsonResponse(
    HttpClientResponse response, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await response
        .forEach((chunk) {
          total += chunk.length;
          if (total > LanTransferProtocolGuard.maxControlBodyBytes) {
            throw LanNetworkException('LAN response body is too large.');
          }
          bytes.add(chunk);
        })
        .timeout(timeout);
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map<String, dynamic>) {
      throw LanNetworkException('LAN response is not a JSON object.');
    }
    return decoded;
  }

  /// 添加所有配对后 LAN API 必需的配对专属凭据。
  Future<NetworkResult<void>> addPairingAuthorization(
    HttpHeaders headers,
    String peerDeviceId,
  ) async {
    final token = await securityService.getOutboundAccessToken(peerDeviceId);
    if (token == null || token.isEmpty) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.authenticationFailed,
          message: 'LAN pairing credentials are unavailable.',
          operation: NetworkOperation.authorizeLanRequest,
          peerId: peerDeviceId,
        ),
      );
    }
    headers.set('x-device-id', currentDeviceId);
    headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    return const NetworkSuccess<void>(null);
  }

  /// 校验配对凭据的会话、设备、请求摘要和有效期绑定。
  _ValidatedPairingCredential _validatePairingCredential(
    Map<String, dynamic> credential, {
    required String expectedNonce,
    required String expectedHandshakeId,
    required String expectedRequestHash,
    required String expectedIssuerDeviceId,
    required String expectedRecipientDeviceId,
    required Duration elapsed,
  }) {
    final protocolVersion = credential['protocolVersion'];
    final accessToken = credential['accessToken'];
    final fingerprint = credential['certFingerprint'];
    final status = credential['status'];
    final requestNonce = credential['requestNonce'];
    final handshakeId = credential['handshakeId'];
    final requestHash = credential['requestHash'];
    final issuerDeviceId = credential['issuerDeviceId'];
    final recipientDeviceId = credential['recipientDeviceId'];
    final encodedX25519PublicKey = credential['x25519PubKey'];
    final encodedNetworkIdentityPublicKey = credential['networkIdentityPubKey'];
    final validForMs = credential['validForMs'];

    if (protocolVersion != LanPairingCrypto.protocolVersion ||
        accessToken is! String ||
        accessToken.isEmpty ||
        accessToken.length > 256 ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fingerprint) ||
        status != 'paired' ||
        requestNonce != expectedNonce ||
        handshakeId != expectedHandshakeId ||
        requestHash != expectedRequestHash ||
        issuerDeviceId != expectedIssuerDeviceId ||
        recipientDeviceId != expectedRecipientDeviceId ||
        encodedX25519PublicKey is! String ||
        encodedNetworkIdentityPublicKey is! String ||
        validForMs is! int ||
        validForMs <= 0 ||
        validForMs > LanPairingCrypto.credentialTtlMillis ||
        elapsed.inMilliseconds > validForMs) {
      throw const FormatException(
        'Pairing response credential binding is invalid or expired',
      );
    }

    final x25519PublicKey = LanPairingCrypto.decodePublicKey(
      encodedX25519PublicKey,
      'peer X25519 public key',
    );
    final networkIdentityPublicKey = LanPairingCrypto.decodePublicKey(
      encodedNetworkIdentityPublicKey,
      'peer network identity public key',
    );
    return _ValidatedPairingCredential(
      accessToken: accessToken,
      certFingerprint: fingerprint,
      status: status as String,
      x25519PublicKey: x25519PublicKey,
      networkIdentityPublicKey: networkIdentityPublicKey,
    );
  }

  /// 为定向协议测试校验配对凭据绑定。
  @visibleForTesting
  bool isPairingCredentialBindingValidForTesting(
    Map<String, dynamic> credential, {
    required String expectedNonce,
    required String expectedHandshakeId,
    required String expectedRequestHash,
    required String expectedIssuerDeviceId,
    required String expectedRecipientDeviceId,
    Duration elapsed = Duration.zero,
  }) {
    try {
      _validatePairingCredential(
        credential,
        expectedNonce: expectedNonce,
        expectedHandshakeId: expectedHandshakeId,
        expectedRequestHash: expectedRequestHash,
        expectedIssuerDeviceId: expectedIssuerDeviceId,
        expectedRecipientDeviceId: expectedRecipientDeviceId,
        elapsed: elapsed,
      );
      return true;
    } catch (_) {
      return false;
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
  }) async {
    Object? lastError;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final result = await _sendHandshakeAttempt(
          device,
          pin,
          localAlias,
          isInitiator: isInitiator,
        );
        return result;
      } on _HandshakeConfirmStarted catch (started) {
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
    late final _AcceptedPairingOffer acceptedOffer;
    try {
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
      beginClient.close();
    }

    final confirmClient = await _createHttpClient(
      peerDeviceId: device.deviceId,
      expectedFingerprint: acceptedOffer.certFingerprint,
    );
    var confirmSent = false;
    try {
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
      confirmClient.close();
    }
  }

  /// 完成本地校验后接受远端配对邀请。
  /// 尝试解密并验证一个服务端配对 offer。
  Future<_AcceptedPairingOffer?> _acceptPairingOffer(
    Map<String, dynamic> offer, {
    required List<LanPairingEphemeralKeyPair> clientKeys,
    required String clientContext,
    required String serverFingerprint,
    required Uint8List serverX25519PublicKey,
    required Uint8List serverNetworkIdentityPublicKey,
  }) async {
    final handshakeId = offer['handshakeId'];
    final slot = offer['slot'];
    final saltB64 = offer['salt'];
    final serverPublicValueB64 = offer['serverPublicValue'];
    final serverProof = offer['serverProof'];
    if (handshakeId is! String ||
        handshakeId.length < 16 ||
        handshakeId.length > 128 ||
        slot is! int ||
        slot < 0 ||
        slot >= clientKeys.length ||
        saltB64 is! String ||
        saltB64.length > 128 ||
        serverPublicValueB64 is! String ||
        serverPublicValueB64.length > 1024 ||
        serverProof is! String ||
        serverProof.isEmpty ||
        serverProof.length > 256) {
      return null;
    }
    try {
      final keys = clientKeys[slot];
      final salt = base64.decode(saltB64);
      if (salt.length != 32 || !listEquals(salt, keys.salt)) {
        return null;
      }
      final serverPublicValue = base64.decode(serverPublicValueB64);
      if (serverPublicValue.length != LanPairingCrypto.publicValueBytes ||
          !LanPairingCrypto.isValidPublicValueForTesting(serverPublicValue)) {
        return null;
      }
      final associatedData = LanPairingCrypto.sessionAssociatedData(
        clientContext: clientContext,
        handshakeId: handshakeId,
        slot: slot,
        salt: salt,
        clientPublicValue: keys.publicValue,
        serverPublicValue: serverPublicValue,
        serverCertFingerprint: serverFingerprint,
        serverX25519PublicKey: serverX25519PublicKey,
        serverNetworkIdentityPublicKey: serverNetworkIdentityPublicKey,
      );
      final sessionSecrets = LanPairingCrypto.deriveSessionSecrets(
        localKeyPair: keys,
        remotePublicValue: serverPublicValue,
        associatedData: associatedData,
      );
      if (!LanPairingCrypto.verifyServerProof(sessionSecrets, serverProof)) {
        return null;
      }
      return _AcceptedPairingOffer(
        handshakeId: handshakeId,
        sessionSecrets: sessionSecrets,
        certFingerprint: serverFingerprint,
        serverX25519PublicKey: Uint8List.fromList(serverX25519PublicKey),
        serverNetworkIdentityPublicKey: Uint8List.fromList(
          serverNetworkIdentityPublicKey,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 在已认证 LAN 通道上发送元数据消息。
  Future<NetworkResult<void>> sendMeta(
    LanDiscoveredPeer device,
    LanMessage message, {
    Uint8List? recipientPubKeyBytes,
  }) async {
    return _executeWithRetry(
      () async {
        final url = _lanEndpoint(device, '/api/lan/meta');
        final client = await _createHttpClient(peerDeviceId: device.deviceId);

        try {
          final request = await client
              .postUrl(url)
              .timeout(const Duration(seconds: 4));
          request.followRedirects = false;
          final authorization = await addPairingAuthorization(
            request.headers,
            device.deviceId,
          );
          if (authorization is NetworkFailure<void>) {
            return authorization;
          }
          final payload = <String, dynamic>{
            ...message.toJson(),
            'localPath': null,
            'sftpServerId': null,
            'sftpRemotePath': null,
          };
          final jsonBytes = utf8.encode(jsonEncode(payload));

          if (recipientPubKeyBytes != null) {
            // E2E：加密元数据载荷。
            final encrypted = await securityService.encryptE2EFor(
              Uint8List.fromList(jsonBytes),
              recipientPubKeyBytes,
            );
            request.headers.set('x-e2e-pubkey', '1');
            request.headers.contentType = ContentType.binary;
            request.headers.contentLength = encrypted.length;
            request.add(encrypted);
          } else {
            request.headers.contentType = ContentType.json;
            request.add(jsonBytes);
          }

          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          final json = await readBoundedJsonResponse(response);
          if (response.statusCode != HttpStatus.ok) {
            throw lanHttpException(
              statusCode: response.statusCode,
              body: json,
              operation: NetworkOperation.sendMeta,
              peerId: device.deviceId,
              fallbackMessage: 'LAN metadata request was rejected.',
            );
          }
          if (json['id'] != message.id) {
            throw LanNetworkException(
              'LAN metadata response is invalid.',
              code: NetworkErrorCode.invalidArgument,
              operation: NetworkOperation.sendMeta,
              peerId: device.deviceId,
              statusCode: response.statusCode,
            );
          }
          return const NetworkSuccess<void>(null);
        } finally {
          client.close();
        }
      },
      peerId: device.deviceId,
      operation: NetworkOperation.sendMeta,
    );
  }

  /// 为之前发送的消息发送撤回信号。
  Future<NetworkResult<void>> sendRecall(
    LanDiscoveredPeer device,
    String messageId,
  ) async {
    return _executeWithRetry(
      () async {
        final url = _lanEndpoint(device, '/api/lan/recall');
        final client = await _createHttpClient(peerDeviceId: device.deviceId);

        try {
          final request = await client
              .postUrl(url)
              .timeout(const Duration(seconds: 4));
          request.followRedirects = false;
          final authorization = await addPairingAuthorization(
            request.headers,
            device.deviceId,
          );
          if (authorization is NetworkFailure<void>) {
            return authorization;
          }
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode({'messageId': messageId}));

          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          final json = await readBoundedJsonResponse(
            response,
            timeout: const Duration(seconds: 8),
          );
          if (response.statusCode != HttpStatus.ok) {
            throw lanHttpException(
              statusCode: response.statusCode,
              body: json,
              operation: NetworkOperation.sendRecall,
              peerId: device.deviceId,
              fallbackMessage: 'LAN recall request was rejected.',
            );
          }
          if (json['messageId'] != messageId) {
            throw LanNetworkException(
              'LAN recall response is invalid.',
              code: NetworkErrorCode.invalidArgument,
              operation: NetworkOperation.sendRecall,
              peerId: device.deviceId,
              statusCode: response.statusCode,
            );
          }
          return const NetworkSuccess<void>(null);
        } finally {
          client.close();
        }
      },
      peerId: device.deviceId,
      operation: NetworkOperation.sendRecall,
    );
  }

  /// 广播本机存在，并返回对端端点。
  Future<NetworkResult<LanPairingEndpoint>> sendAnnouncement(
    LanDiscoveredPeer targetDevice,
    String localAlias,
  ) async {
    return _executeWithRetry(
      () async {
        final url = _lanEndpoint(targetDevice, '/api/lan/announce');
        final client = await _createHttpClient(
          peerDeviceId: targetDevice.deviceId,
        );

        try {
          final request = await client
              .postUrl(url)
              .timeout(const Duration(seconds: 4));
          request.followRedirects = false;
          request.headers.contentType = ContentType.json;
          request.write(
            jsonEncode({
              'id': currentDeviceId,
              'alias': localAlias,
              'os': Platform.operatingSystem,
              'port': activePort,
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
              operation: NetworkOperation.sendAnnouncement,
              peerId: targetDevice.deviceId,
              fallbackMessage: 'LAN announcement was rejected.',
            );
          }
          final remoteDeviceId = json['deviceId'];
          final remotePort = json['port'];
          if (remoteDeviceId is! String ||
              remoteDeviceId.isEmpty ||
              remotePort is! num ||
              remotePort < 1 ||
              remotePort > 65535) {
            throw LanNetworkException(
              'LAN announcement response is invalid.',
              code: NetworkErrorCode.invalidArgument,
              operation: NetworkOperation.sendAnnouncement,
              peerId: targetDevice.deviceId,
              statusCode: response.statusCode,
            );
          }
          return NetworkSuccess(
            LanPairingEndpoint(
              remoteDeviceId: remoteDeviceId,
              remotePort: remotePort.toInt(),
            ),
          );
        } finally {
          client.close();
        }
      },
      peerId: targetDevice.deviceId,
      operation: NetworkOperation.sendAnnouncement,
    );
  }

  /// 邀请对端打开配对页面。PIN 握手仍是独立步骤，只有它可以建立信任。
  Future<NetworkResult<LanPairingEndpoint>> sendPairingInvite(
    LanDiscoveredPeer targetDevice,
    String localAlias, {
    required String sessionId,
    required DateTime expiresAt,
  }) async {
    final url = _lanEndpoint(targetDevice, '/api/lan/pairing_invite');
    final client = await _createHttpClient(
      peerDeviceId: targetDevice.deviceId,
      allowUntrusted: true,
    );
    try {
      final validForMs = expiresAt
          .difference(DateTime.now())
          .inMilliseconds
          .clamp(1, const Duration(minutes: 2).inMilliseconds);
      final request = await client
          .postUrl(url)
          .timeout(const Duration(seconds: 4));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'deviceId': currentDeviceId,
          'alias': localAlias,
          'os': Platform.operatingSystem,
          'port': activePort,
          'sessionId': sessionId,
          'validForMs': validForMs,
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
          operation: NetworkOperation.sendPairingInvite,
          peerId: targetDevice.deviceId,
          fallbackMessage: 'LAN pairing invitation was rejected.',
        );
      }
      final remoteDeviceId = json['deviceId'];
      final remotePort = json['port'];
      if (remoteDeviceId is! String ||
          remoteDeviceId.isEmpty ||
          remotePort is! num ||
          remotePort < 1 ||
          remotePort > 65535) {
        throw const FormatException('Invalid LAN pairing endpoint response.');
      }
      return NetworkSuccess(
        LanPairingEndpoint(
          remoteDeviceId: remoteDeviceId,
          remotePort: remotePort.toInt(),
        ),
      );
    } catch (e) {
      return NetworkFailure(
        lanNetworkError(
          e,
          operation: NetworkOperation.sendPairingInvite,
          peerId: targetDevice.deviceId,
        ),
      );
    } finally {
      client.close();
    }
  }

  /// 使用指数退避重试暂时性失败，最多重试 3 次。
  ///
  /// 尊重服务端建议的 [RetryDisposition]：`noRetry` 立即停止；`retryAfter` 使用
  /// 服务端建议秒数（上限 60s）作为延迟；其余保持既有 `retryable` 指数退避行为。
  Future<NetworkResult<T>> _executeWithRetry<T>(
    Future<NetworkResult<T>> Function() action, {
    int maxAttempts = 3,
    required NetworkOperation operation,
    String? peerId,
  }) async {
    NetworkFailure<T>? lastFailure;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final result = await action();
        if (result is NetworkSuccess<T>) return result;
        final failure = result as NetworkFailure<T>;
        lastFailure = failure;
        if (!failure.error.retryable || attempt == maxAttempts) {
          return failure;
        }
      } catch (e) {
        lastFailure = NetworkFailure(
          lanNetworkError(e, operation: operation, peerId: peerId),
        );
        if (attempt == maxAttempts || !lastFailure.error.retryable) {
          return lastFailure;
        }
      }
      if (attempt < maxAttempts) {
        await Future.delayed(_retryDelay(lastFailure.error, attempt));
      }
    }
    return lastFailure ??
        NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'LAN operation failed.',
            operation: operation,
            peerId: peerId,
          ),
        );
  }

  /// 根据服务端建议选择重试延迟；未建议时使用既有指数退避。
  Duration _retryDelay(NetworkError error, int attempt) {
    if (error.retryDisposition == RetryDisposition.retryAfter &&
        error.retryAfterSeconds > 0) {
      return Duration(seconds: error.retryAfterSeconds.clamp(1, 60));
    }
    return Duration(milliseconds: 500 * attempt);
  }
}
