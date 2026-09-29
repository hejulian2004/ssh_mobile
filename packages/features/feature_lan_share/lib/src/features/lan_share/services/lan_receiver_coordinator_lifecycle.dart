part of 'lan_receiver_coordinator.dart';

/// Receiver initialization, activation, and release ownership.
extension LanReceiverCoordinatorLifecycle on LanReceiverCoordinator {
  /// 初始化接收器资源一次，并让并发调用方共享同一个 Future。
  Future<void> ensureInitialized() {
    if (_disposed) {
      return Future<void>.error(
        StateError('LAN receiver coordinator is disposed.'),
      );
    }
    if (_initialized) return Future<void>.value();
    return _initFuture ??= _doInit();
  }

  /// 激活监听、广播和可选的原生网络数据面。
  Future<void> activateReceiver() {
    if (_disposed) {
      return Future<void>.error(
        StateError('LAN receiver coordinator is disposed.'),
      );
    }
    return _activationFuture ??= _activateReceiver();
  }

  Future<void> _activateReceiver() async {
    try {
      await ensureInitialized();
      if (_receiverActive) return;
      await _startReceiverRuntime();
      final vm = await ensureViewModel();
      await vm.initialize();
      _receiverActive = true;
      _notifyListeners();
    } finally {
      _activationFuture = null;
    }
  }

  /// 停止 Feature listener/discovery 活动但保留 App-owned network runtime。
  Future<void> deactivateReceiver() async {
    if (!_receiverActive) return;
    await _viewModel?.shutdown();
    await _transferService?.stopListening();
    await _discoveryService?.stopAdvertising();
    await _detachBorrowedNetworkFacade();
    _receiverActive = false;
    _notifyListeners();
  }

  /// 创建或返回功能范围的 ViewModel。
  Future<LanShareViewModel> ensureViewModel() {
    if (_disposed) {
      return Future<LanShareViewModel>.error(
        StateError('LAN receiver coordinator is disposed.'),
      );
    }
    final existing = _viewModel;
    if (existing != null) return Future<LanShareViewModel>.value(existing);
    return _viewModelFuture ??= _createViewModel();
  }

  /// 使用共享接收器依赖构建 ViewModel。
  Future<LanShareViewModel> _createViewModel() async {
    LanShareViewModel? viewModel;
    try {
      await ensureInitialized();
      viewModel = LanShareViewModel(
        discoveryService: _discoveryService!,
        securityService: _securityService!,
        storageService: _lanStorageService!,
        transferService: _transferService!,
        nativeTransferCoordinator: _nativeTransferCoordinator,
        historyDao: historyRepository.dao,
        appSettings: appSettings,
        dataProtection: dataProtection,
        logger: logger,
        ownsRuntime: false,
        pairingRequestPublisher: publishPairingRequest,
      );
      if (_receiverActive) await viewModel.initialize();
      if (_disposed) {
        throw StateError('LAN receiver coordinator is disposed.');
      }
      for (final request in _latestPairingRequests.values) {
        if (!request.isExpired && request.peer.discovery != null) {
          viewModel.registerDiscoveredPeer(request.peer.discovery!);
        }
      }
      _viewModel = viewModel;
      return viewModel;
    } catch (_) {
      viewModel?.dispose();
      _viewModelFuture = null;
      rethrow;
    }
  }

  /// 创建服务并准备一次性身份、事件订阅和历史依赖。
  Future<void> _doInit() async {
    LanDiscoveryService? discovery;
    LanTransferService? transfer;
    LanRelayCoordinator? relay;
    try {
      await appSettings.ensureLanIdentity();
      final deviceId = appSettings.lanDeviceId;
      final deviceAlias = appSettings.lanDeviceAlias;
      discovery =
          discoveryServiceOverride ??
          LanDiscoveryService(
            currentDeviceId: deviceId,
            currentDeviceAlias: deviceAlias,
            localAddressSelectionPort: localAddressSelectionPort,
          );
      // Network identity belongs to App Scope and is needed by LAN security
      // even when this Feature's listener/runtime activation is disabled.
      // `initializeNetwork` only gates native capability/listener borrowing.
      final identity = await networkIdentity.loadOrCreate();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: identity.x25519PrivateSeed,
        peerTrustStore: peerTrustStore,
      );
      final lanStorage =
          storageServiceOverride ?? LanStorageService(logger: logger);
      final relayEnrollmentService = RelayEnrollmentService(
        currentDeviceId: deviceId,
        bootstrapClient: bootstrapClient,
      );
      relay = LanRelayCoordinator(
        appSettings: appSettings,
        logger: logger,
        enrollmentService: relayEnrollmentService,
        capability: _LanRelayCapabilityAdapter(networkRuntime),
        onChanged: _notifyIfActive,
      );
      transfer =
          transferServiceOverride ??
          LanTransferService(
            currentDeviceId: deviceId,
            securityService: security,
            storageService: lanStorage,
            networkIdentityPublicKeyProvider: () async => identity.publicKey,
            nativeTransferPortProvider: () =>
                networkRuntime.diagnostics.boundLocalPort,
          );

      _discoveryService = discovery;
      _securityService = security;
      _lanStorageService = lanStorage;
      _transferService = transfer;
      _relayCoordinator = relay;
      _listenToTransferEvents(transfer, discovery);
      if (security.activePin == null) security.generate6DigitPin();

      _initialized = true;
      if (initializeNetwork) await _startReceiverRuntime();
      _receiverActive = initializeNetwork;
      _notifyListeners();
      if (initializeNetwork) relay.connectConfiguredInBackground();
    } catch (_) {
      await _cancelReceiverSubscriptions();
      await discovery?.close();
      await transfer?.close();
      await _detachBorrowedNetworkFacade();
      await relay?.close();
      _discoveryService = null;
      _securityService = null;
      _lanStorageService = null;
      _transferService = null;
      _relayCoordinator = null;
      _initialized = false;
      _initFuture = null;
      rethrow;
    }
  }

  /// 启动 HTTPS/mDNS 和按需原生网络能力。
  Future<void> _startReceiverRuntime() async {
    if (!initializeNetwork) return;
    final transfer = _transferService;
    final discovery = _discoveryService;
    if (transfer == null || discovery == null) return;

    // The App Scope has already configured the shared native runtime. Borrow
    // its facade and restore the complete trust snapshot before starting the
    // HTTPS listener: once the control listener can accept trusted traffic,
    // the corresponding native peers must already be registered. The native
    // endpoint is independent of the HTTPS listener's bound port, so a
    // control-listener failure must not suppress inbound trust restoration.
    int? nativePort;
    if (_networkFacade == null) {
      final storage = _lanStorageService;
      if (storage != null) {
        try {
          await networkRuntime.ensureCapability(NetworkCapability.runtime);
          final facade = await networkAccess.borrowFacade();
          if (facade != null) {
            _networkFacade = facade;
            peerRegistry.attachFacade(facade);
            await peerRegistry.restoreAll();
            _nativeTransferCoordinator = LanNativeTransferCoordinator(
              transferService: transfer,
              networkFacade: facade,
              policyPort: peerRegistry,
              storageService: storage,
            );
            await _bindNativeOfferStream(_nativeTransferCoordinator!);
            final discoveredPeers = discovery.currentDiscoveredPeers;
            if (discoveredPeers.isNotEmpty) {
              await peerRegistry.syncDiscoveredEndpoints(discoveredPeers);
            }
            nativePort = networkRuntime.diagnostics.boundLocalPort;
            await _relayCoordinator?.attachFacade(facade);
            _relayCoordinator?.connectConfiguredInBackground();
          }
        } on Object catch (error, stackTrace) {
          logger.warning(
            'Native network runtime initialization failed',
            details: '$error\n$stackTrace',
          );
          await _detachBorrowedNetworkFacade();
        }
      }
    } else {
      nativePort = networkRuntime.diagnostics.boundLocalPort;
    }

    int? boundPort;
    if (!transfer.isListening) {
      final listenerResult = await transfer.startListening();
      if (listenerResult is NetworkFailure<int>) {
        logger.warning(
          'LAN listener failed',
          details: listenerResult.error.toString(),
        );
      } else {
        boundPort = (listenerResult as NetworkSuccess<int>).data;
      }
    } else {
      boundPort = transfer.activePort;
    }
    if (boundPort != null && nativePort == null) {
      final advertisingResult = await discovery.startAdvertising(
        port: boundPort,
      );
      if (advertisingResult is NetworkFailure<void>) {
        logger.warning(
          'LAN advertising failed',
          details: advertisingResult.error.toString(),
        );
      }
    }

    if (boundPort != null && nativePort != null) {
      final nativeAdvertisingResult = await discovery.startAdvertising(
        port: boundPort,
        nativePort: nativePort,
      );
      if (nativeAdvertisingResult is NetworkFailure<void>) {
        logger.warning(
          'LAN native endpoint advertising failed',
          details: nativeAdvertisingResult.error.toString(),
        );
      }
    }
  }

  /// 异步关闭所有由 Coordinator 使用的网络、传输、订阅和 ViewModel。
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    if (_disposed) return;
    _disposed = true;
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

    final viewModel = _viewModel;
    final transferService = _transferService;
    final discoveryService = _discoveryService;
    final relayCoordinator = _relayCoordinator;
    await attempt(() => viewModel?.shutdown());
    await attempt(() => viewModel?.dispose());
    _viewModel = null;
    await attempt(_cancelReceiverSubscriptions);
    await attempt(() => transferService?.stopListening());
    await attempt(() => discoveryService?.stopAdvertising());
    await attempt(_detachBorrowedNetworkFacade);
    await attempt(() => relayCoordinator?.close());
    _relayCoordinator = null;
    await attempt(() => discoveryService?.close());
    await attempt(() => transferService?.close());
    if (_ownsPeerTrustStore) {
      await attempt(peerTrustStore.dispose);
    }
    _transferService = null;
    _discoveryService = null;
    _securityService = null;
    _lanStorageService = null;
    _initialized = false;
    _receiverActive = false;
    if (!_pairingRequestController.isClosed) {
      await attempt(_pairingRequestController.close);
    }
    if (!_incomingTransferController.isClosed) {
      await attempt(_incomingTransferController.close);
    }
    _disposeNotifier();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}

/// 将 App Scope Runtime 收窄为 Relay Owner 可借用的单一能力。
final class _LanRelayCapabilityAdapter implements LanRelayCapabilityPort {
  const _LanRelayCapabilityAdapter(this._runtime);

  final NetworkRuntime _runtime;

  @override
  Future<void> ensureWebSocketRelay() =>
      _runtime.ensureCapability(NetworkCapability.webSocketRelay);
}
