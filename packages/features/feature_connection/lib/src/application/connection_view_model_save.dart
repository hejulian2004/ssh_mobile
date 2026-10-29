part of 'connection_view_model.dart';

/// 保存事务与认证快照归属；与删除/排序共用 ViewModel mutation queue。
extension _ConnectionSaveActions on ConnectionViewModel {
  /// 验证登录、处理 Host Key、确认活动窗口后保存连接和凭据。
  Future<bool> _verifyAndSaveConnection({
    required ConnectionConfig config,
    required bool isEditing,
    required String? rawPassword,
    required String? rawPrivateKey,
    required Future<bool> Function(int activeWindows) confirmDisconnectCallback,
    ConnectionHostKeyConfirmation? onUnknownHostKey,
    String? expectedCredentialRevision,
    bool Function()? isCredentialAccessCurrent,
  }) async {
    // Route 已核验其冻结目标；在任何 await/通知前接管该次 original → staged 审批。
    final originalTarget = jsonEncode(
      _connectionRepository.getConnection(config.id)?.toJson(),
    );
    void requireOriginalAccess() {
      if (!(isCredentialAccessCurrent?.call() ?? true) ||
          jsonEncode(
                _connectionRepository.getConnection(config.id)?.toJson(),
              ) !=
              originalTarget) {
        throw const CredentialProtectionException(
          CredentialProtectionError.stale,
        );
      }
    }

    final generation = _beginOperation();
    if (generation == null) return false;
    _isSaving = true;
    _isVerifying = true;
    _errorMessage = null;
    _notifyIfCurrent(generation);
    if (!_isCurrent(generation)) return false;

    try {
      final protection = _credentialRepository is CredentialProtectionRepository
          ? _credentialRepository as CredentialProtectionRepository
          : null;
      final wasProtected =
          protection != null && await protection.isProtected(config.id);
      final originalRevision = wasProtected
          ? await protection.protectionRevision(config.id)
          : null;
      requireOriginalAccess();
      if ((wasProtected && originalRevision == null) ||
          (expectedCredentialRevision != null &&
              originalRevision != expectedCredentialRevision)) {
        throw const CredentialProtectionException(
          CredentialProtectionError.stale,
        );
      }
      final stagedConfig = _copyForVerification(
        config,
        password: null,
        privateKey: null,
      );
      if (!kIsWeb) {
        final clientConfig = _copyForVerification(
          config,
          password: rawPassword,
          privateKey: rawPrivateKey,
        );
        final result = await _verificationPort.verify(
          clientConfig,
          password: rawPassword,
          privateKey: rawPrivateKey,
          onUnknownHostKey: onUnknownHostKey,
        );
        if (!_isCurrent(generation)) return false;
        stagedConfig.hostKeyAlgorithm =
            result.algorithm ?? stagedConfig.hostKeyAlgorithm;
        stagedConfig.hostKeyFingerprint =
            result.fingerprint ?? stagedConfig.hostKeyFingerprint;
        stagedConfig.hostKeyTrustedAt =
            result.trustedAt ?? stagedConfig.hostKeyTrustedAt;
      }

      if (!_isCurrent(generation)) return false;
      _isVerifying = false;
      _notifyIfCurrent(generation);
      if (!_isCurrent(generation)) return false;

      final activeWindowCount = isEditing
          ? await _runtimePort.activeWindowCount(config.id)
          : 0;
      if (!_isCurrent(generation)) return false;
      if (activeWindowCount > 0) {
        _isSaving = false;
        _notifyIfCurrent(generation);
        if (!_isCurrent(generation)) return false;
        final confirmed = await confirmDisconnectCallback(activeWindowCount);
        if (!_isCurrent(generation)) return false;
        if (!confirmed) return false;
        _isSaving = true;
        _notifyIfCurrent(generation);
        if (!_isCurrent(generation)) return false;
      }

      return await _runMutationExclusive(() async {
        if (!_isCurrent(generation)) return false;
        final previous = _connectionRepository.getConnection(config.id);
        if (isEditing && previous == null) {
          throw StateError('Connection does not exist: ${config.id}');
        }
        if (!isEditing && previous != null) {
          throw StateError('Connection id already exists: ${config.id}');
        }
        final previousConfig = previous == null
            ? null
            : ConnectionConfig.fromJson(previous.toJson());
        requireOriginalAccess();
        CredentialProtectionSnapshot? protectedSnapshot;
        String? previousPassword;
        String? previousPrivateKey;
        if (wasProtected) {
          protectedSnapshot = await protection.captureProtectedSnapshot(
            config.id,
          );
        }
        try {
          if (!_isCurrent(generation)) return false;
          requireOriginalAccess();
          if (wasProtected) {
            if (protectedSnapshot!.revision != originalRevision ||
                jsonEncode(previousConfig?.toJson()) != originalTarget ||
                !(isCredentialAccessCurrent?.call() ?? true)) {
              throw const CredentialProtectionException(
                CredentialProtectionError.stale,
              );
            }
          } else {
            previousPassword = await _credentialRepository.getPassword(
              config.id,
            );
            if (!_isCurrent(generation)) return false;
            previousPrivateKey = await _credentialRepository.getPrivateKey(
              config.id,
            );
            if (!_isCurrent(generation)) return false;
          }

          // 先停止仍绑定旧端点的 Session；持久化阶段开始后不再因 Route 状态变化
          // 中途退出，避免只写入配置、Host Key 或凭据中的一部分。
          if (isEditing && activeWindowCount > 0) {
            await _runtimePort.disconnectSessionsForConnection(config.id);
            if (!_isCurrent(generation)) return false;
          }

          requireOriginalAccess();

          await _persistenceCoordinator.commit(
            stagedConfig: stagedConfig,
            previousConfig: previousConfig,
            previousPassword: previousPassword,
            previousPrivateKey: previousPrivateKey,
            isEditing: isEditing,
            password: rawPassword,
            privateKey: rawPrivateKey,
            protectedSnapshot: protectedSnapshot,
            isCredentialAccessCurrent: () =>
                _isCurrent(generation) &&
                (isCredentialAccessCurrent?.call() ?? true) &&
                jsonEncode(
                      _connectionRepository.getConnection(config.id)?.toJson(),
                    ) ==
                    jsonEncode(stagedConfig.toJson()),
          );

          // 只有三类持久化都成功后才把 Host Key 候选发布给调用方对象。
          config.hostKeyAlgorithm = stagedConfig.hostKeyAlgorithm;
          config.hostKeyFingerprint = stagedConfig.hostKeyFingerprint;
          config.hostKeyTrustedAt = stagedConfig.hostKeyTrustedAt;
          if (!_isCurrent(generation)) return false;
          _connections = List.unmodifiable(_connectionRepository.connections);
          return true;
        } finally {
          if (protectedSnapshot != null) {
            await protection!.discardProtectedSnapshot(protectedSnapshot);
          }
        }
      });
    } catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _errorMessage = error.toString();
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (_isCurrent(generation)) {
        _isVerifying = false;
        _isSaving = false;
        _notifyIfCurrent(generation);
      }
    }
  }
}
