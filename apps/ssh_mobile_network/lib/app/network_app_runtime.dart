// 网络传输 App 的组合根。
//
// Runtime 拥有 Logger、NetworkRuntime、LAN 设置、身份和数据保护。
// Feature 只借用这些对象。这里不创建 NetworkFacade：生产 SessionClient
// 仍由完整 App 持有。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';

import '../lan/network_control_executor.dart';
import '../lan/network_flutter_secret_store.dart';
import '../lan/network_lan_identity.dart';
import '../lan/network_lan_ports.dart';
import '../lan/network_lan_protection.dart';
import '../lan/network_lan_settings.dart';
import '../lan/network_secret_store.dart';

/// 网络传输页的资源 Owner。
final class NetworkTransportAppRuntime implements Disposable {
  NetworkTransportAppRuntime._({
    required this.logger,
    required this.networkRuntime,
    required this.settings,
    required this.loggerPort,
    required this.protection,
    required this.identity,
    required this.networkAccess,
    required this.screenShare,
    required this.localAddressSelection,
    required this.module,
    required this.bootstrap,
  });

  /// App Scope Logger。
  final AppLoggerImpl logger;

  /// App Scope 网络运行时。
  final NetworkRuntime networkRuntime;

  /// LAN 页面设置。
  final NetworkLanSettings settings;

  /// LAN 日志 Port。
  final NetworkLanLogger loggerPort;

  /// LAN 历史字段保护。
  final NetworkLanProtection protection;

  /// 本 App 的网络身份。
  final NetworkLanIdentity identity;

  /// 不提供 NetworkFacade 的借用 Port。
  final NetworkLanAccess networkAccess;

  /// 关闭的屏幕共享 Port。
  final NetworkLanScreenShare screenShare;

  /// 只在候选唯一时选择本机 IPv4。
  final LanShareLocalAddressSelectionPort localAddressSelection;

  /// LAN Module。它拥有 `lan_share.db`，不释放 NetworkRuntime。
  final LanShareModule module;

  /// 控制面 Bootstrap 客户端。
  final BootstrapClient bootstrap;

  Future<void>? _disposeFuture;
  bool _disposed = false;

  /// App Scope 关闭是否已经开始。
  bool get isDisposed => _disposed;

  /// 打开平台安全存储、LAN 数据库，并启用页面接收器。
  ///
  /// 接收器只会确保 `NetworkCapability.runtime`。本方法不启用 QUIC、
  /// WebSocket Relay 或 Realtime，也不调用 `NetworkFacade.start`。
  // coverage:ignore-start
  static Future<NetworkTransportAppRuntime> create() {
    return open(
      logger: AppLoggerImpl(),
      networkRuntime: NetworkRuntimeImpl(),
      secrets: FlutterNetworkSecretStore(),
      module: LanShareModule(receiverEnabled: true),
      executor: const NetworkControlExecutor(),
    );
  }
  // coverage:ignore-end

  /// 用调用方提供的存储、数据库和运行时装配页面。
  static Future<NetworkTransportAppRuntime> open({
    required AppLoggerImpl logger,
    required NetworkRuntime networkRuntime,
    required NetworkSecretStore secrets,
    required LanShareModule module,
    required SdkRequestExecutor executor,
    LanShareLanguage language = LanShareLanguage.zh,
  }) async {
    final runtime = NetworkTransportAppRuntime._(
      logger: logger,
      networkRuntime: networkRuntime,
      settings: NetworkLanSettings(secrets: secrets, language: language),
      loggerPort: NetworkLanLogger(logger),
      protection: NetworkLanProtection(secrets),
      identity: NetworkLanIdentity(secrets),
      networkAccess: const NetworkLanAccess(),
      screenShare: const NetworkLanScreenShare(),
      localAddressSelection:
          const LanShareSingleCandidateLocalAddressSelection(),
      module: module,
      bootstrap: JsonBootstrapClient(executor: executor),
    );
    try {
      await runtime._start();
    } catch (error, stackTrace) {
      await _disposeQuietly(runtime);
      Error.throwWithStackTrace(error, stackTrace);
    }
    return runtime;
  }

  Future<void> _start() async {
    await settings.ensureLanIdentity();
    await identity.loadOrCreate();
    await module.register(
      ModuleContext.fromMap({
        LanShareSettingsPort: settings,
        LanShareLoggerPort: loggerPort,
        LanShareDataProtectionPort: protection,
        LanShareNetworkIdentityPort: identity,
        LanShareNetworkAccessPort: networkAccess,
        LanShareLocalAddressSelectionPort: localAddressSelection,
        BootstrapClient: bootstrap,
        NetworkRuntime: networkRuntime,
      }),
    );
    await module.initialize();
    await module.activate();
  }

  /// 先释放页面 Module，再释放运行时和 Logger。单项失败仍继续。
  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(module.dispose);
    await attempt(() async => settings.dispose());
    await attempt(networkRuntime.dispose);
    await attempt(logger.dispose);

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  static Future<void> _disposeQuietly(
    NetworkTransportAppRuntime runtime,
  ) async {
    try {
      await runtime.dispose();
    } catch (_) {
      // 启动失败时保留原始错误。dispose 自己的第一个错误仍会释放后续 Owner。
    }
  }
}
