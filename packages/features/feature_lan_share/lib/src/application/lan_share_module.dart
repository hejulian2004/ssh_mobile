// LAN Share Feature Module。
//
// Module 是 LAN 独立数据库、历史 Repository 和接收器 Coordinator 的
// 生命周期 Owner。它只从 ModuleContext 读取 App Shell Port，不查找静态
// 单例，也不会因为包被编译就自动启动后台监听。

import 'package:app_core/app_core.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';

import '../data/database/lan_share_database.dart';
import '../data/repositories/lan_share_history_repository.dart';
import '../domain/lan_share_ports.dart';
import '../features/lan_share/services/lan_receiver_coordinator.dart';
import '../services/lan_share/lan_peer_trust.dart';

/// 供测试替换独立 LAN 数据库创建过程。
typedef LanShareDatabaseFactory = LanShareDatabase Function();

/// LAN Share 的 App Scope Module。
final class LanShareModule implements AppModule {
  /// 创建尚未注册的 LAN Module。
  ///
  /// [receiverEnabled] 为空时读取 App Shell 的设置；显式为 false 时只
  /// 初始化数据库和服务依赖，不启动 HTTPS、mDNS 或原生网络监听。
  LanShareModule({
    bool? receiverEnabled,
    LanShareDatabaseFactory? databaseFactory,
  }) : _configuredReceiverEnabled = receiverEnabled,
       _databaseFactory = databaseFactory ?? LanShareDatabase.new;

  final bool? _configuredReceiverEnabled;
  final LanShareDatabaseFactory _databaseFactory;
  ModuleState _state = ModuleState.registered;
  LanShareSettingsPort? _settings;
  LanShareLoggerPort? _logger;
  LanShareDataProtectionPort? _dataProtection;
  LanShareNetworkIdentityPort? _networkIdentity;
  LanShareNetworkAccessPort? _networkAccess;
  LanShareLocalAddressSelectionPort? _localAddressSelectionPort;
  BootstrapClient? _bootstrapClient;
  NetworkRuntime? _networkRuntime;
  bool? _receiverEnabled;
  LanShareDatabase? _database;
  LanShareHistoryRepository? _historyRepository;
  LanPeerTrustStore? _peerTrustStore;
  LanReceiverCoordinator? _coordinator;
  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;

  @override
  String get id => 'feature_lan_share';

  @override
  ModuleState get state => _state;

  /// 当前 Module 是否会激活后台接收器。
  bool get receiverEnabled =>
      _receiverEnabled ?? _configuredReceiverEnabled ?? false;

  /// 当前 Module 创建的 LAN 接收器 Coordinator。
  LanReceiverCoordinator get coordinator =>
      _coordinator ?? (throw StateError('LanShareModule is not initialized.'));

  /// 当前 Module 独占的 LAN 数据库。
  LanShareDatabase get database =>
      _database ?? (throw StateError('LanShareModule is not initialized.'));

  /// 当前 Module 独占的历史 Repository。
  LanShareHistoryRepository get historyRepository =>
      _historyRepository ??
      (throw StateError('LanShareModule is not initialized.'));

  /// 当前 Module 独占的原子 LAN peer trust store。
  LanPeerTrustStore get peerTrustStore =>
      _peerTrustStore ??
      (throw StateError('LanShareModule is not initialized.'));

  /// 注册 App Shell Port 和 App Scope 网络 Runtime。
  @override
  Future<void> register(ModuleContext context) async {
    if (_state == ModuleState.disposed) {
      throw StateError('LanShareModule has been disposed.');
    }
    _settings = context.require<LanShareSettingsPort>();
    _logger = context.require<LanShareLoggerPort>();
    _dataProtection = context.require<LanShareDataProtectionPort>();
    _networkIdentity = context.require<LanShareNetworkIdentityPort>();
    _networkAccess = context.require<LanShareNetworkAccessPort>();
    _localAddressSelectionPort = context
        .require<LanShareLocalAddressSelectionPort>();
    _bootstrapClient = context.require<BootstrapClient>();
    _networkRuntime = context.require<NetworkRuntime>();
    _receiverEnabled = _configuredReceiverEnabled ?? _settings!.receiverEnabled;
  }

  /// 打开独立数据库并创建模块级 Repository/Coordinator。
  @override
  Future<void> initialize() => _initializeFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    if (_state == ModuleState.disposed) {
      _initializeFuture = null;
      throw StateError('LanShareModule has been disposed.');
    }
    final settings = _settings;
    final logger = _logger;
    final dataProtection = _dataProtection;
    final networkIdentity = _networkIdentity;
    final networkAccess = _networkAccess;
    final localAddressSelectionPort = _localAddressSelectionPort;
    final bootstrapClient = _bootstrapClient;
    final networkRuntime = _networkRuntime;
    if (settings == null ||
        logger == null ||
        dataProtection == null ||
        networkIdentity == null ||
        networkAccess == null ||
        localAddressSelectionPort == null ||
        bootstrapClient == null ||
        networkRuntime == null) {
      _initializeFuture = null;
      throw StateError('LanShareModule must be registered first.');
    }

    LanShareDatabase? database;
    LanPeerTrustStore? peerTrustStore;
    try {
      database = _databaseFactory();
      await database.customSelect('SELECT 1').get();
      final repository = LanShareHistoryRepository(database);
      peerTrustStore = LanPeerTrustStore();
      _database = database;
      _historyRepository = repository;
      _peerTrustStore = peerTrustStore;
      _coordinator = LanReceiverCoordinator(
        appSettings: settings,
        logger: logger,
        dataProtection: dataProtection,
        networkIdentity: networkIdentity,
        networkAccess: networkAccess,
        bootstrapClient: bootstrapClient,
        historyRepository: repository,
        networkRuntime: networkRuntime,
        localAddressSelectionPort: localAddressSelectionPort,
        peerTrustStore: peerTrustStore,
        initializeNetwork: receiverEnabled,
      );
      _state = ModuleState.initialized;
    } catch (_) {
      await database?.dispose();
      await peerTrustStore?.dispose();
      _database = null;
      _historyRepository = null;
      _peerTrustStore = null;
      _coordinator = null;
      _initializeFuture = null;
      rethrow;
    }
  }

  /// 按 App 配置激活后台接收器；配置关闭时不启动任何监听。
  @override
  Future<void> activate() async {
    if (_state == ModuleState.active) return;
    if (_state == ModuleState.disposed) {
      throw StateError('LanShareModule has been disposed.');
    }
    await initialize();
    if (receiverEnabled) await coordinator.activateReceiver();
    _state = ModuleState.active;
  }

  /// 停止监听和原生网络，但保留数据库及可重新激活的 Module 资源。
  @override
  Future<void> deactivate() async {
    if (_state != ModuleState.active) return;
    if (receiverEnabled) await coordinator.deactivateReceiver();
    _state = ModuleState.inactive;
  }

  /// 释放接收器、Repository 和独立数据库。
  @override
  Future<void> dispose() => _disposeFuture ??= _disposeResources();

  Future<void> _disposeResources() async {
    if (_state == ModuleState.disposed) return;
    Object? firstError;
    StackTrace? firstStack;

    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }

    await attempt(() async {
      if (_state == ModuleState.active && receiverEnabled) {
        await coordinator.deactivateReceiver();
      }
      await _coordinator?.close();
    });
    await attempt(() async {
      await _database?.dispose();
    });
    await attempt(() async {
      await _peerTrustStore?.dispose();
    });
    _coordinator = null;
    _historyRepository = null;
    _peerTrustStore = null;
    _database = null;
    _settings = null;
    _logger = null;
    _dataProtection = null;
    _networkIdentity = null;
    _networkAccess = null;
    _localAddressSelectionPort = null;
    _bootstrapClient = null;
    _networkRuntime = null;
    _state = ModuleState.disposed;

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
  }
}
