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
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_native_transfer_coordinator.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import 'package:network_sdk/network_sdk.dart';

part 'lan_share_viewmodel_network.dart';
part 'lan_share_viewmodel_history.dart';

/// 功能范围内的 LAN 状态、命令编排与历史记录外观。
class LanShareViewModel extends ChangeNotifier {
  final LanDiscoveryService discoveryService;
  final LanSecurityService securityService;
  final LanStorageService storageService;
  final LanTransferService transferService;
  final LanNativeTransferCoordinator? nativeTransferCoordinator;
  final LanHistoryDao historyDao;
  final LanShareSettingsPort appSettings;
  final LanShareDataProtectionPort dataProtection;
  final LanShareLoggerPort logger;
  final bool ownsRuntime;
  final ValueChanged<LanPairingRequest>? pairingRequestPublisher;

  List<LanDiscoveredPeer> _devices = [];
  final Map<String, LanPeerTrustRecord> _trustRecords = {};
  List<LanMessage> _history = [];
  StreamSubscription? _devicesSubscription;
  StreamSubscription? _incomingMessageSubscription;
  StreamSubscription? _progressSubscription;
  StreamSubscription<NetworkEvent>? _networkProgressSubscription;
  StreamSubscription? _recallSubscription;
  StreamSubscription? _historyDbSubscription;
  StreamSubscription? _announcedPeerSubscription;
  StreamSubscription? _pairingInviteSubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription<List<LanPeerTrustRecord>>? _trustSubscription;
  StreamSubscription? _routeStateSubscription;
  Timer? _keepAliveTimer;
  Future<void>? _keepAliveOperation;
  Future<void> _historyRefreshSerial = Future<void>.value();
  final Map<String, Future<void>> _messagePersistence = {};
  final Set<Future<void>> _backgroundOperations = <Future<void>>{};

  final _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final Map<String, LanPairingRequest> _latestPairingRequests = {};

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
      );
    }
    return List<LanPeerViewState>.unmodifiable(states.values);
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

  /// 初始化订阅，并在拥有运行时的情况下初始化 LAN 运行时。
  Future<void> initialize() {
    if (_disposed) {
      return Future<void>.error(
        StateError('LAN share view model is disposed.'),
      );
    }
    final shutdown = _shutdownFuture;
    if (shutdown != null) {
      return shutdown.then((_) {
        if (_disposed) {
          throw StateError('LAN share view model is disposed.');
        }
        if (identical(_shutdownFuture, shutdown)) {
          _shutdownFuture = null;
        }
        return initialize();
      });
    }
    return _initializationFuture ??= _initialize();
  }

  /// 执行一次性初始化流程。
  Future<void> _initialize() async {
    if (_isInitialized) return;
    final generation = _lifecycleGeneration;
    await appSettings.ensureLanIdentity();
    if (_disposed || generation != _lifecycleGeneration) return;
    if (appSettings.lanDeviceId.trim().isEmpty ||
        discoveryService.currentDeviceId.trim().isEmpty ||
        transferService.currentDeviceId.trim().isEmpty) {
      _initializationFuture = null;
      throw StateError(
        'LAN Quick Share cannot start without a stable device identity.',
      );
    }

    appSettings.addListener(_onSettingsChanged);

    await _loadTrustProjection();
    if (_disposed || generation != _lifecycleGeneration) return;

    // 在打开监听器前先订阅，避免 HTTPS/mDNS 启动期间到达的邀请被确认后丢失。
    _devicesSubscription = discoveryService.discoveredPeersStream.listen((
      devs,
    ) {
      _devices = List.from(devs);
      if (!_disposed) notifyListeners();
    });
    _incomingMessageSubscription = transferService.incomingMessageStream.listen(
      (msg) {
        _trackBackgroundOperation(
          _enqueueMessagePersistence(msg.id, () => _saveMessageToDb(msg)),
          'LAN incoming history persistence failed',
        );
      },
    );
    _announcedPeerSubscription = transferService.announcedPeerStream.listen((
      peer,
    ) {
      registerDiscoveredPeer(peer);
      _emitIncomingPairingRequest(peer);
    });
    _pairingInviteSubscription = transferService.pairingInviteStream.listen((
      request,
    ) {
      if (request.isExpired) return;
      final peer = request.peer.discovery;
      if (peer != null) registerDiscoveredPeer(peer);
      _publishPairingRequest(request);
    });
    _progressSubscription = transferService.messageProgressStream.listen((msg) {
      _trackBackgroundOperation(
        _enqueueMessagePersistence(
          msg.id,
          () => historyDao.updateRecordStatus(
            msg.id,
            msg.status.toJson(),
            bytesTransferred: msg.bytesTransferred,
            localPath: msg.localPath,
          ),
        ),
        'LAN progress persistence failed',
      );
    });
    _networkProgressSubscription = nativeTransferCoordinator?.events.listen(
      _handleNetworkEvent,
    );
    _routeStateSubscription = nativeTransferCoordinator?.routeStates.listen((
      _,
    ) {
      if (!_disposed) notifyListeners();
    });
    _recallSubscription = transferService.recalledMessageIdStream.listen((
      recall,
    ) {
      _trackBackgroundOperation(
        _applyIncomingRecall(recall),
        'LAN recall persistence failed',
      );
    });
    _historyDbSubscription = historyDao.watchAllRecords().listen((records) {
      _historyRefreshSerial = _historyRefreshSerial
          .then((_) => _refreshHistory(records))
          .catchError((error, stackTrace) {
            debugPrint(
              '[LanShareViewModel] History refresh failed: '
              'errorType=${error.runtimeType}',
            );
          });
    });
    _connectionStateSubscription = transferService.connectionStateStream.listen(
      (_) {
        if (!_disposed) notifyListeners();
      },
    );

    try {
      if (securityService.activePin == null) {
        securityService.generate6DigitPin();
      }
      unawaited(storageService.perform7DayGarbageCollection());

      if (_disposed || generation != _lifecycleGeneration) return;
      if (ownsRuntime) {
        final listenerResult = await transferService.startListening();
        if (listenerResult is NetworkFailure<int>) {
          logger.warning(
            'LAN listener failed',
            details: listenerResult.error.toString(),
          );
          return;
        }
        final boundPort = (listenerResult as NetworkSuccess<int>).data;
        if (_disposed || generation != _lifecycleGeneration) {
          await transferService.stopListening();
          return;
        }
        await discoveryService.startAdvertising(port: boundPort);
      }

      _isInitialized = true;
      _startKeepAliveTimer();
    } catch (_) {
      appSettings.removeListener(_onSettingsChanged);
      await _cancelRuntimeSubscriptions();
      _initializationFuture = null;
      rethrow;
    }
  }

  /// Loads trust records into local view projection without creating a stream subscription.
  Future<void> _refreshTrustProjection() async {
    try {
      final trustStore = securityService.peerTrustStore;
      final records = await trustStore.loadAll();
      if (_disposed) return;
      _trustRecords
        ..clear()
        ..addEntries(
          records.map((record) => MapEntry(record.deviceId, record)),
        );
    } catch (_) {
      _trustRecords.clear();
    }
  }

  /// Loads trust independently of discovery so offline trusted peers remain
  /// available to the presentation layer. Test doubles that do not provide
  /// the concrete trust store are intentionally treated as an empty store.
  Future<void> _loadTrustProjection() async {
    await _trustSubscription?.cancel();
    _trustSubscription = null;
    await _refreshTrustProjection();
    try {
      final trustStore = securityService.peerTrustStore;
      _trustSubscription = trustStore.changes.listen((records) {
        if (_disposed) return;
        _trustRecords
          ..clear()
          ..addEntries(
            records.map((record) => MapEntry(record.deviceId, record)),
          );
        notifyListeners();
      });
    } catch (_) {}
  }

  /// 取消 ViewModel 持有的全部订阅和保活定时器。
  Future<void> _cancelRuntimeSubscriptions() async {
    final subscriptions = <StreamSubscription?>[
      _devicesSubscription,
      _incomingMessageSubscription,
      _progressSubscription,
      _networkProgressSubscription,
      _recallSubscription,
      _historyDbSubscription,
      _announcedPeerSubscription,
      _pairingInviteSubscription,
      _connectionStateSubscription,
      _trustSubscription,
      _routeStateSubscription,
    ];
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final subscription in subscriptions) {
      try {
        await subscription?.cancel();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _devicesSubscription = null;
    _incomingMessageSubscription = null;
    _progressSubscription = null;
    _networkProgressSubscription = null;
    _routeStateSubscription = null;
    _recallSubscription = null;
    _historyDbSubscription = null;
    _announcedPeerSubscription = null;
    _pairingInviteSubscription = null;
    _connectionStateSubscription = null;
    _trustSubscription = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void _trackBackgroundOperation(Future<void> operation, String description) {
    late final Future<void> tracked;
    tracked = operation
        .catchError((Object error) {
          logger.warning(
            description,
            details: 'errorType=${error.runtimeType}',
          );
        })
        .whenComplete(() => _backgroundOperations.remove(tracked));
    _backgroundOperations.add(tracked);
  }

  Future<void> _applyIncomingRecall(LanRecallRequest recall) async {
    final record = await historyDao.getRecord(recall.messageId);
    if (record == null ||
        !record.isIncoming ||
        record.senderId != recall.senderDeviceId) {
      return;
    }
    final localPath = record.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      await storageService.deleteSandboxFile(localPath);
    }
    await _enqueueMessagePersistence(
      recall.messageId,
      () => historyDao.updateRecordStatus(
        recall.messageId,
        LanTransferStatus.recalled.toJson(),
        isRecalled: true,
      ),
    );
  }

  Future<void> _drainBackgroundOperations() async {
    while (_backgroundOperations.isNotEmpty) {
      await Future.wait(_backgroundOperations.toList(growable: false));
    }
    while (_messagePersistence.isNotEmpty) {
      await Future.wait(
        _messagePersistence.values.map(
          (operation) => operation.then<void>((_) {}, onError: (_, _) {}),
        ),
      );
    }
    while (true) {
      final refresh = _historyRefreshSerial;
      await refresh;
      if (identical(refresh, _historyRefreshSerial)) return;
    }
  }

  NetworkError? _lastScanError;

  /// 最近一次扫描失败的错误信息（成功或正在扫描时为 null）。
  NetworkError? get lastScanError => _lastScanError;

  /// 启动 LAN 发现并刷新 UI 状态。
  Future<NetworkResult<void>> startScanning() async {
    if (_disposed) {
      return _networkFailure(
        code: NetworkErrorCode.cancelled,
        message: 'LAN discovery is stopped.',
        operation: NetworkOperation.startDiscovery,
      );
    }
    _lastScanError = null;
    final result = await discoveryService.startDiscovery();
    if (result is NetworkFailure<void>) {
      _lastScanError = result.error;
    }
    if (!_disposed) notifyListeners();
    return result;
  }

  /// 停止 LAN 发现并刷新 UI 状态。
  Future<NetworkResult<void>> stopScanning() async {
    _lastScanError = null;
    final result = await discoveryService.stopDiscovery();
    if (!_disposed) notifyListeners();
    return result;
  }

  /// 启动或停止固定使用 HTTPS 的 WebShare。
  Future<NetworkResult<void>> toggleWebShare() async {
    late final NetworkResult<void> result;
    if (isWebShareActive) {
      result = await discoveryService.stopWebShareServer();
    } else {
      result = await discoveryService.startWebShareServer(
        securityService: securityService,
        storageService: storageService,
        transferService: transferService,
      );
    }
    if (!_disposed) notifyListeners();
    return result;
  }

  /// 发送文本消息，并持久化稳定结果码。
  Future<NetworkResult<void>> sendText(
    LanDiscoveredPeer device,
    String text,
  ) async {
    final msg = LanMessage(
      id: const Uuid().v4(),
      senderId: discoveryService.currentDeviceId,
      senderAlias: discoveryService.currentDeviceAlias,
      receiverId: device.deviceId,
      payloadType: LanPayloadType.text,
      textContent: text,
      status: LanTransferStatus.transferring,
      createdAt: DateTime.now(),
      isIncoming: false,
    );

    await _saveMessageToDb(msg);
    final pubKey = await securityService.getPeerX25519PublicKey(
      device.deviceId,
    );
    if (pubKey == null) {
      return _recordNetworkFailure(
        msg.id,
        NetworkError(
          code: NetworkErrorCode.authenticationFailed,
          message: 'Recipient E2E public key is unavailable.',
          operation: NetworkOperation.sendMeta,
          peerId: device.deviceId,
        ),
      );
    }
    final result = await transferService.sendMeta(
      device,
      msg,
      recipientPubKeyBytes: pubKey,
    );
    await historyDao.updateRecordStatus(
      msg.id,
      result is NetworkSuccess<void>
          ? LanTransferStatus.completed.toJson()
          : LanTransferStatus.failed.toJson(),
      failureReason: result is NetworkFailure<void>
          ? result.error.code.name
          : null,
    );
    return result;
  }

  /// 发送剪贴板内容，并持久化稳定结果码。
  Future<NetworkResult<void>> sendClipboard(
    LanDiscoveredPeer device,
    String text,
  ) async {
    final msg = LanMessage(
      id: const Uuid().v4(),
      senderId: discoveryService.currentDeviceId,
      senderAlias: discoveryService.currentDeviceAlias,
      receiverId: device.deviceId,
      payloadType: LanPayloadType.clipboard,
      textContent: text,
      status: LanTransferStatus.transferring,
      createdAt: DateTime.now(),
      isIncoming: false,
    );

    await _saveMessageToDb(msg);
    final pubKey = await securityService.getPeerX25519PublicKey(
      device.deviceId,
    );
    if (pubKey == null) {
      return _recordNetworkFailure(
        msg.id,
        NetworkError(
          code: NetworkErrorCode.authenticationFailed,
          message: 'Recipient E2E public key is unavailable.',
          operation: NetworkOperation.sendMeta,
          peerId: device.deviceId,
        ),
      );
    }
    final result = await transferService.sendMeta(
      device,
      msg,
      recipientPubKeyBytes: pubKey,
    );
    await historyDao.updateRecordStatus(
      msg.id,
      result is NetworkSuccess<void>
          ? LanTransferStatus.completed.toJson()
          : LanTransferStatus.failed.toJson(),
      failureReason: result is NetworkFailure<void>
          ? result.error.code.name
          : null,
    );
    return result;
  }

  /// Delegates binary transfer orchestration to the Network V2 coordinator.
  Future<NetworkResult<TransferSession>> sendFile({
    required String peerId,
    required String filePath,
    LanDiscoveredPeer? discovery,
  }) async {
    final file = File(filePath);
    final stat = await file.stat();
    final fileName = file.uri.pathSegments.isEmpty
        ? 'file.bin'
        : file.uri.pathSegments.last;
    final payloadType = classifyAttachment(fileName: fileName);
    final transferId = const Uuid().v4();

    final msg = LanMessage(
      id: transferId,
      senderId: discoveryService.currentDeviceId,
      senderAlias: discoveryService.currentDeviceAlias,
      receiverId: peerId,
      payloadType: payloadType,
      fileName: fileName,
      fileSize: stat.size,
      status: LanTransferStatus.transferring,
      createdAt: DateTime.now(),
      isIncoming: false,
    );

    await _saveMessageToDb(msg);

    final coordinator = nativeTransferCoordinator;
    if (coordinator == null) {
      final error = NetworkError(
        code: NetworkErrorCode.noRoute,
        message: 'Native transfer coordinator is unavailable.',
        operation: NetworkOperation.sendFile,
        peerId: peerId,
      );
      await historyDao.updateRecordStatus(
        transferId,
        LanTransferStatus.failed.toJson(),
        failureReason: error.code.name,
      );
      return NetworkFailure<TransferSession>(error);
    }

    final result = await coordinator.sendFile(
      peerId: peerId,
      transferId: transferId,
      filePath: filePath,
      discovery: discovery,
    );

    if (result is NetworkFailure<TransferSession>) {
      await historyDao.updateRecordStatus(
        transferId,
        LanTransferStatus.failed.toJson(),
        failureReason: result.error.code.name,
      );
    }
    return result;
  }

  /// Convenience method for discovered peers.
  Future<NetworkResult<TransferSession>> sendFileToDiscoveredPeer(
    LanDiscoveredPeer device,
    String filePath,
  ) => sendFile(peerId: device.deviceId, filePath: filePath, discovery: device);

  /// 远端撤回消息，并将本地历史记录标记为已撤回。
  Future<NetworkResult<void>> recallMessage(
    LanMessage message,
    LanDiscoveredPeer? device,
  ) async {
    NetworkResult<void> result = const NetworkSuccess<void>(null);
    if (device != null) {
      result = await transferService.sendRecall(device, message.id);
      if (result is NetworkFailure<void>) return result;
    }
    if (message.isIncoming && message.localPath != null) {
      await storageService.deleteSandboxFile(message.localPath!);
    }
    await historyDao.updateRecordStatus(
      message.id,
      LanTransferStatus.recalled.toJson(),
      isRecalled: true,
    );
    return result;
  }

  /// 清除全部 LAN 历史记录并清理已导入的沙箱文件。
  Future<void> clearHistory() async {
    try {
      final records = await historyDao.getAllRecords();
      for (final r in records) {
        if (r.localPath != null && r.localPath!.isNotEmpty) {
          try {
            await storageService.deleteSandboxFile(r.localPath!);
          } catch (error, stackTrace) {
            logger.warning(
              'Failed to delete sandbox file on clearHistory: ${r.localPath}',
              details: '$error\n$stackTrace',
            );
          }
        }
      }
    } catch (error, stackTrace) {
      logger.warning(
        'Failed to query records before clearHistory',
        details: '$error\n$stackTrace',
      );
    }
    await historyDao.clearAllRecords();
    if (!_disposed) notifyListeners();
  }

  /// 删除一条 LAN 历史记录并清理对应沙箱文件。
  Future<void> deleteMessage(String messageId) async {
    try {
      final record = await historyDao.getRecord(messageId);
      if (record?.localPath != null && record!.localPath!.isNotEmpty) {
        await storageService.deleteSandboxFile(record.localPath!);
      }
    } catch (error, stackTrace) {
      logger.warning(
        'Failed to delete sandbox file on deleteMessage: $messageId',
        details: '$error\n$stackTrace',
      );
    }
    await historyDao.deleteRecord(messageId);
    if (!_disposed) notifyListeners();
  }

  /// 解除设备配对； native peer removal is owned by the transfer coordinator.
  Future<NetworkResult<void>> forgetDevice(String deviceId) async {
    final coordinator = nativeTransferCoordinator;
    if (coordinator == null) {
      return _networkFailure(
        code: NetworkErrorCode.noRoute,
        message:
            'Cannot unpair a LAN peer without the native transfer coordinator.',
        operation: NetworkOperation.removePeer,
        peerId: deviceId,
      );
    }
    final result = await coordinator.removeTrustedPeer(deviceId);
    if (result is NetworkSuccess<void>) {
      _trustRecords.remove(deviceId);
      if (!_disposed) notifyListeners();
    }
    return result;
  }

  /// 设置对端设备的 Relay 传输授权策略。
  Future<NetworkResult<void>> setRelayAuthorization(
    String deviceId,
    bool enabled,
  ) async {
    final coordinator = nativeTransferCoordinator;
    if (coordinator == null) {
      return _networkFailure(
        code: NetworkErrorCode.noRoute,
        message: 'Native transfer coordinator is unavailable.',
        operation: NetworkOperation.upsertPeer,
        peerId: deviceId,
      );
    }
    final result = await coordinator.setRelayAuthorization(
      peerId: deviceId,
      enabled: enabled,
    );
    if (result is NetworkSuccess<void>) {
      await _refreshTrustProjection();
      if (!_disposed) notifyListeners();
    }
    return result;
  }

  /// 删除一个对端关联的全部历史和文件。
  Future<void> clearChatHistory(String targetDeviceId) async {
    final records = await historyDao.getAllRecords();
    for (final r in records) {
      final otherId = r.isIncoming ? r.senderId : r.receiverId;
      if (otherId == targetDeviceId) {
        if (r.localPath != null && r.localPath!.isNotEmpty) {
          await storageService.deleteSandboxFile(r.localPath!);
        }
        await historyDao.deleteRecord(r.id);
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// 执行 V2 配对认证；成功响应已原子提交完整 trust record。
  Future<NetworkResult<void>> authenticateDevice(
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
    if (result is NetworkSuccess<void> && !_disposed) {
      notifyListeners();
    }
    return result;
  }

  /// 请求配对，并发布生成的 UI 会话。
  Future<NetworkResult<void>> requestPairing(LanDiscoveredPeer device) async {
    final sessionId = const Uuid().v4();
    final expiresAt = DateTime.now().add(const Duration(minutes: 1));
    final result = await transferService.sendPairingInvite(
      device,
      appSettings.lanDeviceAlias,
      sessionId: sessionId,
      expiresAt: expiresAt,
    );
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

  /// 启动已配对 LAN 对端的周期性重连检查。
  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_disposed || !_isInitialized || _keepAliveOperation != null) return;
      final generation = _lifecycleGeneration;
      late final Future<void> operation;
      operation = _refreshPeerConnections(generation)
          .catchError((Object error) {
            logger.warning(
              'LAN keep-alive refresh failed',
              details: 'errorType=${error.runtimeType}',
            );
          })
          .whenComplete(() {
            if (identical(_keepAliveOperation, operation)) {
              _keepAliveOperation = null;
            }
          });
      _keepAliveOperation = operation;
    });
  }

  Future<void> _refreshPeerConnections(int generation) async {
    for (final device in List<LanDiscoveredPeer>.of(_devices)) {
      final paired = await isDevicePaired(device.deviceId);
      if (_disposed || !_isInitialized || generation != _lifecycleGeneration) {
        return;
      }
      if (paired && !transferService.isWebSocketConnected(device.deviceId)) {
        await transferService.connectWebSocket(device);
      }
    }
  }

  /// 注册手动解析的对端并刷新监听器。
  void registerDiscoveredPeer(LanDiscoveredPeer device) {
    if (_disposed) return;
    discoveryService.registerDiscoveredPeer(device);
    notifyListeners();
  }

  /// 返回可选的 WebShare IP 覆盖值。
  String? get customIp => discoveryService.customIp;

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

  /// 将变更后的应用设置应用到活动发现服务。
  void _onSettingsChanged() {
    if (_disposed) return;
    unawaited(discoveryService.updateDeviceAlias(appSettings.lanDeviceAlias));
    notifyListeners();
  }

  /// 关闭 ViewModel 持有的资源，且只执行一次。
  Future<void> shutdown() {
    return _shutdownFuture ??= _shutdown();
  }

  /// 执行串行化的 ViewModel 关闭流程。
  Future<void> _shutdown() async {
    _lifecycleGeneration++;
    _isInitialized = false;
    appSettings.removeListener(_onSettingsChanged);
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(_cancelRuntimeSubscriptions);
    final keepAlive = _keepAliveOperation;
    if (keepAlive != null) await attempt(() => keepAlive);
    await attempt(_drainBackgroundOperations);
    await attempt(stopScanning);
    if (ownsRuntime) {
      await attempt(discoveryService.stopAdvertising);
      await attempt(transferService.stopListening);
    }

    final initialization = _initializationFuture;
    if (initialization != null) {
      await attempt(() => initialization);
    }
    if (ownsRuntime) {
      // startListening 可能与上面的第一次 stop 并发完成。
      await attempt(discoveryService.stopAdvertising);
      await attempt(transferService.closeConnections);
    }
    _devices = [];
    _initializationFuture = null;
    if (!_disposed) notifyListeners();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<void> _disposeOwnedResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(shutdown);
    if (ownsRuntime) {
      await attempt(discoveryService.close);
      await attempt(transferService.close);
    }
    await attempt(_pairingRequestController.close);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  /// 销毁 ViewModel，并安排其拥有的运行时清理。
  @override
  void dispose() {
    _disposed = true;
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
