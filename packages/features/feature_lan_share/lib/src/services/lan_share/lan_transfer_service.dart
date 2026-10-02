// LAN HTTPS control, WebSocket, pairing and text-message service.
//
// 服务向调用方暴露类型化网络结果，同时将端点专属 HTTP 实现限制在本库内。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'lan_security_service.dart';
import 'lan_network_models.dart';
import 'lan_pairing_crypto.dart';
import 'lan_pairing_reciprocal.dart';
import 'lan_share_models.dart';
import 'lan_storage_service.dart';
import 'lan_transfer_protocol.dart';
import 'package:network_sdk/network_sdk.dart';

part 'lan_transfer_client.dart';
part 'lan_pairing_server.dart';
part 'lan_pairing_confirm.dart';

/// Manages LAN HTTPS control metadata, WebSocket and RECALL signals.
///
/// Binary files are intentionally excluded; [LanNativeTransferCoordinator]
/// owns their Network V2 data plane.
class LanTransferService {
  static const int defaultHttpPort = 53317;

  /// 主端口被占用时按顺序尝试的备用端口。
  static const List<int> httpPortCandidates = [
    53317,
    53320,
    53325,
    53330,
    53335,
  ];
  static const int chunkSize = 512 * 1024; // 512 KB 流式缓冲区。

  final String currentDeviceId;
  final LanSecurityService securityService;
  final LanStorageService storageService;
  final Future<Uint8List> Function()? networkIdentityPublicKeyProvider;
  final int? Function()? nativeTransferPortProvider;
  late final LanTransferProtocolGuard _protocolGuard;

  HttpServer? _server;
  bool _isListening = false;
  bool _closing = false;
  bool _closed = false;
  Future<void>? _closeFuture;
  Future<NetworkResult<int>>? _startListeningFuture;
  Future<NetworkResult<void>>? _stopListeningFuture;

  /// LAN HTTPS 监听器当前是否已绑定。
  bool get isListening => _isListening;

  final Map<String, WebSocket> _activeWebSockets = {};
  final Set<WebSocket> _trackedWebSockets = {};
  final Map<String, Future<NetworkResult<void>>> _webSocketConnectAttempts = {};
  final Set<Future<void>> _requestOperations = {};
  final Map<String, _PendingPairingHandshake> _pendingPairingHandshakes = {};
  final LanReciprocalPairingGate _reciprocalPairing =
      LanReciprocalPairingGate();
  final _connectionStateController =
      StreamController<LanConnectionStateChanged>.broadcast();

  /// 发布类型化 WebSocket 连接变化。
  Stream<LanConnectionStateChanged> get connectionStateStream =>
      _connectionStateController.stream;

  final _incomingMessageController = StreamController<LanMessage>.broadcast();
  final _messageProgressController = StreamController<LanMessage>.broadcast();
  final _recalledMessageIdController =
      StreamController<LanRecallRequest>.broadcast();
  final _handshakeSuccessController =
      StreamController<LanDiscoveredPeer>.broadcast();
  final _announcedPeerController =
      StreamController<LanDiscoveredPeer>.broadcast();
  final _pairingInviteController =
      StreamController<LanPairingRequest>.broadcast();
  final _observedPeerController =
      StreamController<LanDiscoveredPeer>.broadcast();
  final _pairingDirectionController =
      StreamController<LanPairingDirectionNotice>.broadcast();

  /// 使用安全与存储依赖创建 LAN 传输服务。
  LanTransferService({
    required this.currentDeviceId,
    required this.securityService,
    required this.storageService,
    this.networkIdentityPublicKeyProvider,
    this.nativeTransferPortProvider,
  }) {
    _protocolGuard = LanTransferProtocolGuard(
      currentDeviceId: currentDeviceId,
      securityService: securityService,
    );
  }

  /// 发布收到的元数据和传输消息。
  Stream<LanMessage> get incomingMessageStream =>
      _incomingMessageController.stream;

  /// 发布收到的传输进度消息。
  Stream<LanMessage> get messageProgressStream =>
      _messageProgressController.stream;

  /// 发布已配对对端发来的撤回请求。
  Stream<LanRecallRequest> get recalledMessageIdStream =>
      _recalledMessageIdController.stream;

  /// 发布握手成功的传入设备。
  Stream<LanDiscoveredPeer> get handshakeSuccessPeerStream =>
      _handshakeSuccessController.stream;

  /// 发布在 LAN 上广播的设备。
  Stream<LanDiscoveredPeer> get announcedPeerStream =>
      _announcedPeerController.stream;

  /// 发布收到的配对邀请。
  Stream<LanPairingRequest> get pairingInviteStream =>
      _pairingInviteController.stream;

  /// 发布握手证明观察到的对端，供发现表刷新 lastSeen。
  Stream<LanDiscoveredPeer> get observedPeerStream =>
      _observedPeerController.stream;

  /// 发布某一方向 PIN 已验证、但信任尚未提交的进度。
  Stream<LanPairingDirectionNotice> get pairingDirectionStream =>
      _pairingDirectionController.stream;

  /// 返回 [peerId] 当前未过期的双向 PIN 进度。
  LanPairingDirectionNotice? pairingDirectionFor(String peerId) {
    return _reciprocalPairing.noticeFor(peerId);
  }

  /// 是否仍有未过期的单向配对证明，需要保活发现记录。
  bool hasPendingPairing(String peerId) =>
      _reciprocalPairing.hasPending(peerId);

  /// 返回已绑定监听端口；绑定前返回默认端口。
  int get activePort => _server?.port ?? defaultHttpPort;

  /// native runtime 已配置时返回独立的可靠传输端口。
  int? get activeNativeTransferPort => nativeTransferPortProvider?.call();

  /// 启动接收 LAN 传输的 HTTPS 服务。
  /// 按 [httpPortCandidates] 顺序尝试，直到一个端口绑定成功。
  Future<NetworkResult<int>> startListening({int port = defaultHttpPort}) {
    if (_closing || _closed) {
      return Future.value(
        NetworkFailure<int>(
          lanNetworkError(
            StateError('LAN transfer service is closed.'),
            operation: NetworkOperation.startLanListener,
          ),
        ),
      );
    }
    final activeStop = _stopListeningFuture;
    if (activeStop != null) {
      return activeStop.then((_) => startListening(port: port));
    }
    if (_isListening) {
      return Future.value(NetworkSuccess<int>(_server!.port));
    }
    final activeStart = _startListeningFuture;
    if (activeStart != null) return activeStart;
    late final Future<NetworkResult<int>> start;
    start = _startListening(port).whenComplete(() {
      if (identical(_startListeningFuture, start)) {
        _startListeningFuture = null;
      }
    });
    _startListeningFuture = start;
    return start;
  }

  Future<NetworkResult<int>> _startListening(int port) async {
    try {
      return NetworkSuccess(await _bindListeningServer(port: port));
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(error, operation: NetworkOperation.startLanListener),
      );
    }
  }

  /// 在 [startListening] 完成生命周期校验后绑定 HTTPS 监听器。
  Future<int> _bindListeningServer({required int port}) async {
    final securityContext = await securityService.getOrCreateSecurityContext(
      currentDeviceId,
    );
    if (_closing || _closed) {
      throw StateError('LAN transfer service is closed.');
    }
    final candidates = [port, ...httpPortCandidates.where((p) => p != port)];

    for (final candidate in candidates) {
      try {
        final server = await HttpServer.bindSecure(
          InternetAddress.anyIPv4,
          candidate,
          securityContext,
          requestClientCertificate: false,
        );
        if (_closing || _closed) {
          await server.close(force: true);
          throw StateError('LAN transfer service is closed.');
        }
        _server = server;
        _isListening = true;
        _server!.listen(handleHttpRequest);
        debugPrint(
          '[LanTransferService] HTTPS server listening on port ${_server!.port}',
        );
        return _server!.port;
      } catch (error) {
        if (_closing || _closed) rethrow;
        debugPrint(
          '[LanTransferService] HTTPS port $candidate unavailable: $error',
        );
      }
    }

    final server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      0,
      securityContext,
      requestClientCertificate: false,
    );
    if (_closing || _closed) {
      await server.close(force: true);
      throw StateError('LAN transfer service is closed.');
    }
    _server = server;
    _isListening = true;
    _server!.listen(handleHttpRequest);
    debugPrint(
      '[LanTransferService] HTTPS server listening on ephemeral port ${_server!.port}',
    );
    return _server!.port;
  }

  /// 停止 HTTPS 监听器并返回类型化结果。
  Future<NetworkResult<void>> stopListening() {
    final activeStop = _stopListeningFuture;
    if (activeStop != null) return activeStop;
    late final Future<NetworkResult<void>> stop;
    stop = _stopListening().whenComplete(() {
      if (identical(_stopListeningFuture, stop)) {
        _stopListeningFuture = null;
      }
    });
    _stopListeningFuture = stop;
    return stop;
  }

  Future<NetworkResult<void>> _stopListening() async {
    try {
      // A stop requested during TLS-context creation or bind owns the result:
      // wait for that start generation and close whatever it created.
      final activeStart = _startListeningFuture;
      if (activeStart != null) await activeStart;
      if (_server != null) {
        await _server!.close(force: true);
        _server = null;
      }
      _isListening = false;
      _pendingPairingHandshakes.clear();
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(error, operation: NetworkOperation.stopLanListener),
      );
    }
  }

  /// 关闭所有活跃的 LAN WebSocket 连接。
  Future<NetworkResult<void>> closeConnections() async {
    try {
      await Future.wait(
        _trackedWebSockets.toList().map((socket) async {
          try {
            await socket.close();
          } catch (_) {}
        }),
      );
      _activeWebSockets.clear();
      _trackedWebSockets.clear();
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(error, operation: NetworkOperation.closeLanConnections),
      );
    }
  }

  /// 路由一个传入 LAN HTTP 请求，并将处理任务纳入关闭屏障。
  void handleHttpRequest(HttpRequest request) {
    late final Future<void> operation;
    operation = _handleHttpRequest(request).whenComplete(() {
      _requestOperations.remove(operation);
    });
    _requestOperations.add(operation);
  }

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

  /// 连接一个已配对 LAN 对端，只返回命令层状态。
  Future<NetworkResult<void>> connectWebSocket(LanDiscoveredPeer peer) {
    if (_closing || _closed) {
      return Future.value(
        NetworkFailure(
          lanNetworkError(
            StateError('LAN transfer service is closed.'),
            operation: NetworkOperation.connectWebSocket,
            peerId: peer.deviceId,
          ),
        ),
      );
    }
    if (_activeWebSockets.containsKey(peer.deviceId)) {
      return Future.value(const NetworkSuccess<void>(null));
    }
    final activeAttempt = _webSocketConnectAttempts[peer.deviceId];
    if (activeAttempt != null) return activeAttempt;
    late final Future<NetworkResult<void>> attempt;
    attempt = _connectWebSocket(peer).whenComplete(() {
      if (identical(_webSocketConnectAttempts[peer.deviceId], attempt)) {
        _webSocketConnectAttempts.remove(peer.deviceId);
      }
    });
    _webSocketConnectAttempts[peer.deviceId] = attempt;
    return attempt;
  }

  Future<NetworkResult<void>> _connectWebSocket(LanDiscoveredPeer peer) async {
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
      if (_closing || _closed) {
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

  /// 返回 [deviceId] 是否注册了活跃 WebSocket。
  bool isWebSocketConnected(String deviceId) {
    return _activeWebSockets.containsKey(deviceId);
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

  /// 为生命周期测试注册可控 socket。
  @visibleForTesting
  void registerActiveWebSocketForTesting(String deviceId, WebSocket socket) {
    _registerActiveWebSocket(deviceId, socket);
  }

  /// 校验并记录对端广播。
  Future<void> _handleAnnounceRequest(HttpRequest request) async {
    final json = await _protocolGuard.readJson(request);

    final senderId = json['id'] is String ? (json['id'] as String).trim() : '';
    final alias = json['alias'] is String
        ? (json['alias'] as String).trim()
        : '';
    final os = json['os'] is String ? (json['os'] as String).trim() : '';
    var hostIp = request.connectionInfo?.remoteAddress.address ?? '';
    if (hostIp.startsWith('::ffff:')) {
      hostIp = hostIp.substring(7);
    }
    final port = (json['port'] as num?)?.toInt() ?? defaultHttpPort;

    if (senderId.isEmpty ||
        senderId == currentDeviceId ||
        senderId.length > 128 ||
        alias.isEmpty ||
        alias.length > 128 ||
        os.isEmpty ||
        os.length > 64 ||
        hostIp.isEmpty ||
        port < 1 ||
        port > 65535) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid device announcement.',
      );
    }
    _protocolGuard.checkPairingInviteRate(hostIp);
    {
      final peer = LanDiscoveredPeer(
        deviceId: senderId,
        alias: alias,
        ip: hostIp,
        controlPort: port,
        deviceType: _guessDeviceType(os),
        os: os,
        lastSeen: DateTime.now(),
      );
      _emit(_announcedPeerController, peer);
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'deviceId': currentDeviceId, 'port': activePort}),
    );
    await request.response.close();
  }

  /// 校验并记录传入配对邀请。
  Future<void> _handlePairingInviteRequest(HttpRequest request) async {
    final json = await _protocolGuard.readJson(request);
    final senderId = json['deviceId'] is String
        ? (json['deviceId'] as String).trim()
        : '';
    final sessionId = json['sessionId'] is String
        ? (json['sessionId'] as String).trim()
        : '';
    final validForMs = (json['validForMs'] as num?)?.toInt() ?? 0;
    final alias = json['alias'] is String
        ? (json['alias'] as String).trim()
        : '';
    final os = json['os'] is String ? (json['os'] as String).trim() : '';
    final port = (json['port'] as num?)?.toInt() ?? defaultHttpPort;
    if (senderId.isEmpty ||
        senderId == currentDeviceId ||
        senderId.length > 128 ||
        sessionId.isEmpty ||
        sessionId.length > 128 ||
        alias.isEmpty ||
        alias.length > 128 ||
        os.isEmpty ||
        os.length > 64 ||
        port < 1 ||
        port > 65535 ||
        validForMs <= 0 ||
        validForMs > const Duration(minutes: 2).inMilliseconds) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid pairing invitation.',
      );
    }
    final expiresAt = DateTime.now().add(Duration(milliseconds: validForMs));
    var hostIp = request.connectionInfo?.remoteAddress.address ?? '';
    if (hostIp.startsWith('::ffff:')) {
      hostIp = hostIp.substring(7);
    }
    if (hostIp.isEmpty) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Pairing invitation has no source address.',
      );
    }
    _protocolGuard.checkPairingInviteRate(hostIp);
    final peer = LanDiscoveredPeer(
      deviceId: senderId,
      alias: alias,
      ip: hostIp,
      controlPort: port,
      deviceType: _guessDeviceType(os),
      os: os,
      lastSeen: DateTime.now(),
    );
    _emit(
      _pairingInviteController,
      LanPairingRequest(
        peer: LanPeerViewState(discovery: peer),
        sessionId: sessionId,
        isIncoming: true,
        expiresAt: expiresAt,
      ),
    );
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'deviceId': currentDeviceId, 'port': activePort}),
    );
    await request.response.close();
  }

  /// 将对端操作系统标签映射为功能使用的设备类别。
  LanDeviceType _guessDeviceType(String os) {
    final lower = os.toLowerCase();
    if (lower.contains('android') || lower.contains('ios')) {
      return LanDeviceType.mobile;
    }
    if (lower.contains('web')) {
      return LanDeviceType.webBrowser;
    }
    return LanDeviceType.desktop;
  }

  /// 校验并接收文本/剪贴板元数据。
  ///
  /// Binary metadata is intentionally rejected. Files are transferred through
  /// Network V2 and never through this HTTPS control plane.
  Future<void> _handleMetaRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final e2ePubKeyHeader = request.headers.value('x-e2e-pubkey');
    final isEncrypted = e2ePubKeyHeader == '1';
    if (!isEncrypted) {
      throw const LanHttpException(
        HttpStatus.upgradeRequired,
        'LAN metadata requires application E2E encryption.',
      );
    }
    Map<String, dynamic> json;
    final blob = await _protocolGuard.readBytes(
      request,
      maxBytes: LanTransferProtocolGuard.maxMetadataBodyBytes + 60,
    );
    try {
      final plainBytes = await securityService.decryptE2E(blob);
      if (plainBytes.length > LanTransferProtocolGuard.maxMetadataBodyBytes) {
        throw const LanHttpException(
          HttpStatus.requestEntityTooLarge,
          'Metadata is too large.',
        );
      }
      final decoded = jsonDecode(utf8.decode(plainBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object.');
      }
      json = decoded;
    } on LanHttpException {
      rethrow;
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Encrypted metadata is invalid.',
      );
    }

    final payloadName = json['payloadType'];
    final validPayload =
        payloadName == LanPayloadType.text.name ||
        payloadName == LanPayloadType.clipboard.name;
    if (!validPayload) {
      throw const LanHttpException(
        HttpStatus.upgradeRequired,
        'Binary LAN payloads require Network V2 transfer.',
      );
    }

    late final LanMessage decodedMessage;
    try {
      decodedMessage = LanMessage.fromJson({
        ...json,
        'localPath': null,
        'isIncoming': true,
        'isRecalled': false,
      });
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN message metadata.',
      );
    }
    if (decodedMessage.id.isEmpty ||
        decodedMessage.id.length > 128 ||
        decodedMessage.senderId != senderDeviceId ||
        decodedMessage.receiverId != currentDeviceId ||
        decodedMessage.senderAlias.isEmpty ||
        decodedMessage.senderAlias.length > 128 ||
        decodedMessage.fileSize != 0 ||
        (decodedMessage.textContent?.length ?? 0) > 512 * 1024) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN message metadata.',
      );
    }

    final message = LanMessage(
      id: decodedMessage.id,
      senderId: senderDeviceId,
      senderAlias: decodedMessage.senderAlias,
      receiverId: currentDeviceId,
      payloadType: decodedMessage.payloadType,
      textContent: decodedMessage.textContent,
      fileName: null,
      fileSize: 0,
      status: LanTransferStatus.completed,
      bytesTransferred: 0,
      createdAt: DateTime.now(),
      isIncoming: true,
    );

    if (_closing || _closed) {
      throw const LanHttpException(
        HttpStatus.serviceUnavailable,
        'LAN transfer service is shutting down.',
      );
    }

    _emit(_incomingMessageController, message);

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'id': message.id}));
    await request.response.close();
  }

  /// 校验并广播已配对对端发来的撤回请求。
  Future<void> _handleRecallRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final json = await _protocolGuard.readJson(request);
    final messageId = json['messageId'] is String
        ? (json['messageId'] as String).trim()
        : '';
    if (messageId.isEmpty || messageId.length > 128) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid recalled message ID.',
      );
    }
    _emit(
      _recalledMessageIdController,
      LanRecallRequest(senderDeviceId: senderDeviceId, messageId: messageId),
    );

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'messageId': messageId}));
    await request.response.close();
  }

  // ── 带重试的客户端发送 API ──

  /// 创建用于 LAN 请求的证书固定 HTTP 客户端。
  Future<HttpClient> _createHttpClient({
    String? peerDeviceId,
    String? expectedFingerprint,
    bool allowUntrusted = false,
  }) async {
    final storedFingerprint = peerDeviceId == null
        ? null
        : await securityService.getPeerCertificateFingerprint(peerDeviceId);
    final providedFingerprint = expectedFingerprint?.trim().toLowerCase();
    if (providedFingerprint != null &&
        providedFingerprint.isNotEmpty &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(providedFingerprint)) {
      throw const FormatException('Invalid LAN certificate fingerprint');
    }
    if (storedFingerprint != null &&
        providedFingerprint != null &&
        providedFingerprint.isNotEmpty &&
        storedFingerprint.toLowerCase() != providedFingerprint) {
      throw const FormatException('LAN certificate fingerprint changed');
    }
    final pinnedFingerprint =
        storedFingerprint?.toLowerCase() ??
        (providedFingerprint?.isNotEmpty == true ? providedFingerprint : null);
    // 使用空信任库，确保每张证书都会到达回调。
    // 否则链到系统或企业 CA 的证书可能绕过应用层指纹固定。
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 15)
      ..findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (cert, host, port) {
      if (pinnedFingerprint == null) {
        return allowUntrusted;
      }
      return crypto.sha256.convert(cert.der).toString() == pinnedFingerprint;
    };
    return client;
  }

  /// 手动分发 Web Share 服务传入的 LanMessage。
  void handleIncomingMessageFromWeb(LanMessage message) {
    _emit(_incomingMessageController, message);
  }

  /// 手动分发 Web Share 服务的消息进度更新。
  void handleMessageProgressFromWeb(LanMessage message) {
    _emit(_messageProgressController, message);
  }

  /// 丢弃 [peerId] 的双向证明，并通知界面清除等待提示。
  void _discardReciprocalPairing(String peerId) {
    _reciprocalPairing.discard(peerId);
    _emit(
      _pairingDirectionController,
      LanPairingDirectionNotice(
        peerId: peerId,
        outboundVerified: false,
        inboundVerified: false,
      ),
    );
  }

  LanDiscoveredPeer _peerFromPairingProof(LanPairingDirectionProof proof) {
    return LanDiscoveredPeer(
      deviceId: proof.peerDeviceId,
      alias: proof.alias,
      ip: proof.ip,
      controlPort: proof.controlPort,
      deviceType: _guessDeviceType(proof.os),
      os: proof.os,
      lastSeen: DateTime.now(),
    );
  }

  void _emitObservedPeer(LanPairingDirectionProof proof) {
    _emit(_observedPeerController, _peerFromPairingProof(proof));
  }

  /// Persists trust only for a committed reciprocal update.
  ///
  /// Waiting leaves the trust store unchanged. The observed peer is emitted
  /// before handshake success so discovery is registered first.
  Future<LanPairingHandshakeProgress?> _applyReciprocalUpdate({
    required LanReciprocalPairingUpdate update,
    required LanPairingDirectionProof observed,
  }) async {
    _emit(_pairingDirectionController, update.notice);
    switch (update.decision) {
      case LanReciprocalPairingDecision.rejected:
        return null;
      case LanReciprocalPairingDecision.waiting:
        _emitObservedPeer(observed);
        return LanPairingHandshakeProgress.waitingForPeer;
      case LanReciprocalPairingDecision.committed:
        final proof = update.commitProof;
        if (proof == null) return null;
        await securityService.savePeerTrustRecord(
          deviceId: proof.peerDeviceId,
          certificateFingerprint: proof.certificateFingerprint,
          inboundAccessToken: proof.inboundAccessToken,
          outboundAccessToken: proof.outboundAccessToken,
          x25519PublicKey: proof.x25519PublicKey,
          networkIdentityPublicKey: proof.networkIdentityPublicKey,
        );
        _emitObservedPeer(proof);
        _emit(_handshakeSuccessController, _peerFromPairingProof(proof));
        return LanPairingHandshakeProgress.paired;
    }
  }

  /// 只在服务未进入关闭阶段时发布事件。
  void _emit<T>(StreamController<T> controller, T event) {
    if (_closing || _closed || controller.isClosed) return;
    controller.add(event);
  }

  /// 可等待且幂等地停止网络资源，再关闭所有事件流。
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    _closing = true;
    final activeStart = _startListeningFuture;
    if (activeStart != null) await activeStart;
    await stopListening();
    final requestOperations = _requestOperations.toList();
    if (requestOperations.isNotEmpty) {
      await Future.wait(requestOperations);
    }
    final connectAttempts = _webSocketConnectAttempts.values.toList();
    if (connectAttempts.isNotEmpty) {
      await Future.wait(connectAttempts);
    }
    await closeConnections();
    _activeWebSockets.clear();
    _webSocketConnectAttempts.clear();
    _requestOperations.clear();
    _pendingPairingHandshakes.clear();
    _reciprocalPairing.clear();
    await Future.wait([
      _incomingMessageController.close(),
      _messageProgressController.close(),
      _recalledMessageIdController.close(),
      _handshakeSuccessController.close(),
      _announcedPeerController.close(),
      _pairingInviteController.close(),
      _observedPeerController.close(),
      _pairingDirectionController.close(),
      _connectionStateController.close(),
    ]);
    _closed = true;
  }

  /// Flutter 同步生命周期入口；正式 owner 应等待 [close]。
  void dispose() {
    unawaited(close());
  }
}
