import 'package:drift/drift.dart';

import '../database/connection_database.dart';
import '../model/connection_enums.dart';
import '../model/connection_profile.dart';
import 'connection_repository.dart';
import 'host_key_repository.dart';

/// 基于独立 Drift 数据库的 Connection Repository。
///
/// Repository 只拥有内存快照和数据库写入顺序，不拥有数据库本身；数据库由
/// AppRuntime 创建和释放。所有写操作通过串行尾队列执行，避免快速连续保存、
/// 删除和排序时出现内存快照与 SQLite 顺序不一致。
final class DriftConnectionRepository
    implements
        ConnectionRepository,
        HostKeyRepository,
        ConnectionCatalogChanges {
  /// 使用 AppRuntime 注入的 ConnectionDatabase 创建 Repository。
  factory DriftConnectionRepository({required ConnectionDatabase database}) =>
      DriftConnectionRepository._(database);

  DriftConnectionRepository._(this._database);

  final ConnectionDatabase _database;
  List<ConnectionConfig> _connections = const [];
  Future<void>? _initialization;
  Future<void> _operationTail = Future<void>.value();

  @override
  List<ConnectionConfig> get connections => _connections;

  @override
  Stream<List<ConnectionConfig>> watchConnections() => _database.connectionDao
      .watchAll()
      .map((rows) => List<ConnectionConfig>.unmodifiable(rows.map(_fromRow)));

  /// 初始化一次并建立内存快照。
  @override
  Future<void> initialize() {
    return _initialization ??= _loadSnapshot();
  }

  /// 从数据库读取最新连接快照。
  @override
  Future<List<ConnectionConfig>> loadConnections() async {
    await initialize();
    return _runExclusive(() async {
      await _loadSnapshot();
      return connections;
    });
  }

  /// 新增连接结构；凭据字段不会被映射到数据库。
  @override
  Future<void> addConnection(ConnectionConfig config) async {
    requireCanonicalConnectionId(config.id);
    await initialize();
    await _runExclusive(() async {
      if (_connections.any((item) => item.id == config.id)) {
        throw StateError('Connection id already exists: ${config.id}');
      }
      await _database.connectionDao.save(
        _toCompanion(config, sortOrder: _connections.length),
      );
      _connections = List.unmodifiable([
        ..._connections,
        _withoutCredentials(config),
      ]);
    });
  }

  /// 更新已有连接结构；凭据仍由 CredentialRepository 管理。
  @override
  Future<void> updateConnection(ConnectionConfig config) async {
    requireCanonicalConnectionId(config.id);
    await initialize();
    await _runExclusive(() async {
      final index = _connections.indexWhere((item) => item.id == config.id);
      if (index == -1) {
        throw StateError('Connection does not exist: ${config.id}');
      }
      await _database.connectionDao.save(
        _toCompanion(config, sortOrder: index),
      );
      final next = List<ConnectionConfig>.from(_connections);
      next[index] = _withoutCredentials(config);
      _connections = List.unmodifiable(next);
    });
  }

  /// 删除一个连接结构；不会越权删除 Secure Storage 凭据。
  @override
  Future<void> deleteConnection(String id) async {
    requireCanonicalConnectionId(id);
    await initialize();
    await _runExclusive(() async {
      await _database.connectionDao.deleteById(id);
      _connections = List.unmodifiable(
        _connections.where((item) => item.id != id),
      );
    });
  }

  /// 按调用顺序删除多个连接结构。
  @override
  Future<void> deleteConnections(List<String> ids) async {
    for (final id in ids) {
      requireCanonicalConnectionId(id);
    }
    await initialize();
    await _runExclusive(() async {
      for (final id in ids) {
        await _database.connectionDao.deleteById(id);
      }
      final idSet = ids.toSet();
      _connections = List.unmodifiable(
        _connections.where((item) => !idSet.contains(item.id)),
      );
      await _rewriteSortOrders();
    });
  }

  /// 调整连接顺序并在一个事务中写入排序值。
  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    await initialize();
    await _runExclusive(() async {
      if (oldIndex < 0 || oldIndex >= _connections.length) {
        throw RangeError.index(oldIndex, _connections, 'oldIndex');
      }
      if (newIndex < 0 || newIndex > _connections.length) {
        throw RangeError.index(newIndex, _connections, 'newIndex');
      }
      final next = List<ConnectionConfig>.from(_connections);
      final item = next.removeAt(oldIndex);
      next.insert(newIndex, item);
      await _database.transaction(_rewriteSortOrdersFor(next));
      _connections = List.unmodifiable(next);
    });
  }

  /// 从当前内存快照获取一个连接。
  @override
  ConnectionConfig? getConnection(String id) {
    requireCanonicalConnectionId(id);
    for (final connection in _connections) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  /// 保存用户确认过的 Host Key 元数据。
  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {
    requireCanonicalConnectionId(connectionId);
    await initialize();
    await _runExclusive(() async {
      final index = _connections.indexWhere((item) => item.id == connectionId);
      if (index == -1) return;
      final now = DateTime.now();
      final hasTrust = fingerprint?.isNotEmpty == true;
      final trusted = hasTrust ? trustedAt ?? now.toUtc() : null;
      await _database.connectionDao.updateHostKey(
        id: connectionId,
        algorithm: hasTrust ? algorithm : null,
        fingerprint: hasTrust ? fingerprint : null,
        trustedAt: trusted?.toUtc().millisecondsSinceEpoch,
        updatedAt: now.toUtc().millisecondsSinceEpoch,
      );
      final next = _withoutCredentials(_connections[index]);
      next.hostKeyAlgorithm = hasTrust ? algorithm : null;
      next.hostKeyFingerprint = hasTrust ? fingerprint : null;
      next.hostKeyTrustedAt = trusted;
      next.updatedAt = now;
      final snapshot = List<ConnectionConfig>.from(_connections);
      snapshot[index] = next;
      _connections = List.unmodifiable(snapshot);
    });
  }

  Future<void> _loadSnapshot() async {
    final rows = await _database.connectionDao.loadAll();
    _connections = List.unmodifiable(rows.map(_fromRow));
  }

  Future<void> _rewriteSortOrders() {
    return _database.transaction(_rewriteSortOrdersFor(_connections));
  }

  Future<void> Function() _rewriteSortOrdersFor(List<ConnectionConfig> items) {
    return () async {
      for (var index = 0; index < items.length; index++) {
        await _database.connectionDao.updateSortOrder(items[index].id, index);
      }
    };
  }

  Future<T> _runExclusive<T>(Future<T> Function() operation) {
    final previous = _operationTail;
    final next = previous.catchError((_) {}).then((_) => operation());
    _operationTail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  ConnectionTableCompanion _toCompanion(
    ConnectionConfig config, {
    required int sortOrder,
  }) {
    return ConnectionTableCompanion(
      id: Value(config.id),
      name: Value(config.name),
      host: Value(config.host),
      port: Value(config.port),
      username: Value(config.username),
      authMethod: Value(config.authMethod.name),
      terminalWidth: Value(config.terminalWidth),
      terminalHeight: Value(config.terminalHeight),
      keepAlive: Value(config.keepAlive),
      keepAliveInterval: Value(config.keepAliveInterval),
      launchMode: Value(config.launchMode.name),
      serverPlatform: Value(config.serverPlatform.name),
      tmuxAutoDeleteSeconds: Value(config.tmuxAutoDeleteSeconds),
      hostKeyFingerprint: Value(config.hostKeyFingerprint),
      hostKeyAlgorithm: Value(config.hostKeyAlgorithm),
      hostKeyTrustedAt: Value(_toMillis(config.hostKeyTrustedAt)),
      jumpHost: Value(config.jumpHost),
      jumpPort: Value(config.jumpPort),
      jumpUsername: Value(config.jumpUsername),
      group: Value(config.group),
      createdAt: Value(config.createdAt.toUtc().millisecondsSinceEpoch),
      updatedAt: Value(config.updatedAt.toUtc().millisecondsSinceEpoch),
      sortOrder: Value(sortOrder),
    );
  }

  ConnectionConfig _fromRow(ConnectionTableData row) {
    return ConnectionConfig(
      id: row.id,
      name: row.name,
      host: row.host,
      port: row.port,
      username: row.username,
      authMethod: AuthMethod.fromName(row.authMethod),
      terminalWidth: row.terminalWidth,
      terminalHeight: row.terminalHeight,
      keepAlive: row.keepAlive,
      keepAliveInterval: row.keepAliveInterval,
      launchMode: TerminalLaunchMode.fromName(row.launchMode),
      serverPlatform: ServerPlatform.fromName(row.serverPlatform),
      tmuxAutoDeleteSeconds: row.tmuxAutoDeleteSeconds,
      hostKeyFingerprint: row.hostKeyFingerprint,
      hostKeyAlgorithm: row.hostKeyAlgorithm,
      hostKeyTrustedAt: _fromMillis(row.hostKeyTrustedAt),
      jumpHost: row.jumpHost,
      jumpPort: row.jumpPort,
      jumpUsername: row.jumpUsername,
      group: row.group,
      createdAt: _fromMillis(row.createdAt) ?? DateTime.now(),
      updatedAt: _fromMillis(row.updatedAt) ?? DateTime.now(),
    );
  }

  ConnectionConfig _withoutCredentials(ConnectionConfig config) {
    return ConnectionConfig.fromJson(config.toJson());
  }

  int? _toMillis(DateTime? value) => value?.toUtc().millisecondsSinceEpoch;

  DateTime? _fromMillis(int? value) {
    if (value == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
  }
}
