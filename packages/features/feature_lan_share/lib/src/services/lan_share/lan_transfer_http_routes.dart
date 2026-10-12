part of 'lan_transfer_service.dart';

extension LanTransferHttpRoutes on LanTransferService {
  /// 处理一个 LAN HTTP 请求并写入规范化安全响应。
  Future<void> _handleHttpRequest(HttpRequest request) async {
    final path = request.uri.path;
    try {
      if (_closing || _closed) {
        throw const LanHttpException(
          HttpStatus.serviceUnavailable,
          'LAN transfer service is shutting down.',
        );
      }
      if (request.method == 'POST' && path == '/api/lan/handshake') {
        await _handleSecureHandshakeRequest(request);
      } else if (request.method == 'GET' && path == '/api/lan/ws') {
        await _handleWebSocketUpgrade(request);
      } else if (request.method == 'GET' && path == '/api/lan/check_pair') {
        await _handleCheckPairRequest(request);
      } else if (request.method == 'POST' && path == '/api/lan/announce') {
        await _handleAnnounceRequest(request);
      } else if (request.method == 'POST' &&
          path == '/api/lan/pairing_invite') {
        await _handlePairingInviteRequest(request);
      } else if (request.method == 'GET' && path == '/api/lan/capabilities') {
        await _handleCapabilitiesRequest(request);
      } else if (request.method == 'POST' && path == '/api/lan/meta') {
        await _handleMetaRequest(request);
      } else if (request.method == 'POST' && path == '/api/lan/recall') {
        await _handleRecallRequest(request);
      } else {
        throw const LanHttpException(
          HttpStatus.notFound,
          'LAN endpoint not found.',
        );
      }
    } on LanHttpException catch (error) {
      try {
        request.response.statusCode = error.statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'code': _httpErrorCode(error.statusCode).wireValue,
            'message': error.message,
            'operation': _operationForPath(path).wireName,
            if (error.discardPairingProofs) 'discardPairingProofs': true,
            if (request.headers.value('x-device-id') case final peerId?
                when peerId.isNotEmpty)
              'peer_id': peerId,
          }),
        );
        await request.response.close();
      } catch (_) {}
    } catch (error) {
      debugPrint(
        '[LanTransferService] Error handling request $path: '
        'errorType=${error.runtimeType}',
      );
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'code': NetworkErrorCode.ioError.wireValue,
            'message': 'LAN request failed.',
            'operation': _operationForPath(path).wireName,
            if (request.headers.value('x-device-id') case final peerId?
                when peerId.isNotEmpty)
              'peer_id': peerId,
          }),
        );
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 将 HTTP 状态映射为稳定的 LAN 错误码。
  NetworkErrorCode _httpErrorCode(int statusCode) {
    if (statusCode == HttpStatus.badRequest ||
        statusCode == HttpStatus.requestEntityTooLarge) {
      return NetworkErrorCode.invalidArgument;
    }
    if (statusCode == HttpStatus.unauthorized ||
        statusCode == HttpStatus.forbidden ||
        statusCode == HttpStatus.upgradeRequired) {
      return NetworkErrorCode.authenticationFailed;
    }
    if (statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.gatewayTimeout) {
      return NetworkErrorCode.timeout;
    }
    if (statusCode == HttpStatus.notFound) {
      return NetworkErrorCode.noRoute;
    }
    return NetworkErrorCode.ioError;
  }

  /// 返回 HTTP 端点路径对应的稳定操作名称。
  NetworkOperation _operationForPath(String path) {
    return switch (path) {
      '/api/lan/handshake' => NetworkOperation.sendHandshake,
      '/api/lan/ws' => NetworkOperation.connectWebSocket,
      '/api/lan/check_pair' => NetworkOperation.checkPair,
      '/api/lan/announce' => NetworkOperation.sendAnnouncement,
      '/api/lan/pairing_invite' => NetworkOperation.sendPairingInvite,
      '/api/lan/capabilities' => NetworkOperation.readCapabilities,
      '/api/lan/meta' => NetworkOperation.sendMeta,
      '/api/lan/recall' => NetworkOperation.sendRecall,
      _ => NetworkOperation.lanRequest,
    };
  }

  /// 提供端点专属的原生能力数据。
  Future<void> _handleCapabilitiesRequest(HttpRequest request) async {
    await _protocolGuard.authorize(request);
    final pubKeyBytes = await securityService.getStaticX25519PublicKeyBytes();
    final networkIdentityKey = await networkIdentityPublicKeyProvider?.call();
    final nativeTransferPort = nativeTransferPortProvider?.call();
    final nativeTransferReady =
        networkIdentityKey != null &&
        nativeTransferPort != null &&
        nativeTransferPort >= 1 &&
        nativeTransferPort <= 65535;
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'protocolVersion': LanControlProtocol.version,
        'e2eEncryption': LanSecurityService.supportsE2EEncryption,
        'x25519PubKey': base64.encode(pubKeyBytes),
        if (networkIdentityKey != null)
          'networkIdentityPubKey': base64.encode(networkIdentityKey),
        'quicFileTransfer': nativeTransferReady,
        if (nativeTransferReady) 'quicPort': nativeTransferPort,
      }),
    );
    await request.response.close();
  }
}
