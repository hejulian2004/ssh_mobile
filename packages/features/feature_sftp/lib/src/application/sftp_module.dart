// SFTP Module 的生命周期实现。
//
// Module 是 sftp.db、路径 Repository 和 Feature 门面的唯一 Owner。SSH
// Manager 与兼容后端由 AppRuntime 注入，Module 只借用，不在 dispose 中
// 关闭 App Scope 资源。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:ssh_core/ssh_core.dart';

import '../data/database/sftp_database.dart';
import '../data/repository/drift_sftp_path_history_repository.dart';
import '../data/sftp_service.dart';
import '../domain/sftp_ports.dart';

/// SFTP 数据库构造器，供生命周期测试注入内存数据库。
typedef SftpDatabaseFactory = FutureOr<SftpDatabase> Function();

/// SFTP Feature 的 Module Scope Owner。
final class SftpModule implements AppModule {
  /// 创建尚未注册的 SFTP Module。
  SftpModule({SftpDatabaseFactory? databaseFactory})
    : _databaseFactory = databaseFactory ?? SftpDatabase.new;

  final SftpDatabaseFactory _databaseFactory;
  ModuleState _state = ModuleState.registered;
  SftpDatabase? _database;
  DriftSftpPathHistoryRepository? _repository;
  SftpService? _service;
  SshSessionManager? _sshSessionManager;
  SftpBackend? _backend;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;
  int _generation = 0;
  bool _initializing = false;

  @override
  String get id => 'feature_sftp';

  @override
  ModuleState get state => _state;

  /// 当前 Module 持有的数据库。
  SftpDatabase get database =>
      _database ?? (throw StateError('SftpModule is not initialized.'));

  /// 当前 Module 持有的路径 Repository。
  SftpPathHistoryRepository get pathHistoryRepository =>
      _repository ?? (throw StateError('SftpModule is not initialized.'));

  /// 当前 Module 的 SFTP Route Service。
  SftpService get service =>
      _service ?? (throw StateError('SftpModule is not initialized.'));

  /// 注册 App Scope SSH Manager 和兼容后端。
  @override
  Future<void> register(ModuleContext context) async {
    if (_state == ModuleState.disposed) {
      throw StateError('SftpModule has been disposed.');
    }
    _sshSessionManager = context.require<SshSessionManager>();
    _backend = context.require<SftpBackend>();
  }

  /// 幂等初始化 sftp.db、Repository 和 Service。
  @override
  Future<void> initialize() {
    if (_state == ModuleState.disposed) {
      return Future<void>.error(StateError('SftpModule has been disposed.'));
    }
    final existing = _initializeFuture;
    if (existing != null) return existing;
    _initializing = true;
    final future = _doInitialize(_generation);
    _initializeFuture = future;
    return future;
  }

  Future<void> _doInitialize(int generation) async {
    SftpDatabase? createdDatabase;
    try {
      final manager = _sshSessionManager;
      final backend = _backend;
      if (manager == null || backend == null) {
        throw StateError('SftpModule must be registered before initialize.');
      }
      final databaseCandidate = _databaseFactory();
      createdDatabase = databaseCandidate is Future<SftpDatabase>
          ? await databaseCandidate
          : databaseCandidate;
      final database = createdDatabase;
      if (_state == ModuleState.disposed || generation != _generation) {
        throw StateError('SftpModule initialization was cancelled.');
      }
      await database.customSelect('SELECT 1').getSingle();
      if (_state == ModuleState.disposed || generation != _generation) {
        throw StateError('SftpModule initialization was cancelled.');
      }
      final repository = DriftSftpPathHistoryRepository(database);
      _database = database;
      _repository = repository;
      _service = SftpService(
        backend: backend,
        historyRepository: repository,
        sshSessionManager: manager,
      );
      _state = ModuleState.initialized;
    } catch (_) {
      await createdDatabase?.dispose();
      if (_state != ModuleState.disposed && generation == _generation) {
        _initializeFuture = null;
        _state = ModuleState.registered;
      }
      rethrow;
    } finally {
      _initializing = false;
    }
  }

  /// 激活 Route；初始化失败时下次仍可重试。
  @override
  Future<void> activate() async {
    if (_state == ModuleState.initialized || _state == ModuleState.active) {
      _state = ModuleState.active;
      return;
    }
    final generation = _generation;
    await initialize();
    if (_state == ModuleState.disposed || generation != _generation) {
      throw StateError('SftpModule has been disposed.');
    }
    _state = ModuleState.active;
  }

  /// 停止 Route 级状态，但不关闭 App Scope 后端。
  @override
  Future<void> deactivate() async {
    if (_state == ModuleState.active) _state = ModuleState.inactive;
  }

  /// 释放 Service 监听、路径数据库；重复调用安全。
  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    _generation++;
    _state = ModuleState.disposed;
    final initialization = _initializeFuture;
    if (_initializing && initialization != null) {
      try {
        await initialization;
      } catch (_) {
        // A stale initializer owns and closes its local database before exit.
      }
    }
    final service = _service;
    final database = _database;
    _service = null;
    _repository = null;
    _database = null;
    _backend = null;
    _sshSessionManager = null;
    try {
      // Drain Feature-owned document I/O before closing its database.
      // Backend connections and SSH resources still belong to AppRuntime.
      if (service != null) await service.close();
    } finally {
      if (database != null) await database.dispose();
    }
  }
}
