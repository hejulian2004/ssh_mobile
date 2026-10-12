part of 'lan_transfer_service.dart';

extension LanTransferWebSockets on LanTransferService {
  /// 确认已认证调用方正在检查自身配对状态。
  Future<void> _handleCheckPairRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final requestedDeviceId = request.uri.queryParameters['deviceId'] ?? '';
    if (requestedDeviceId != senderDeviceId) {
      throw const LanHttpException(
        HttpStatus.forbidden,
        'Pairing identity does not match.',
      );
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'paired': true}));
    await request.response.close();
  }

  /// 认证 LAN 请求并将其升级为 WebSocket。
  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'LAN WebSocket upgrade is required.',
      );
    }

    final deviceId = await _protocolGuard.authorize(request);
    if (request.uri.queryParameters['deviceId'] != deviceId) {
      throw const LanHttpException(
        HttpStatus.forbidden,
        'Pairing identity does not match.',
      );
    }

    try {
      final socket = await WebSocketTransformer.upgrade(request);
      if (_closing || _closed) {
        await socket.close();
        throw const LanHttpException(
          HttpStatus.serviceUnavailable,
          'LAN transfer service is shutting down.',
        );
      }
      _registerActiveWebSocket(deviceId, socket);
    } on LanHttpException {
      rethrow;
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.internalServerError,
        'LAN WebSocket upgrade failed.',
      );
    }
  }

  Future<NetworkResult<void>> _connectWebSocket(LanDiscoveredPeer peer) async {
    final epoch = _peerPairingEpochs[peer.deviceId] ?? 0;
    final url = Uri(
      scheme: 'wss',
      host: peer.ip,
      port: peer.controlPort,
      path: '/api/lan/ws',
      queryParameters: {'deviceId': currentDeviceId},
    );

    try {
      final token = await securityService.getOutboundAccessToken(peer.deviceId);
      if (token == null || token.isEmpty) {
        return NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.authenticationFailed,
            message: 'LAN pairing credentials are unavailable.',
            operation: NetworkOperation.connectWebSocket,
            peerId: peer.deviceId,
          ),
        );
      }
      final client = await _createHttpClient(peerDeviceId: peer.deviceId);
      WebSocket? openedSocket;
      try {
        openedSocket = await WebSocket.connect(
          url.toString(),
          headers: {
            'x-device-id': currentDeviceId,
            HttpHeaders.authorizationHeader: 'Bearer $token',
          },
          customClient: client,
        ).timeout(const Duration(seconds: 4));
      } finally {
        client.close(force: openedSocket == null);
      }
      final socket = openedSocket;
      if (_closing ||
          _closed ||
          epoch != (_peerPairingEpochs[peer.deviceId] ?? 0)) {
        await socket.close();
        return NetworkFailure(
          lanNetworkError(
            StateError('LAN transfer service is closed.'),
            operation: NetworkOperation.connectWebSocket,
            peerId: peer.deviceId,
          ),
        );
      }
      _registerActiveWebSocket(peer.deviceId, socket);
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.connectWebSocket,
          peerId: peer.deviceId,
        ),
      );
    }
  }

  /// 注册 socket，并发布类型化的已连接事件。
  bool _registerActiveWebSocket(String deviceId, WebSocket socket) {
    if (_closing || _closed) {
      unawaited(socket.close());
      return false;
    }
    socket.pingInterval = const Duration(seconds: 5);
    _trackedWebSockets.add(socket);
    final previousSocket = _activeWebSockets[deviceId];
    _activeWebSockets[deviceId] = socket;
    if (previousSocket != null && !identical(previousSocket, socket)) {
      unawaited(_closeTrackedWebSocket(previousSocket));
    }

    _emit(
      _connectionStateController,
      LanConnectionStateChanged(deviceId: deviceId, connected: true),
    );

    socket.listen(
      (data) {},
      onError: (e) {
        debugPrint(
          '[LanTransferService] WebSocket failed: '
          'errorType=${e.runtimeType}',
        );
        _unregisterActiveWebSocket(deviceId, socket);
      },
      onDone: () {
        debugPrint('[LanTransferService] WebSocket disconnected for $deviceId');
        _unregisterActiveWebSocket(deviceId, socket);
      },
      cancelOnError: true,
    );
    return true;
  }

  /// 仅当 socket 仍是该对端的活跃 socket 时移除它。
  void _unregisterActiveWebSocket(String deviceId, WebSocket socket) {
    if (identical(_activeWebSockets[deviceId], socket)) {
      _activeWebSockets.remove(deviceId);
      _emit(
        _connectionStateController,
        LanConnectionStateChanged(deviceId: deviceId, connected: false),
      );
    }
    unawaited(_closeTrackedWebSocket(socket));
  }

  Future<void> _closeTrackedWebSocket(WebSocket socket) async {
    try {
      await socket.close();
    } catch (_) {
    } finally {
      _trackedWebSockets.remove(socket);
    }
  }
}
