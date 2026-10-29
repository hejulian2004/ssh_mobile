import 'package:connection_core/connection_core.dart';

/// 串行提交 Connection 结构、Host Key 和安全凭据，并在失败时逆序补偿。
///
/// 该协调器只编排 Repository 契约，不拥有数据库或 Secure Storage。调用方必须
/// 先完成网络验证，并把 Host Key 作为尚未发布的候选值传入。
final class ConnectionPersistenceCoordinator {
  ConnectionPersistenceCoordinator(
    this._connectionRepository,
    this._credentialRepository,
    this._hostKeyRepository,
  );

  final ConnectionRepository _connectionRepository;
  final CredentialRepository _credentialRepository;
  final HostKeyRepository _hostKeyRepository;

  /// 提交候选状态；任一步失败时恢复调用前的三类持久化状态。
  Future<void> commit({
    required ConnectionConfig stagedConfig,
    required ConnectionConfig? previousConfig,
    required String? previousPassword,
    required String? previousPrivateKey,
    required bool isEditing,
    required String? password,
    required String? privateKey,
    CredentialProtectionSnapshot? protectedSnapshot,
    bool Function()? isCredentialAccessCurrent,
  }) async {
    var connectionAttempted = false;
    var hostKeyAttempted = false;
    var credentialsAttempted = false;
    try {
      connectionAttempted = true;
      if (isEditing) {
        await _connectionRepository.updateConnection(stagedConfig);
      } else {
        await _connectionRepository.addConnection(stagedConfig);
      }

      hostKeyAttempted = true;
      await _hostKeyRepository.trustHostKey(
        stagedConfig.id,
        algorithm: stagedConfig.hostKeyAlgorithm,
        fingerprint: stagedConfig.hostKeyFingerprint,
        trustedAt: stagedConfig.hostKeyTrustedAt,
      );

      credentialsAttempted = true;
      if (protectedSnapshot != null) {
        await (_credentialRepository as CredentialProtectionRepository)
            .saveProtectedCredentials(
              connectionId: stagedConfig.id,
              password: password,
              privateKey: privateKey,
              expectedRevision: protectedSnapshot.revision,
              isCurrent: isCredentialAccessCurrent,
            );
      } else {
        await _credentialRepository.saveCredentials(
          connectionId: stagedConfig.id,
          password: password,
          privateKey: privateKey,
        );
      }
    } catch (error, stackTrace) {
      final rollbackErrors = <Object>[];
      if (credentialsAttempted) {
        await _captureRollbackError(rollbackErrors, () {
          if (protectedSnapshot != null) {
            return (_credentialRepository as CredentialProtectionRepository)
                .restoreProtectedSnapshot(protectedSnapshot);
          }
          return _credentialRepository.saveCredentials(
            connectionId: stagedConfig.id,
            password: previousPassword,
            privateKey: previousPrivateKey,
          );
        });
      }
      if (hostKeyAttempted) {
        await _captureRollbackError(rollbackErrors, () {
          return _hostKeyRepository.trustHostKey(
            stagedConfig.id,
            algorithm: previousConfig?.hostKeyAlgorithm,
            fingerprint: previousConfig?.hostKeyFingerprint,
            trustedAt: previousConfig?.hostKeyTrustedAt,
          );
        });
      }
      if (connectionAttempted) {
        await _captureRollbackError(rollbackErrors, () async {
          if (previousConfig != null) {
            await _connectionRepository.updateConnection(previousConfig);
            return;
          }
          // 提交前已确认该 ID 不存在；即使 add 在数据库落盘后才抛错，
          // 删除也只会清理本次尝试创建的记录。
          await _connectionRepository.deleteConnection(stagedConfig.id);
        });
      }
      if (rollbackErrors.isNotEmpty) {
        throw ConnectionSaveRollbackException(
          cause: error,
          rollbackErrors: List.unmodifiable(rollbackErrors),
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _captureRollbackError(
    List<Object> errors,
    Future<void> Function() rollback,
  ) async {
    try {
      await rollback();
    } catch (error) {
      errors.add(error);
    }
  }
}

/// 跨存储保存失败且补偿也未能全部完成。
///
/// [cause] 保留原始失败，[rollbackErrors] 明确暴露残留状态风险，调用方不得把
/// 该错误当作普通验证失败继续连接。
final class ConnectionSaveRollbackException implements Exception {
  const ConnectionSaveRollbackException({
    required this.cause,
    required this.rollbackErrors,
  });

  final Object cause;
  final List<Object> rollbackErrors;

  @override
  String toString() =>
      'Connection save failed and rollback was incomplete: $cause '
      '(rollback failures: ${rollbackErrors.length})';
}
