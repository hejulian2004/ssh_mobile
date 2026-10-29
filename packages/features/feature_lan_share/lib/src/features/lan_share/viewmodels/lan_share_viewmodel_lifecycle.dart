part of 'lan_share_viewmodel.dart';

extension LanShareViewModelLifecycle on LanShareViewModel {
  /// 初始化订阅，并在拥有运行时的情况下初始化 LAN 运行时。
  Future<void> _beginInitialize() {
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

    appSettings.addListener(_settingsChangedListener);

    try {
      await _loadTrustProjection();
      await _loadPeerMetadata();
    } catch (_) {
      appSettings.removeListener(_settingsChangedListener);
      await _cancelRuntimeSubscriptions();
      _initializationFuture = null;
      rethrow;
    }
    if (_disposed || generation != _lifecycleGeneration) {
      appSettings.removeListener(_settingsChangedListener);
      await _cancelRuntimeSubscriptions();
      return;
    }

    // 在打开监听器前先订阅，避免 HTTPS/mDNS 启动期间到达的邀请被确认后丢失。
    _devicesSubscription = discoveryService.discoveredPeersStream.listen((
      devs,
    ) {
      _applyDiscoveredPeers(devs);
      if (!_disposed) _notifyStateChanged();
    });
    _applyDiscoveredPeers(discoveryService.currentDiscoveredPeers);
    _incomingMessageSubscription = transferService.incomingMessageStream.listen(
      (msg) {
        _trackBackgroundOperation(
          _enqueueMessagePersistence(msg.id, () async {
            await _saveMessageToDb(msg);
            _emitNotification(incomingMessageNotification(msg));
          }),
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
    _observedPeerSubscription = transferService.observedPeerStream.listen(
      _notePairingObservation,
    );
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
      _refreshOnlinePresence();
      if (!_disposed) _notifyStateChanged();
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
        _refreshOnlinePresence();
        if (!_disposed) _notifyStateChanged();
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
      appSettings.removeListener(_settingsChangedListener);
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
    if (_disposed) return;
    try {
      final trustStore = securityService.peerTrustStore;
      _trustSubscription = trustStore.changes.listen((records) {
        if (_disposed) return;
        _trustRecords
          ..clear()
          ..addEntries(
            records.map((record) => MapEntry(record.deviceId, record)),
          );
        _applyDiscoveredPeers(_devices);
        _notifyStateChanged();
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
      _observedPeerSubscription,
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
    _observedPeerSubscription = null;
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
      if (transferService.hasPendingPairing(device.deviceId)) {
        discoveryService.touchDiscoveredPeer(device.deviceId);
      }
      final paired = await isDevicePaired(device.deviceId);
      if (_disposed || !_isInitialized || generation != _lifecycleGeneration) {
        return;
      }
      if (!paired) continue;
      final connected = await transferService.connectWebSocket(device);
      if (_disposed || !_isInitialized || generation != _lifecycleGeneration) {
        return;
      }
      if (connected is NetworkSuccess<void>) {
        discoveryService.touchDiscoveredPeer(device.deviceId);
      }
    }
  }

  /// 握手证明只刷新已有发现记录的 lastSeen。
  ///
  /// 证明里没有 native 端口，直接替换会把二维码登记的数据面地址清掉。
  void _notePairingObservation(LanDiscoveredPeer peer) {
    if (_disposed) return;
    if (discoveryService.touchDiscoveredPeer(peer.deviceId)) return;
    registerDiscoveredPeer(peer);
  }

  /// 注册手动解析的对端并刷新监听器。
  void _registerPeer(LanDiscoveredPeer device) {
    if (_disposed) return;
    discoveryService.registerDiscoveredPeer(device);
    _notifyStateChanged();
  }

  /// 将变更后的应用设置应用到活动发现服务。
  void _onSettingsChanged() {
    if (_disposed) return;
    unawaited(discoveryService.updateDeviceAlias(appSettings.lanDeviceAlias));
    _notifyStateChanged();
  }

  /// 关闭 ViewModel 持有的资源，且只执行一次。
  Future<void> _beginShutdown() {
    return _shutdownFuture ??= _shutdown();
  }

  /// 执行串行化的 ViewModel 关闭流程。
  Future<void> _shutdown() async {
    _lifecycleGeneration++;
    for (final peerId in _pairingConnections.keys.toList()) {
      cancelPairingConnection(peerId);
    }
    _isInitialized = false;
    appSettings.removeListener(_settingsChangedListener);
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

    await attempt(_cancelDocumentOperations);
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
    if (!_disposed) _notifyStateChanged();
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
}
