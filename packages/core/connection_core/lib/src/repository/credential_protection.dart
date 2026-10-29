import 'dart:typed_data';

/// 一次显式解锁返回完整凭据；不得进入日志、连接 JSON 或明文回滚快照。
final class CredentialPair {
  const CredentialPair({this.password, this.privateKey, this.revision});

  final String? password;
  final String? privateKey;
  final String? revision;
}

/// Android Keystore 等平台认证加密能力的不可变密文结果。
final class CredentialCiphertext {
  CredentialCiphertext({required Uint8List iv, required Uint8List ciphertext})
    : iv = Uint8List.fromList(iv).asUnmodifiableView(),
      ciphertext = Uint8List.fromList(ciphertext).asUnmodifiableView();

  final Uint8List iv;
  final Uint8List ciphertext;
}

/// 平台拥有 AES-GCM 密钥与认证会话；AAD 必须绑定规范连接 ID 和随机 revision。
abstract interface class CredentialCryptoPort {
  bool get supportsProtection;
  Future<CredentialCiphertext> seal({
    required String connectionId,
    required String revision,
    required Uint8List plaintext,
  });
  Future<Uint8List> open({
    required String connectionId,
    required String revision,
    required CredentialCiphertext ciphertext,
  });
  Future<void> removeKey({
    required String connectionId,
    required String revision,
  });
}

enum CredentialProtectionError {
  locked,
  corrupt,
  unsupported,
  cancelled,
  stale,
  authenticationFailed,
  keyInvalidated,
  storageFailure,
}

/// 只公开稳定错误码；原生异常、密码、私钥和存储内容不得出现在异常文本中。
final class CredentialProtectionException implements Exception {
  const CredentialProtectionException(this.code);
  final CredentialProtectionError code;
  @override
  String toString() => 'CredentialProtectionException: ${code.name}';
}

/// 无秘密读取的保护事务租约，只能由创建它的 Repository 恢复或释放。
abstract interface class CredentialProtectionSnapshot {
  String get connectionId;
  String get revision;
}

/// 可选保护能力；基础 CredentialRepository 对未保护调用方保持兼容。
abstract interface class CredentialProtectionRepository {
  bool get supportsProtection;
  Future<bool> isProtected(String connectionId);
  Future<String?> protectionRevision(String connectionId);
  Future<void> enableProtection(
    String connectionId, {
    bool Function()? isCurrent,
  });
  Future<CredentialPair> unlockCredentials(
    String connectionId, {
    String? expectedRevision,
  });
  Future<void> disableProtection(
    String connectionId, {
    String? expectedRevision,
    bool Function()? isCurrent,
  });
  Future<void> saveProtectedCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
    String? expectedRevision,
    bool Function()? isCurrent,
  });
  Future<CredentialProtectionSnapshot> captureProtectedSnapshot(
    String connectionId,
  );
  Future<void> restoreProtectedSnapshot(CredentialProtectionSnapshot snapshot);
  Future<void> discardProtectedSnapshot(CredentialProtectionSnapshot snapshot);
}
