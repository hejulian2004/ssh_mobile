import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../model/connection_profile.dart';
import 'credential_repository.dart';
import 'credential_protection.dart';
import 'protected_credential_record.dart';

part 'secure_credential_protection.dart';
part 'secure_credential_snapshots.dart';

/// Secure Storage 最小适配契约，便于在不触碰真实 Keychain/KeyStore 的情况下测试。
abstract interface class SecureStorageClient {
  /// 读取一个受保护值。
  Future<String?> read({required String key});

  /// 写入一个受保护值。
  Future<void> write({required String key, required String value});

  /// 删除一个受保护值。
  Future<void> delete({required String key});
}

/// 对 FlutterSecureStorage 的最小适配，统一插件生命周期边界。
final class FlutterSecureStorageClient implements SecureStorageClient {
  /// 使用应用统一的安全存储默认配置。
  FlutterSecureStorageClient({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

/// 将 Connection 密码和私钥绑定到平台 Secure Storage 的 Repository。
///
/// 键名带有模块前缀，避免与其它 SharedPreferences/Secret
/// 键混用；空值通过 delete 写入路径处理，避免把空字符串误认为有效凭据。
final class SecureCredentialRepository
    implements CredentialRepository, CredentialProtectionRepository {
  /// 密码键前缀。
  static const passwordKeyPrefix = 'connection.v2.password.';

  /// 私钥键前缀。
  static const privateKeyKeyPrefix = 'connection.v2.private_key.';

  static const _legacyPasswordKeyPrefix = 'connection.password.';
  static const _legacyPrivateKeyKeyPrefix = 'connection.private_key.';

  /// 创建一个使用注入安全存储客户端的凭据 Repository。
  SecureCredentialRepository({
    SecureStorageClient? storage,
    CredentialCryptoPort? crypto,
  }) : _storage = storage ?? FlutterSecureStorageClient(),
       // ignore: prefer_initializing_formals
       _crypto = crypto;

  final SecureStorageClient _storage;
  final CredentialCryptoPort? _crypto;
  final _queues = <String, Future<void>>{};
  final _snapshots = <_SecureCredentialSnapshot>{};

  @override
  bool get supportsProtection => _crypto?.supportsProtection ?? false;

  Future<T> _serial<T>(String id, Future<T> Function() action) {
    final previous = _queues[id] ?? Future<void>.value();
    final released = Completer<void>();
    _queues[id] = released.future;
    return (() async {
      await previous;
      try {
        return await action();
      } finally {
        released.complete();
        if (identical(_queues[id], released.future)) _queues.remove(id);
      }
    })();
  }

  @override
  Future<bool> isProtected(String connectionId) {
    final id = _protectionId(connectionId);
    return _serial(id, () async => await _record(id) != null);
  }

  @override
  Future<String?> protectionRevision(String connectionId) {
    final id = _protectionId(connectionId);
    return _serial(id, () async => (await _record(id))?.revision);
  }

  @override
  Future<void> enableProtection(
    String connectionId, {
    bool Function()? isCurrent,
  }) {
    final id = _protectionId(connectionId);
    return _serial(id, () => _enable(id, isCurrent));
  }

  @override
  Future<CredentialPair> unlockCredentials(
    String connectionId, {
    String? expectedRevision,
  }) {
    final id = _protectionId(connectionId);
    return _serial(id, () => _unlock(id, expectedRevision));
  }

  @override
  Future<void> disableProtection(
    String connectionId, {
    String? expectedRevision,
    bool Function()? isCurrent,
  }) {
    final id = _protectionId(connectionId);
    return _serial(id, () => _disable(id, expectedRevision, isCurrent));
  }

  @override
  Future<void> saveProtectedCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
    String? expectedRevision,
    bool Function()? isCurrent,
  }) {
    final id = _protectionId(connectionId);
    return _serial(
      id,
      () =>
          _saveProtected(id, password, privateKey, expectedRevision, isCurrent),
    );
  }

  @override
  Future<CredentialProtectionSnapshot> captureProtectedSnapshot(
    String connectionId,
  ) {
    final id = _protectionId(connectionId);
    return _serial(id, () => _captureSnapshot(id));
  }

  @override
  Future<void> restoreProtectedSnapshot(CredentialProtectionSnapshot snapshot) {
    final owned = _ownedSnapshot(snapshot);
    return _serial(owned.connectionId, () => _restoreSnapshot(owned));
  }

  @override
  Future<void> discardProtectedSnapshot(CredentialProtectionSnapshot snapshot) {
    final owned = _ownedSnapshot(snapshot);
    return _serial(owned.connectionId, () => _discardSnapshot(owned));
  }

  @override
  Future<String?> getPassword(String connectionId) {
    final id = requireCanonicalConnectionId(connectionId);
    return _serial(id, () async {
      await _requireUnprotected(id);
      return _readWithLegacyMigration(
        currentKey: _passwordKey(id),
        legacyKey: '$_legacyPasswordKeyPrefix$id',
      );
    });
  }

  @override
  Future<String?> getPrivateKey(String connectionId) {
    final id = requireCanonicalConnectionId(connectionId);
    return _serial(id, () async {
      await _requireUnprotected(id);
      return _readWithLegacyMigration(
        currentKey: _privateKeyKey(id),
        legacyKey: '$_legacyPrivateKeyKeyPrefix$id',
      );
    });
  }

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {
    final id = requireCanonicalConnectionId(connectionId);
    await _serial(id, () async {
      await _requireUnprotected(id);
      _markUnprotectedMutation(id);
      await _writeOrDelete(_passwordKey(id), password);
      await _writeOrDelete(_privateKeyKey(id), privateKey);
      await _storage.delete(key: '$_legacyPasswordKeyPrefix$id');
      await _storage.delete(key: '$_legacyPrivateKeyKeyPrefix$id');
    });
  }

  @override
  Future<void> deleteCredentials(String connectionId) {
    final id = requireCanonicalConnectionId(connectionId);
    return _serial(id, () => _deleteAllCredentials(id));
  }

  Future<String?> _readWithLegacyMigration({
    required String currentKey,
    required String legacyKey,
  }) async {
    final current = await _storage.read(key: currentKey);
    if (current != null) {
      final staleLegacy = await _storage.read(key: legacyKey);
      if (staleLegacy != null) await _storage.delete(key: legacyKey);
      return current;
    }
    final legacy = await _storage.read(key: legacyKey);
    if (legacy == null) return null;
    if (legacy.isEmpty) {
      await _storage.delete(key: legacyKey);
      return null;
    }
    // 先写新键再删旧键；迁移中断时至少保留一份可恢复的秘密。
    await _storage.write(key: currentKey, value: legacy);
    await _storage.delete(key: legacyKey);
    return legacy;
  }

  Future<void> _writeOrDelete(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  String _passwordKey(String connectionId) =>
      '$passwordKeyPrefix${_encodedId(connectionId)}';

  String _privateKeyKey(String connectionId) =>
      '$privateKeyKeyPrefix${_encodedId(connectionId)}';

  String _encodedId(String connectionId) => base64UrlEncode(
    utf8.encode(requireCanonicalConnectionId(connectionId)),
  ).replaceAll('=', '');
}
