part of 'secure_credential_repository.dart';

/// 无明文回滚租约与 Keystore revision 清理账本；所有入口沿用每 ID 串行队列。
extension _CredentialProtectionSnapshots on SecureCredentialRepository {
  Future<Set<String>> _revisions(String id) async {
    final raw = await _safe(() => _storage.read(key: _revisionKey(id)));
    if (raw == null) return {};
    try {
      if (raw.length > 256 * 68 + 2) throw const FormatException();
      final values = jsonDecode(raw);
      if (values is! List ||
          values.length > 256 ||
          values.any(
            (value) =>
                value is! String ||
                !ProtectedCredentialRecord.revisionPattern.hasMatch(value),
          )) {
        throw const FormatException();
      }
      return values.cast<String>().toSet();
    } catch (_) {
      throw const CredentialProtectionException(
        CredentialProtectionError.corrupt,
      );
    }
  }

  Future<void> _writeRevisions(String id, Set<String> revisions) async {
    final key = _revisionKey(id);
    if (revisions.isEmpty) {
      await _safe(() => _storage.delete(key: key));
      return;
    }
    if (revisions.length > 256) {
      throw const CredentialProtectionException(
        CredentialProtectionError.storageFailure,
      );
    }
    final value = jsonEncode(revisions.toList());
    await _safe(() => _storage.write(key: key, value: value));
    if (await _safe(() => _storage.read(key: key)) != value) {
      throw const CredentialProtectionException(
        CredentialProtectionError.storageFailure,
      );
    }
  }

  Future<void> _retainRevision(String id, String revision) async {
    final revisions = await _revisions(id)
      ..add(revision);
    await _writeRevisions(id, revisions);
  }

  Future<void> _dropUnusedRevision(String id, String revision) async {
    if (_snapshots.any(
      (snapshot) =>
          !snapshot._released &&
          snapshot.connectionId == id &&
          snapshot.revision == revision,
    )) {
      return;
    }
    if ((await _record(id))?.revision == revision) return;
    await _safe(
      () =>
          _crypto?.removeKey(connectionId: id, revision: revision) ??
          Future<void>.value(),
    );
    final revisions = await _revisions(id)
      ..remove(revision);
    await _writeRevisions(id, revisions);
  }

  Future<CredentialProtectionSnapshot> _captureSnapshot(String id) async {
    final record = await _record(id);
    if (record == null) {
      throw const CredentialProtectionException(
        CredentialProtectionError.locked,
      );
    }
    final snapshot = _SecureCredentialSnapshot(this, record);
    _snapshots.add(snapshot);
    return snapshot;
  }

  _SecureCredentialSnapshot _ownedSnapshot(
    CredentialProtectionSnapshot snapshot,
  ) {
    if (snapshot is! _SecureCredentialSnapshot ||
        !identical(snapshot._owner, this)) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
    return snapshot;
  }

  void _markSnapshotSuccessor(String id, String? previous, String? next) {
    for (final snapshot in _snapshots) {
      if (!snapshot._released &&
          snapshot.connectionId == id &&
          snapshot.revision == previous &&
          !snapshot._hasSuccessor) {
        snapshot._hasSuccessor = true;
        snapshot._successor = next;
      }
    }
  }

  void _markUnprotectedMutation(String id) {
    for (final snapshot in _snapshots) {
      if (snapshot.connectionId == id &&
          snapshot._hasSuccessor &&
          snapshot._successor == null) {
        snapshot._stale = true;
      }
    }
  }

  Future<void> _restoreSnapshot(_SecureCredentialSnapshot snapshot) async {
    if (snapshot._released || snapshot._stale) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
    final current = await _record(snapshot.connectionId);
    if (current?.revision != snapshot.revision &&
        (!snapshot._hasSuccessor || current?.revision != snapshot._successor)) {
      throw const CredentialProtectionException(
        CredentialProtectionError.stale,
      );
    }
    await _writeRecord(snapshot._record);
    await _clearPlain(snapshot.connectionId);
    snapshot._released = true;
    _snapshots.remove(snapshot);
    if (current != null && current.revision != snapshot.revision) {
      await _dropUnusedRevision(snapshot.connectionId, current.revision);
    }
  }

  Future<void> _discardSnapshot(_SecureCredentialSnapshot snapshot) async {
    if (snapshot._released) return;
    snapshot._released = true;
    _snapshots.remove(snapshot);
    await _dropUnusedRevision(snapshot.connectionId, snapshot.revision);
  }

  Future<void> _deleteAllCredentials(String id) async {
    Object? failure;
    ProtectedCredentialRecord? record;
    String? raw;
    Set<String> revisions = {};
    var preserveJournal = false;
    try {
      raw = await _rawRecord(id);
    } catch (error) {
      failure = error;
    }
    if (raw != null) {
      try {
        record = ProtectedCredentialRecord.decode(id, raw);
      } on CredentialProtectionException {
        // A delete may clear damaged opaque data. Retry tombstones retain aliases.
        try {
          if (raw.length <= ProtectedCredentialRecord.maxBytes * 2) {
            final deleted = jsonDecode(raw);
            if (deleted is Map &&
                deleted['deleted'] == true &&
                deleted['revisions'] is List) {
              revisions.addAll(
                (deleted['revisions'] as List).whereType<String>().where(
                  ProtectedCredentialRecord.revisionPattern.hasMatch,
                ),
              );
            }
          }
        } catch (_) {}
      }
    }
    try {
      revisions.addAll(await _revisions(id));
    } catch (error) {
      failure ??= error;
      preserveJournal =
          error is CredentialProtectionException &&
          error.code == CredentialProtectionError.storageFailure;
    }
    if (record != null) revisions.add(record.revision);
    for (final snapshot
        in _snapshots
            .where((snapshot) => snapshot.connectionId == id)
            .toList()) {
      revisions.add(snapshot.revision);
      snapshot._released = true;
      _snapshots.remove(snapshot);
    }
    // A failed delete leaves a tombstone so leftover legacy secrets cannot reappear.
    final hadProtection =
        raw != null || revisions.isNotEmpty || failure != null;
    if (hadProtection) {
      try {
        await _safe(
          () => _storage.write(
            key: _protectedKey(id),
            value: jsonEncode({
              'deleted': true,
              'revisions': revisions.toList(),
            }),
          ),
        );
      } catch (error) {
        failure ??= error;
      }
    }
    try {
      await _clearPlain(id);
    } catch (error) {
      failure ??= error;
    }
    for (final revision in revisions) {
      try {
        await _safe(
          () =>
              _crypto?.removeKey(connectionId: id, revision: revision) ??
              Future<void>.value(),
        );
      } catch (error) {
        failure ??= error;
      }
    }
    if (!preserveJournal) {
      try {
        await _safe(() => _storage.delete(key: _revisionKey(id)));
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure == null) {
      await _safe(() => _storage.delete(key: _protectedKey(id)));
    }
    if (failure != null) throw failure;
  }
}

final class _SecureCredentialSnapshot implements CredentialProtectionSnapshot {
  _SecureCredentialSnapshot(this._owner, this._record);
  final SecureCredentialRepository _owner;
  final ProtectedCredentialRecord _record;
  bool _released = false;
  bool _stale = false;
  bool _hasSuccessor = false;
  String? _successor;
  @override
  String get connectionId => _record.connectionId;
  @override
  String get revision => _record.revision;
}
