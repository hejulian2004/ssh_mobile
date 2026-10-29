part of 'secure_credential_repository.dart';

/// 显式认证状态迁移；每次加密使用不可复用 revision，不在失败时回退明文读取。
extension _CredentialProtectionTransitions on SecureCredentialRepository {
  String _protectionId(String value) {
    final id = requireCanonicalConnectionId(value);
    if (id.length > 256) {
      throw ArgumentError.value(id.length, 'connectionId.length');
    }
    return id;
  }

  void _current(bool Function()? check) {
    if (check != null && !check()) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
  }

  CredentialCryptoPort get _platformCrypto {
    final crypto = _crypto;
    if (crypto == null || !crypto.supportsProtection) {
      throw const CredentialProtectionException(
        CredentialProtectionError.unsupported,
      );
    }
    return crypto;
  }

  Future<T> _safe<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on CredentialProtectionException {
      rethrow;
    } catch (_) {
      throw const CredentialProtectionException(
        CredentialProtectionError.storageFailure,
      );
    }
  }

  Future<void> _requireUnprotected(String id) async {
    if (await _record(id) != null) {
      throw const CredentialProtectionException(
        CredentialProtectionError.locked,
      );
    }
  }

  String _protectedKey(String id) =>
      'connection.v3.protected.${_encodedId(id)}';
  String _revisionKey(String id) => 'connection.v3.revisions.${_encodedId(id)}';
  Future<String?> _rawRecord(String id) =>
      _safe(() => _storage.read(key: _protectedKey(id)));
  Future<ProtectedCredentialRecord?> _record(String id) async {
    final raw = await _rawRecord(id);
    return raw == null ? null : ProtectedCredentialRecord.decode(id, raw);
  }

  Future<void> _writeRecord(ProtectedCredentialRecord record) async {
    final value = record.encode();
    await _safe(
      () =>
          _storage.write(key: _protectedKey(record.connectionId), value: value),
    );
    if (await _rawRecord(record.connectionId) != value) {
      throw const CredentialProtectionException(
        CredentialProtectionError.storageFailure,
      );
    }
  }

  Future<CredentialPair> _plainPair(String id) async => CredentialPair(
    password: await _readWithLegacyMigration(
      currentKey: _passwordKey(id),
      legacyKey: '${SecureCredentialRepository._legacyPasswordKeyPrefix}$id',
    ),
    privateKey: await _readWithLegacyMigration(
      currentKey: _privateKeyKey(id),
      legacyKey: '${SecureCredentialRepository._legacyPrivateKeyKeyPrefix}$id',
    ),
  );

  Future<void> _enable(String id, bool Function()? check) async {
    _platformCrypto;
    _current(check);
    if (await _record(id) != null) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
    _current(check);
    final pair = await _safe(() => _plainPair(id));
    _current(check);
    await _commitProtected(id, pair.password, pair.privateKey, null, check);
  }

  Future<CredentialPair> _unlock(String id, String? expected) async {
    final record = await _record(id);
    if (record == null) {
      if (expected != null) {
        throw const CredentialProtectionException(
          CredentialProtectionError.stale,
        );
      }
      return _safe(() => _plainPair(id));
    }
    _expectRevision(record, expected);
    return _openPair(record);
  }

  void _expectRevision(ProtectedCredentialRecord record, String? expected) {
    if (expected != null && record.revision != expected) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
  }

  Future<CredentialPair> _openPair(ProtectedCredentialRecord record) async {
    final bytes = await _safe(
      () => _platformCrypto.open(
        connectionId: record.connectionId,
        revision: record.revision,
        ciphertext: record.cipher,
      ),
    );
    try {
      return ProtectedCredentialRecord.decodePair(bytes, record.revision);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _saveProtected(
    String id,
    String? password,
    String? privateKey,
    String? expected,
    bool Function()? check,
  ) async {
    _current(check);
    final previous = await _record(id);
    if (previous == null) {
      throw const CredentialProtectionException(
        CredentialProtectionError.locked,
      );
    }
    _expectRevision(previous, expected);
    _current(check);
    await _commitProtected(id, password, privateKey, previous, check);
  }

  Future<void> _commitProtected(
    String id,
    String? password,
    String? privateKey,
    ProtectedCredentialRecord? previous,
    bool Function()? check,
  ) async {
    final random = Random.secure();
    final revision = List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final bytes = ProtectedCredentialRecord.encodePair(password, privateKey);
    ProtectedCredentialRecord? next;
    var committed = false;
    try {
      _current(check);
      // Persist the cleanup owner before the platform can generate a Keystore key.
      // An engine/process loss during the prompt must not orphan this revision.
      await _retainRevision(id, revision);
      _current(check);
      final cipher = await _safe(
        () => _platformCrypto.seal(
          connectionId: id,
          revision: revision,
          plaintext: bytes,
        ),
      );
      next = ProtectedCredentialRecord(id, revision, cipher);
      next.encode();
      _current(check);
      // Pin this exact candidate even when the storage write outcome is uncertain.
      _markSnapshotSuccessor(id, previous?.revision, revision);
      await _writeRecord(next);
      _current(check);
      committed =
          true; // Only a verified sealed record can authorize legacy cleanup.
      await _clearPlain(id);
      if (previous != null) await _dropUnusedRevision(id, previous.revision);
    } catch (_) {
      if (!committed) await _rollbackCandidate(id, next, previous, revision);
      rethrow;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _rollbackCandidate(
    String id,
    ProtectedCredentialRecord? next,
    ProtectedCredentialRecord? previous,
    String revision,
  ) async {
    try {
      var raw = await _rawRecord(id);
      if (next != null && raw == next.encode()) {
        if (previous == null) {
          await _safe(() => _storage.delete(key: _protectedKey(id)));
        } else {
          await _writeRecord(previous);
        }
        raw = await _rawRecord(id);
      }
      // An unknown write outcome must retain the key for the possibly committed record.
      if (next == null || raw != next.encode()) {
        await _dropUnusedRevision(id, revision);
      }
    } catch (_) {
      /* Original failure remains visible; uncertain ciphertext keeps its key. */
    }
  }

  Future<void> _disable(
    String id,
    String? expected,
    bool Function()? check,
  ) async {
    _current(check);
    final record = await _record(id);
    if (record == null) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
    _expectRevision(record, expected);
    _current(check);
    final pair = await _openPair(record);
    _current(check);
    var committed = false;
    try {
      await _safe(() => _writeOrDelete(_passwordKey(id), pair.password));
      _current(check);
      await _safe(() => _writeOrDelete(_privateKeyKey(id), pair.privateKey));
      _current(check);
      if (await _safe(() => _storage.read(key: _passwordKey(id))) !=
              pair.password ||
          await _safe(() => _storage.read(key: _privateKeyKey(id))) !=
              pair.privateKey) {
        throw const CredentialProtectionException(
          CredentialProtectionError.storageFailure,
        );
      }
      _current(check);
      await _safe(() => _storage.delete(key: _protectedKey(id)));
      if (await _rawRecord(id) != null) {
        throw const CredentialProtectionException(
          CredentialProtectionError.storageFailure,
        );
      }
      _current(check);
      committed = true;
      _markSnapshotSuccessor(id, record.revision, null);
      await _dropUnusedRevision(id, record.revision);
    } finally {
      if (!committed) {
        // Opaque rollback only; the authenticated pair is never saved as a backup.
        await _writeRecord(record);
        await _clearPlain(id);
      }
    }
  }

  List<String> _plainKeys(String id) => [
    _passwordKey(id),
    _privateKeyKey(id),
    '${SecureCredentialRepository._legacyPasswordKeyPrefix}$id',
    '${SecureCredentialRepository._legacyPrivateKeyKeyPrefix}$id',
  ];

  Future<void> _clearPlain(String id) async {
    Object? failure;
    for (final key in _plainKeys(id)) {
      try {
        await _safe(() => _storage.delete(key: key));
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }
}
