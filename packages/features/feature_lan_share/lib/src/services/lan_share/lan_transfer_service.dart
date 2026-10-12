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
import '../../domain/lan_discovery_bridge.dart';
import 'lan_storage_service.dart';
import 'lan_transfer_protocol.dart';
import 'package:network_sdk/network_sdk.dart';

part 'lan_transfer_client.dart';
part 'lan_transfer_http_routes.dart';
part 'lan_transfer_peer_routes.dart';
part 'lan_transfer_content_routes.dart';
part 'lan_transfer_websockets.dart';
part 'lan_pairing_commit.dart';
part 'lan_pairing_client.dart';
part 'lan_pairing_offer_validation.dart';
part 'lan_transfer_peer_client.dart';
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

  /// Runs after reciprocal PIN verification has committed trust and before
  /// the pairing-success event is published. The receiver coordinator uses
  /// this hook to register the peer in Native Network V2 before the UI can
  /// start a data-plane transfer.
  Future<void> Function(LanDiscoveredPeer peer)? onPairingCommitted;
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
  final Set<Future<void>> _incomingPairingOperations = {};
  final Map<String, Set<Future<NetworkResult<LanPairingHandshakeProgress>>>>
  _outboundPairingOperations = {};
  final Map<String, int> _peerPairingEpochs = {};
  final Map<String, _PairingInviteAttempt> _pairingInviteAttempts = {};
  final Map<String, Set<HttpClient>> _pairingHttpClients = {};

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
    this.onPairingCommitted,
    this.discoveryBridge,
  }) {
    _protocolGuard = LanTransferProtocolGuard(
      currentDeviceId: currentDeviceId,
      securityService: securityService,
    );
  }

  final LanShareDiscoveryBridgePort? discoveryBridge;

  /// Resolves only live, platform-owned local port mappings.
  LanDiscoveredPeer resolvePeer(LanDiscoveredPeer peer) =>
      discoveryBridge?.routePeer(peer) ?? peer;

  /// Maps an authenticated native capability without changing its identity.
  int? resolveNativePort(LanDiscoveredPeer peer, int remotePort) =>
      discoveryBridge == null
      ? remotePort
      : discoveryBridge!.nativePortFor(peer, remotePort);

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

  /// Releases this peer's HTTPS pairing proofs and connection after explicit unpair.
  Future<void> disconnectPairedPeer(String peerId) =>
      _disconnectPairedPeer(peerId);

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
      _incomingPairingOperations.remove(operation);
    });
    _requestOperations.add(operation);
    if (request.uri.path == '/api/lan/handshake') {
      _incomingPairingOperations.add(operation);
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

  /// 返回 [deviceId] 是否注册了活跃 WebSocket。
  bool isWebSocketConnected(String deviceId) {
    return _activeWebSockets.containsKey(deviceId);
  }

  /// 为生命周期测试注册可控 socket。
  @visibleForTesting
  void registerActiveWebSocketForTesting(String deviceId, WebSocket socket) {
    _registerActiveWebSocket(deviceId, socket);
  }

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

  void _emit<T>(StreamController<T> controller, T event) {
    if (_closing || _closed || controller.isClosed) return;
    controller.add(event);
  }

  /// 可等待且幂等地停止网络资源，再关闭所有事件流。
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    _closing = true;
    for (final peerId in _outboundPairingOperations.keys.toList()) {
      cancelPairingAuthentication(peerId);
    }
    final invitations = _pairingInviteAttempts.values.toList();
    for (final peerId in _pairingInviteAttempts.keys.toList()) {
      cancelPairingInvite(peerId);
    }
    await Future.wait(invitations.map((attempt) => attempt.done.future));
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
    await Future.wait(
      _outboundPairingOperations.values
          .expand((operations) => operations)
          .toList(),
    );
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
