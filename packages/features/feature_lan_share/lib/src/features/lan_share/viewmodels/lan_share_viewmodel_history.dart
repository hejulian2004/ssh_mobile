// 从功能 ViewModel 拆出的 LAN 历史持久化与载荷映射。
// 确保每个源码文件低于 1000 行维护限制。

part of 'lan_share_viewmodel.dart';

extension LanShareViewModelHistory on LanShareViewModel {
  /// 在写入数据库前加密一项敏感历史字段。
  Future<String?> _encryptSensitive(String? value) {
    if (value == null) return Future<String?>.value();
    return dataProtection.encryptString(value);
  }

  /// 从数据库读取后解密一项敏感历史字段。
  Future<String?> _decryptSensitive(String? value) async {
    if (value == null) return null;
    return dataProtection.decryptString(value);
  }

  /// 将一条 LAN 消息写入持久化历史数据库。
  Future<void> _saveMessageToDb(LanMessage msg) async {
    await historyDao.insertRecord(
      LanTransferRecordsCompanion(
        id: Value(msg.id),
        senderId: Value(msg.senderId),
        senderAlias: Value(msg.senderAlias),
        receiverId: Value(msg.receiverId),
        payloadType: Value(msg.payloadType.toJson()),
        textContent: Value(await _encryptSensitive(msg.textContent)),
        fileName: Value(msg.fileName),
        fileSize: Value(msg.fileSize),
        localPath: Value(msg.localPath),
        manifestJson: Value(
          await _encryptSensitive(msg.manifest?.encodeJson()),
        ),
        status: Value(msg.status.toJson()),
        bytesTransferred: Value(msg.bytesTransferred),
        createdAt: Value(msg.createdAt.millisecondsSinceEpoch),
        isIncoming: Value(msg.isIncoming),
        isRecalled: Value(msg.isRecalled),
        sftpServerId: Value(msg.sftpServerId),
        sftpRemotePath: Value(await _encryptSensitive(msg.sftpRemotePath)),
        routeType: Value(msg.routeType?.name),
        bytesTotal: Value(msg.fileSize),
      ),
    );
  }

  /// 串行化一条消息的更新，避免进度事件打乱历史顺序。
  Future<void> _enqueueMessagePersistence(
    String messageId,
    Future<void> Function() operation,
  ) async {
    final previous = _messagePersistence[messageId] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) => operation());
    _messagePersistence[messageId] = next;
    try {
      await next;
    } finally {
      if (identical(_messagePersistence[messageId], next)) {
        _messagePersistence.remove(messageId);
      }
    }
  }

  /// 将一条数据库记录转换为已解密的功能消息。
  Future<LanMessage> _mapRecordToMessage(LanTransferRecord record) async {
    final textContent = await _decryptSensitive(record.textContent);
    final manifestJson = await _decryptSensitive(record.manifestJson);
    final sftpRemotePath = await _decryptSensitive(record.sftpRemotePath);
    if ((record.textContent != null &&
            !dataProtection.isEncrypted(record.textContent!)) ||
        (record.manifestJson != null &&
            !dataProtection.isEncrypted(record.manifestJson!)) ||
        (record.sftpRemotePath != null &&
            !dataProtection.isEncrypted(record.sftpRemotePath!))) {
      await historyDao.updateSensitiveFields(
        record.id,
        textContent: Value(await _encryptSensitive(textContent)),
        manifestJson: Value(await _encryptSensitive(manifestJson)),
        sftpRemotePath: Value(await _encryptSensitive(sftpRemotePath)),
      );
    }
    return LanMessage(
      id: record.id,
      senderId: record.senderId,
      senderAlias: record.senderAlias,
      receiverId: record.receiverId,
      payloadType: LanPayloadType.fromJson(record.payloadType),
      textContent: textContent,
      fileName: record.fileName,
      fileSize: record.fileSize,
      localPath: record.localPath,
      manifest: manifestJson != null
          ? FileManifest.decodeJson(manifestJson)
          : null,
      status: LanTransferStatus.fromJson(record.status),
      routeType: networkRouteTypeFromJson(record.routeType),
      bytesTransferred: record.bytesTransferred,
      createdAt: DateTime.fromMillisecondsSinceEpoch(record.createdAt),
      isIncoming: record.isIncoming,
      isRecalled: record.isRecalled,
      sftpServerId: record.sftpServerId,
      sftpRemotePath: sftpRemotePath,
      failureReason: record.failureReason,
    );
  }

  /// 根据数据库监听记录重建内存历史。
  Future<void> _refreshHistory(List<LanTransferRecord> records) async {
    final mapped = await Future.wait(records.map(_mapRecordToMessage));
    if (_disposed) return;
    _history = mapped;
    _notifyHistoryChanged();
  }
}
