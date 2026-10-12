// LAN Control Protocol V2 客户端的配对、元数据和撤回操作。
// Binary files are sent by LanNativeTransferCoordinator through Network V2.
// 使用 part 文件与服务端实现分离，保持控制请求与配对职责分离。

part of 'lan_transfer_service.dart';

extension LanTransferClientApi on LanTransferService {
  Uri _lanEndpoint(LanDiscoveredPeer device, String path) {
    device = resolvePeer(device);
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
