part of 'lan_receiver_coordinator.dart';

/// Stable event streams and ephemeral discovery observations.
extension LanReceiverCoordinatorObservation on LanReceiverCoordinator {
  /// 仅在 Coordinator 仍活跃时通知路由级观察者。
  void _notifyIfActive() {
    if (!_disposed && !_notifierDisposed) _notifyListeners();
  }

  /// 发布唯一 LAN 接收器收到的配对请求。
  Stream<LanPairingRequest> get pairingRequestStream =>
      _pairingRequestController.stream;

  /// 返回 [sessionId] 对应的未过期配对请求。
  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestPairingRequests[sessionId];
    if (request == null || request.isExpired) return null;
    return request;
  }

  /// 发布并保留一个未过期配对请求。
  void publishPairingRequest(LanPairingRequest request) {
    if (_disposed || request.isExpired) return;
    _latestPairingRequests.removeWhere((_, value) => value.isExpired);
    _latestPairingRequests[request.sessionId] = request;
    _pairingRequestController.add(request);
  }

  /// 将发现到的传入对端转换为配对请求。
  void _publishIncomingPeer(LanDiscoveredPeer peer) {
    publishPairingRequest(
      LanPairingRequest(
        peer: LanPeerViewState(discovery: peer),
        sessionId: const Uuid().v4(),
        isIncoming: true,
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      ),
    );
  }

  /// 创建服务并准备事件订阅；底层服务的创建归生命周期 part 所有。
  void _listenToTransferEvents(
    LanTransferService transfer,
    LanDiscoveryService discovery,
  ) {
    _pairingInviteSubscription = transfer.pairingInviteStream.listen(
      publishPairingRequest,
    );
    _announcedPeerSubscription = transfer.announcedPeerStream.listen(
      _publishIncomingPeer,
    );
    _handshakeSuccessSubscription = transfer.handshakeSuccessPeerStream.listen(
      (device) => unawaited(_registerNewlyPairedPeer(device)),
    );
    _discoveredPeersSubscription = discovery.discoveredPeersStream.listen(
      (peers) => unawaited(_syncDiscoveredEndpoints(peers)),
      onError: (Object error, StackTrace stackTrace) {
        logger.warning(
          'LAN discovery endpoint synchronization failed',
          details: '$error\n$stackTrace',
        );
      },
    );
  }

  Future<void> _syncDiscoveredEndpoints(
    Iterable<LanDiscoveredPeer> peers,
  ) async {
    try {
      await peerRegistry.syncDiscoveredEndpoints(peers);
    } on Object catch (error, stackTrace) {
      logger.warning(
        'LAN discovery endpoint synchronization failed',
        details: '$error\n$stackTrace',
      );
    }
  }

  /// 配对完成后立即同步当前 native runtime 的完整信任注册。
  Future<void> _registerNewlyPairedPeer(LanDiscoveredPeer peer) async {
    final facade = _networkFacade;
    if (facade == null || _disposed) return;
    try {
      if (_disposed || !identical(_networkFacade, facade)) return;
      final trust = await peerTrustStore.read(peer.deviceId);
      if (trust == null) return;
      final registerResult = await peerRegistry.reconcilePersistedTrust(trust);
      if (registerResult is NetworkFailure<void>) {
        logger.warning(
          'Native paired peer registration failed',
          details: registerResult.error.toString(),
        );
        return;
      }
      // The handshake event has no native port. Observing that incomplete
      // peer clears a direct endpoint the discovery record still advertises.
      final endpointPeer = _endpointPeerForPairing(peer);
      if (endpointPeer != null) {
        await peerRegistry.observeDiscoveredEndpoint(endpointPeer);
      }
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Native paired peer synchronization failed',
        details: '$error\n$stackTrace',
      );
    }
  }

  /// 把每一代 Facade 的 offer 事件桥接到 Coordinator 稳定生命周期流。
  Future<void> _bindNativeOfferStream(
    LanNativeTransferCoordinator nativeTransfer,
  ) async {
    await _nativeOfferSubscription?.cancel();
    _nativeOfferSubscription = nativeTransfer.incomingOffers.listen(
      (offer) => unawaited(_publishTrustedIncomingOffer(offer)),
      onError: (Object error, StackTrace stackTrace) {
        logger.warning(
          'Native incoming transfer stream failed',
          details: '$error\n$stackTrace',
        );
      },
    );
  }

  Future<void> _publishTrustedIncomingOffer(IncomingTransferOffer offer) async {
    if (_disposed || _incomingTransferController.isClosed) return;
    final trust = await peerTrustStore.read(offer.peerId);
    if (trust == null ||
        !isIncomingRouteAuthorized(trust.authorization, offer.routeType)) {
      return;
    }
    if (!_disposed && !_incomingTransferController.isClosed) {
      _incomingTransferController.add(offer);
    }
  }

  /// 已有发现记录优先。没有 native 端口的事件不能拿来更新数据面。
  LanDiscoveredPeer? _endpointPeerForPairing(LanDiscoveredPeer event) {
    final peers = _discoveryService?.currentDiscoveredPeers;
    if (peers != null) {
      for (final candidate in peers) {
        if (candidate.deviceId != event.deviceId) continue;
        return _hasAdvertisedDirectEndpoint(candidate) ? candidate : null;
      }
    }
    return _hasAdvertisedDirectEndpoint(event) ? event : null;
  }

  /// 取消接收器持有的 LAN 事件订阅。
  Future<void> _cancelReceiverSubscriptions() async {
    await _pairingInviteSubscription?.cancel();
    _pairingInviteSubscription = null;
    await _announcedPeerSubscription?.cancel();
    _announcedPeerSubscription = null;
    await _handshakeSuccessSubscription?.cancel();
    _handshakeSuccessSubscription = null;
    await _discoveredPeersSubscription?.cancel();
    _discoveredPeersSubscription = null;
  }

  /// 撤销 Feature 对 App-owned Facade 的借用与订阅；不停止或释放共享 Runtime。
  Future<void> _detachBorrowedNetworkFacade() async {
    _networkFacade = null;
    peerRegistry.detachFacade();
    await _nativeOfferSubscription?.cancel();
    _nativeOfferSubscription = null;
    await _nativeTransferCoordinator?.dispose();
    _nativeTransferCoordinator = null;
    await _relayCoordinator?.detachFacade();
  }
}

bool _hasAdvertisedDirectEndpoint(LanDiscoveredPeer peer) {
  final port = peer.advertisedNativePort;
  return port != null &&
      port >= 1 &&
      port <= 65535 &&
      peer.ip.trim().isNotEmpty;
}
