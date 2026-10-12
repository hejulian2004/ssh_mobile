part of 'lan_share_viewmodel.dart';

extension LanShareViewModelCommands on LanShareViewModel {
  /// 启动 LAN 发现并刷新 UI 状态。
  Future<NetworkResult<void>> _startScanning() async {
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
    if (!_disposed) _notifyStateChanged();
    return result;
  }

  /// 停止 LAN 发现并刷新 UI 状态。
  Future<NetworkResult<void>> _stopScanning() async {
    _lastScanError = null;
    final result = await discoveryService.stopDiscovery();
    if (!_disposed) _notifyStateChanged();
    return result;
  }

  /// 启动或停止固定使用 HTTPS 的 WebShare。
  Future<NetworkResult<void>> _toggleWebShare() async {
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
    if (!_disposed) _notifyStateChanged();
    return result;
  }

  /// 发送文本消息，并持久化稳定结果码。
  Future<NetworkResult<void>> _sendText(
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
  Future<NetworkResult<void>> _sendClipboard(
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
  Future<NetworkResult<TransferSession>> _sendFile({
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
  Future<NetworkResult<TransferSession>> _sendFileToDiscoveredPeer(
    LanDiscoveredPeer device,
    String filePath,
  ) => sendFile(peerId: device.deviceId, filePath: filePath, discovery: device);

  /// 远端撤回消息，并将本地历史记录标记为已撤回。
  Future<NetworkResult<void>> _recallMessage(
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
  Future<void> _clearHistory() async {
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
    if (!_disposed) _notifyStateChanged();
  }

  /// 删除一条 LAN 历史记录并清理对应沙箱文件。
  Future<void> _deleteMessage(String messageId) async {
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
    if (!_disposed) _notifyStateChanged();
  }

  /// 解除设备配对； native peer removal is owned by the transfer coordinator.
  Future<NetworkResult<void>> _forgetDevice(String deviceId) async {
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
    try {
      await transferService.disconnectPairedPeer(deviceId);
      final result = await coordinator.removeTrustedPeer(deviceId);
      if (result is NetworkSuccess<void>) {
        _trustRecords.remove(deviceId);
        _devices.removeWhere((peer) => peer.deviceId == deviceId);
        discoveryService.removeDiscoveredPeer(deviceId);
        _peerMetadata.remove(deviceId);
        _onlinePeerIds.remove(deviceId);
        _onlineSince.remove(deviceId);
        _latestPairingRequests.removeWhere(
          (_, request) => request.peer.peerId == deviceId,
        );
        await _peerMetadataWrites;
        await pairingMetadataDao?.deleteDevice(deviceId);
        if (!_disposed) _notifyStateChanged();
      }
      return result;
    } catch (error) {
      logger.warning(
        'LAN device unpair failed',
        details: 'errorType=${error.runtimeType}',
      );
      if (!_disposed) _notifyStateChanged();
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.removePeer,
          peerId: deviceId,
        ),
      );
    }
  }

  /// 设置对端设备的 Relay 传输授权策略。
  Future<NetworkResult<void>> _setRelayAuthorization(
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
      if (!_disposed) _notifyStateChanged();
    }
    return result;
  }

  /// 删除一个对端关联的全部历史和文件。
  Future<void> _clearChatHistory(String targetDeviceId) async {
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
    if (!_disposed) _notifyStateChanged();
  }
}
