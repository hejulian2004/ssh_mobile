// LAN Share ViewModel：负责 HTTPS 控制命令、Network V2 事件和持久化传输历史。
// 网络事件处理位于独立 part 文件。

import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../data/database/lan_share_database.dart';
import '../../../domain/lan_share_ports.dart';
import '../../../services/lan_share/lan_discovery_service.dart';
import '../../../services/lan_share/lan_network_models.dart';
import '../../../services/lan_share/lan_security_service.dart';
import '../../../services/lan_share/lan_peer_trust.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_document_exchange.dart';
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_native_transfer_coordinator.dart';
import '../../../services/lan_share/lan_pairing_reciprocal.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import '../notifications/lan_system_notification.dart';
import 'package:network_sdk/network_sdk.dart';

part 'lan_share_viewmodel_network.dart';
part 'lan_share_viewmodel_history.dart';
part 'lan_share_viewmodel_presence.dart';
part 'lan_share_viewmodel_lifecycle.dart';
part 'lan_share_viewmodel_commands.dart';
part 'lan_share_viewmodel_documents.dart';

/// 功能范围内的 LAN 状态、命令编排与历史记录外观。
class LanShareViewModel extends ChangeNotifier {
  final LanDiscoveryService discoveryService;
  final LanSecurityService securityService;
  final LanStorageService storageService;
  final LanTransferService transferService;
  final LanNativeTransferCoordinator? nativeTransferCoordinator;
  final LanHistoryDao historyDao;
  final LanPairingMetadataDao? pairingMetadataDao;
  final LanShareSettingsPort appSettings;
  final LanShareDataProtectionPort dataProtection;
  final LanShareLoggerPort logger;
  final bool ownsRuntime;
  final ValueChanged<LanPairingRequest>? pairingRequestPublisher;
  late final VoidCallback _settingsChangedListener = _onSettingsChanged;

  List<LanDiscoveredPeer> _devices = [];
  final Map<String, LanPeerTrustRecord> _trustRecords = {};
  final Map<String, LanPairingMetadataData> _peerMetadata = {};
  final Set<String> _onlinePeerIds = {};
  final Map<String, DateTime> _onlineSince = {};
  Future<void> _peerMetadataWrites = Future<void>.value();
  List<LanMessage> _history = [];
  StreamSubscription? _devicesSubscription;
  StreamSubscription? _incomingMessageSubscription;
  StreamSubscription? _progressSubscription;
  StreamSubscription<NetworkEvent>? _networkProgressSubscription;
  StreamSubscription? _recallSubscription;
  StreamSubscription? _historyDbSubscription;
  StreamSubscription? _announcedPeerSubscription;
  StreamSubscription? _pairingInviteSubscription;
  StreamSubscription? _observedPeerSubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription<List<LanPeerTrustRecord>>? _trustSubscription;
  StreamSubscription? _routeStateSubscription;
  Timer? _keepAliveTimer;
  Future<void>? _keepAliveOperation;
  Future<void> _historyRefreshSerial = Future<void>.value();
  final Map<String, Future<void>> _messagePersistence = {};
  final Set<Future<void>> _backgroundOperations = <Future<void>>{};
  final _documentSources = <LanDocumentSource>{};
  final _documentSinks = <LanDocumentSink>{};
  final _documentOperations = <Future<void>>{};

  final _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final _notificationEvents =
      StreamController<LanNotificationEvent>.broadcast();

  /// Events published after a notifiable LAN record is persisted.
  Stream<LanNotificationEvent> get notificationEvents =>
      _notificationEvents.stream;

  void _emitNotification(LanNotificationEvent? event) {
    if (event == null || _disposed || _notificationEvents.isClosed) return;
    _notificationEvents.add(event);
  }

  final Map<String, LanPairingRequest> _latestPairingRequests = {};
  final Map<String, Object> _pairingConnections = {};
  final Set<Object> _cancelledPairingConnections = {};

  bool isPairingConnecting(String peerId) =>
      _pairingConnections.containsKey(peerId);

  void cancelPairingConnection(String peerId) {
    final attempt = _pairingConnections[peerId];
    if (attempt == null) return;
    _cancelledPairingConnections.add(attempt);
    transferService.cancelPairingInvite(peerId);
    if (!_disposed) _notifyStateChanged();
  }

  void cancelPairingAuthentication(String peerId) =>
      transferService.cancelPairingAuthentication(peerId);

  /// 发布当前 LAN UI 范围的配对请求。
  Stream<LanPairingRequest> get pairingRequestStream =>
      _pairingRequestController.stream;

  /// 返回 [sessionId] 对应的未过期配对请求。
  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestPairingRequests[sessionId];
    if (request == null || request.isExpired) return null;
    return request;
  }

  /// 向协调器和 UI 保存并发布一个配对请求。
  void _publishPairingRequest(LanPairingRequest request) {
    _latestPairingRequests.removeWhere((_, value) => value.isExpired);
    _latestPairingRequests[request.sessionId] = request;
    _pairingRequestController.add(request);
    pairingRequestPublisher?.call(request);
  }

  bool _isInitialized = false;
  bool _disposed = false;
  int _lifecycleGeneration = 0;
  Future<void>? _initializationFuture;

  Future<void>? _shutdownFuture;

  /// 基于功能拥有的 LAN 与历史服务创建 ViewModel。
  LanShareViewModel({
    required this.discoveryService,
    required this.securityService,
    required this.storageService,
    required this.transferService,
    this.nativeTransferCoordinator,
    required this.historyDao,
    this.pairingMetadataDao,
    required this.appSettings,
    required this.dataProtection,
    required this.logger,
    this.ownsRuntime = true,
    this.pairingRequestPublisher,
  });

  /// 返回当前发现和手动注册的设备。
  List<LanDiscoveredPeer> get devices => _devices;

  /// 返回 UI 使用的聚合 peer 状态。
  ///
  /// Trust records are retained when discovery disappears, so a peer with a
  /// trust record and no current endpoint remains visible as trusted offline.
  /// The list is ordered by display name, then peer id. Discovery snapshots
  /// are ordered by lastSeen, and heartbeats refresh that timestamp, so
  /// following recency would move cards on every announcement.
  List<LanPeerViewState> get peerStates {
    final states = <String, LanPeerViewState>{};
    final routeStates =
        nativeTransferCoordinator?.currentRouteStates ?? const {};
    for (final trust in _trustRecords.values) {
      final routeState =
          routeStates[trust.deviceId] ?? const LanPeerRouteState();
      states[trust.deviceId] = LanPeerViewState(
        trust: trust,
        route: routeState,
        reachability: _isRouteOnline(trust.deviceId, routeState)
            ? LanPeerReachability.online
            : LanPeerReachability.offline,
        savedAlias: _peerMetadata[trust.deviceId]?.alias,
        savedDeviceType: _savedDeviceType(trust.deviceId),
        lastOnlineAt: _savedOnlineTime(trust.deviceId),
      );
    }
    for (final peer in _devices) {
      final nativePort = peer.advertisedNativePort;
      final directAvailable =
          peer.ip.trim().isNotEmpty &&
          nativePort != null &&
          nativePort > 0 &&
          nativePort <= 65535;
      final existing = states[peer.deviceId];
      final routeState =
          routeStates[peer.deviceId] ??
          existing?.route ??
          const LanPeerRouteState();
      states[peer.deviceId] = LanPeerViewState(
        peerId: peer.deviceId,
        trust: existing?.trust ?? _trustRecords[peer.deviceId],
        discovery: peer,
        route: routeState.copyWith(directAvailable: directAvailable),
        lastOnlineAt: _latestOnlineTime(peer),
      );
    }
    final ordered = states.values.toList(growable: false)
      ..sort(_compareDeviceListOrder);
    return List<LanPeerViewState>.unmodifiable(ordered);
  }

  /// Returns one aggregated UI state by stable peer id.
  LanPeerViewState? peerStateFor(String deviceId) {
    for (final state in peerStates) {
      if (state.peerId == deviceId) return state;
    }
    return null;
  }

  /// 返回持久化 LAN 传输历史快照。
  List<LanMessage> get history => _history;

  /// LAN 发现是否处于活动状态。
  bool get isScanning => discoveryService.isScanning;

  /// WebShare 是否处于活动状态。
  bool get isWebShareActive => discoveryService.isWebShareActive;

  /// WebShare 活动时返回当前 URL。
  String? get webShareUrl => discoveryService.webShareUrl;

  /// 创建带有稳定操作上下文的网络失败结果。
  NetworkFailure<T> _networkFailure<T>({
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

  /// 将失败结果写入 LAN 历史记录，并返回相同的类型化失败。
  Future<NetworkFailure<T>> _recordNetworkFailure<T>(
    String messageId,
    NetworkError error,
  ) async {
    await _enqueueMessagePersistence(
      messageId,
      () => historyDao.updateRecordStatus(
        messageId,
        LanTransferStatus.failed.toJson(),
        failureReason: error.code.name,
      ),
    );
    return NetworkFailure<T>(error);
  }

  /// 发布 ViewModel part 文件请求的状态变化。
  void _notifyHistoryChanged() => notifyListeners();
  void _notifyStateChanged() => notifyListeners();

  NetworkError? _lastScanError;

  /// 最近一次扫描失败的错误信息（成功或正在扫描时为 null）。
  NetworkError? get lastScanError => _lastScanError;

  /// 执行 V2 配对认证。只有双方 PIN 都验证后才提交 trust record。
  Future<NetworkResult<LanPairingHandshakeProgress>> authenticateDevice(
    LanDiscoveredPeer device,
    String pin, {
    bool isInitiator = true,
  }) async {
    final result = await transferService.sendHandshake(
      device,
      pin,
      appSettings.lanDeviceAlias,
      isInitiator: isInitiator,
    );
    if (result is NetworkSuccess<LanPairingHandshakeProgress> &&
        result.data == LanPairingHandshakeProgress.paired &&
        !_disposed) {
      notifyListeners();
    }
    return result;
  }

  /// 请求配对，并发布生成的 UI 会话。
  Future<NetworkResult<void>> requestPairing(LanDiscoveredPeer device) async {
    if (_disposed || isPairingConnecting(device.deviceId)) {
      return _networkFailure(
        code: _disposed
            ? NetworkErrorCode.cancelled
            : NetworkErrorCode.invalidState,
        message: 'LAN pairing connection is unavailable.',
        operation: NetworkOperation.sendPairingInvite,
      );
    }
    final attempt = Object();
    _pairingConnections[device.deviceId] = attempt;
    _notifyStateChanged();
    try {
      final sessionId = const Uuid().v4();
      final expiresAt = DateTime.now().add(const Duration(minutes: 1));
      final result = await transferService.sendPairingInvite(
        device,
        appSettings.lanDeviceAlias,
        sessionId: sessionId,
        expiresAt: expiresAt,
      );
      if (_disposed ||
          _cancelledPairingConnections.contains(attempt) ||
          !identical(_pairingConnections[device.deviceId], attempt)) {
        return _networkFailure(
          code: NetworkErrorCode.cancelled,
          message: 'LAN pairing invitation cancelled.',
          operation: NetworkOperation.sendPairingInvite,
        );
      }
      if (result is NetworkFailure<LanPairingEndpoint>) {
        return NetworkFailure<void>(result.error);
      }
      final endpoint = (result as NetworkSuccess<LanPairingEndpoint>).data;
      final remoteDeviceId = endpoint.remoteDeviceId;
      final remotePort = endpoint.remotePort;
      var resolvedDevice = device;
      if (remoteDeviceId != null &&
          remoteDeviceId.isNotEmpty &&
          (remoteDeviceId != device.deviceId ||
              (remotePort != null && remotePort != device.controlPort))) {
        resolvedDevice = device.copyWith(
          deviceId: remoteDeviceId,
          controlPort: remotePort,
          lastSeen: DateTime.now(),
        );
        discoveryService.removeDiscoveredPeer(device.deviceId);
      }
      registerDiscoveredPeer(resolvedDevice);
      _publishPairingRequest(
        LanPairingRequest(
          peer: LanPeerViewState(discovery: resolvedDevice),
          sessionId: sessionId,
          isIncoming: false,
          expiresAt: expiresAt,
        ),
      );
      return const NetworkSuccess<void>(null);
    } finally {
      _cancelledPairingConnections.remove(attempt);
      if (identical(_pairingConnections[device.deviceId], attempt)) {
        _pairingConnections.remove(device.deviceId);
        if (!_disposed) _notifyStateChanged();
      }
    }
  }

  /// 为 [device] 发布传入配对请求。
  void _emitIncomingPairingRequest(LanDiscoveredPeer peer) {
    _publishPairingRequest(
      LanPairingRequest(
        peer: LanPeerViewState(discovery: peer),
        sessionId: const Uuid().v4(),
        isIncoming: true,
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      ),
    );
  }

  /// 向远端 LAN 对端广播本设备。
  Future<NetworkResult<LanPairingEndpoint>> sendAnnouncement(
    LanDiscoveredPeer device,
  ) {
    return transferService.sendAnnouncement(device, appSettings.lanDeviceAlias);
  }

  /// 检查 [deviceId] 是否有有效的已存储配对。
  Future<bool> isDevicePaired(String deviceId) async {
    String? ip;
    int? port;
    for (final d in _devices) {
      if (d.deviceId == deviceId) {
        ip = d.ip;
        port = d.controlPort;
        break;
      }
    }
    return securityService.isDevicePaired(
      deviceId,
      ip: ip,
      port: port,
      localDeviceId: appSettings.lanDeviceId,
    );
  }

  /// 返回已配对对端是否拥有活跃 WebSocket。
  bool isDeviceConnected(String deviceId) {
    return transferService.isWebSocketConnected(deviceId);
  }

  /// 返回可选的 WebShare IP 覆盖值。
  String? get customIp => discoveryService.customIp;

  /// 本机可用于发现和 WebShare 的地址。页面不直接调用发现服务。
  Future<Map<String, String>> localIpInterfaces() =>
      LanDiscoveryService.getLocalIpInterfaces();

  /// 当前 WebShare 本地地址选择状态，供 Feature UI 显示本地化原因。
  LanShareLocalAddressSelectionResult? get webShareAddressSelectionResult =>
      discoveryService.webShareAddressSelectionResult;

  /// 当前地址选择失败的本地化提示；成功或尚未解析时为 null。
  String? get webShareAddressSelectionMessage =>
      switch (webShareAddressSelectionResult) {
        LanShareLocalAddressAmbiguous() =>
          appSettings.strings.lanShareAddressAmbiguous,
        LanShareLocalAddressUnavailable() =>
          appSettings.strings.lanShareAddressUnavailable,
        LanShareLocalAddressStaleOverride() =>
          appSettings.strings.lanShareAddressOverrideStale,
        _ => null,
      };

  /// Validates an address override and applies it to an active WebShare URL.
  Future<NetworkResult<void>> updateWebShareAddressOverride(String? ip) async {
    final result = await discoveryService.updateWebShareAddressOverride(ip);
    if (!_disposed) notifyListeners();
    return result;
  }

  Future<void> initialize() => _beginInitialize();
  Future<void> shutdown() => _beginShutdown();
  void registerDiscoveredPeer(LanDiscoveredPeer peer) => _registerPeer(peer);
  Future<NetworkResult<void>> startScanning() => _startScanning();
  Future<NetworkResult<void>> stopScanning() => _stopScanning();
  Future<NetworkResult<void>> toggleWebShare() => _toggleWebShare();
  Future<NetworkResult<void>> sendText(LanDiscoveredPeer peer, String text) =>
      _sendText(peer, text);
  Future<NetworkResult<void>> sendClipboard(
    LanDiscoveredPeer peer,
    String text,
  ) => _sendClipboard(peer, text);
  Future<NetworkResult<TransferSession>> sendFile({
    required String peerId,
    required String filePath,
    LanDiscoveredPeer? discovery,
  }) => _sendFile(peerId: peerId, filePath: filePath, discovery: discovery);
  Future<NetworkResult<TransferSession>> sendFileToDiscoveredPeer(
    LanDiscoveredPeer peer,
    String path,
  ) => _sendFileToDiscoveredPeer(peer, path);
  Future<NetworkResult<TransferSession>> retryOutgoingFile(
    LanMessage message, {
    LanDiscoveredPeer? discovery,
  }) => _retryOutgoingFile(message, discovery: discovery);
  Future<NetworkResult<void>> recallMessage(
    LanMessage message,
    LanDiscoveredPeer? peer,
  ) => _recallMessage(message, peer);
  Future<void> clearHistory() => _clearHistory();
  Future<void> deleteMessage(String id) => _deleteMessage(id);
  Future<NetworkResult<void>> forgetDevice(String id) => _forgetDevice(id);
  Future<NetworkResult<void>> setRelayAuthorization(String id, bool enabled) =>
      _setRelayAuthorization(id, enabled);
  Future<void> clearChatHistory(String id) => _clearChatHistory(id);

  /// 销毁 ViewModel，并安排其拥有的运行时清理。
  @override
  void dispose() {
    _disposed = true;
    if (!_notificationEvents.isClosed) _notificationEvents.close();
    for (final peerId in _pairingConnections.keys.toList()) {
      cancelPairingConnection(peerId);
    }
    _lifecycleGeneration++;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    unawaited(
      _disposeOwnedResources().catchError((Object error) {
        logger.warning(
          'LAN share view model cleanup failed',
          details: 'errorType=${error.runtimeType}',
        );
      }),
    );
    super.dispose();
  }
}
