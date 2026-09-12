import 'dart:async';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_developer/feature_developer.dart' as developer;
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_webview/feature_webview.dart' as feature_webview;
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:realtime_media_android/realtime_media_android.dart';
import 'package:realtime_media_windows/realtime_media_windows.dart';
import 'package:path_provider/path_provider.dart';

import '../core/services/data_protection_service.dart';
import '../services/app_bootstrap_coordinator.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/telemetry/app_crash_telemetry_bridge.dart';
import '../services/telemetry/build_metadata_provider.dart';
import '../services/telemetry/drift_telemetry_storage.dart';
import '../services/telemetry/network_telemetry_bridge.dart';
import '../services/telemetry/network_telemetry_connectivity.dart';
import '../services/telemetry/telemetry_database.dart';
import '../services/telemetry/telemetry_database/telemetry_database_constants.dart';
import '../services/telemetry/telemetry_factory.dart';
import '../services/telemetry/telemetry_span.dart';
import '../services/display_mode_service.dart';
import '../services/network/network_identity_service.dart';
import '../services/network/network_service.dart';
import '../services/sftp_service.dart';
import '../services/terminal_session_metadata_store.dart';
import '../services/shortcut_command_service.dart';
import '../services/ssh_service.dart';
import 'app_runtime.dart';
import 'app_runtime_initialization_owner.dart';
import 'ai_external_capability_adapters.dart';
import 'ai_feature_adapters.dart';
import 'developer_feature_adapters.dart';
import 'lan_share_feature_adapters.dart';
import 'mcp_feature_adapters.dart';
import 'monitoring_feature_adapters.dart';
import 'network_sdk_adapters.dart';
import 'playbook_feature_adapters.dart';
import 'ssh_native_stream_adapters.dart';
import 'rag_feature_adapters.dart';
import 'realtime_feature_adapters.dart';
import 'realtime_media_feature_adapters.dart';
import 'terminal_ssh_capability_adapter.dart';
import 'webview_feature_adapters.dart';

part 'app_runtime_factory_context.dart';
part 'app_runtime_factory_core.dart';
part 'app_runtime_factory_modules.dart';
part 'app_runtime_factory_network.dart';
part 'app_runtime_factory_telemetry.dart';
part 'app_runtime_factory_runtime.dart';

/// App Scope 的唯一组装入口，负责创建并连接应用级服务。
///
/// 该工厂只做依赖装配，不把路由级 ViewModel 放进 Runtime；页面状态仍
/// 由 Provider 或 Route Scope 管理。初始化仍保持原来的非阻塞策略，避免
/// 为建立 Composition Root 而改变首帧和业务行为。
final class AppRuntimeFactory {
  AppRuntimeFactory._();

  /// 创建应用级 Runtime，并启动原有的轻量异步初始化任务。
  ///
  /// Connection 依赖参数只用于测试注入；生产入口不传参时始终创建一组
  /// Runtime 独占的数据库和 Repository。
  ///
  /// [disposeLogger] 默认 [true]，生产行为不变；回归测试可以关闭它，避免
  /// 销毁跨用例共享的 `AppLogService` 全局单例。
  /// [startPendingInitialization] 默认 [true]；仅用于不需要后台启动任务的
  /// App widget/route 测试，生产入口保持原有非阻塞初始化行为。
  static Future<AppRuntime> create({
    AppLogService? appLogService,
    connection_core.ConnectionDatabase? connectionDatabase,
    connection_core.ConnectionRepository? connectionRepository,
    connection_core.CredentialRepository? credentialRepository,
    connection_core.HostKeyRepository? hostKeyRepository,
    NetworkRuntime? networkRuntime,
    NetworkIdentityService? networkIdentityService,
    feature_lan_share.LanShareDatabaseFactory? lanShareDatabaseFactory,
    feature_ai.AiModuleDatabaseFactory? aiDatabaseFactory,
    feature_playbook.PlaybookModuleDatabaseFactory? playbookDatabaseFactory,
    feature_rag.RagDatabaseFactory? ragDatabaseFactory,
    feature_rag.RagCacheStoreFactory? ragCacheStoreFactory,
    feature_mcp.McpModuleDatabaseFactory? mcpDatabaseFactory,
    bool? lanShareReceiverEnabled,
    bool disposeLogger = true,
    bool startPendingInitialization = true,
    void Function(String event)? lifecycleObserver,
  }) {
    return _AppRuntimeFactoryContext(
      suppliedAppLogService: appLogService,
      connectionDatabase: connectionDatabase,
      connectionRepository: connectionRepository,
      credentialRepository: credentialRepository,
      hostKeyRepository: hostKeyRepository,
      networkRuntime: networkRuntime,
      networkIdentityService: networkIdentityService,
      lanShareDatabaseFactory: lanShareDatabaseFactory,
      aiDatabaseFactory: aiDatabaseFactory,
      playbookDatabaseFactory: playbookDatabaseFactory,
      ragDatabaseFactory: ragDatabaseFactory,
      ragCacheStoreFactory: ragCacheStoreFactory,
      mcpDatabaseFactory: mcpDatabaseFactory,
      lanShareReceiverEnabled: lanShareReceiverEnabled,
      disposeLogger: disposeLogger,
      startPendingInitialization: startPendingInitialization,
      lifecycleObserver: lifecycleObserver,
    ).create();
  }

  /// 从显式注入或同一 Connection Repository 派生 Host Key 契约。
  static connection_core.HostKeyRepository _resolveHostKeyRepository({
    required connection_core.HostKeyRepository? supplied,
    required connection_core.ConnectionRepository connectionRepository,
  }) {
    final explicit = supplied;
    if (explicit != null) return explicit;
    final derived = connectionRepository;
    if (derived is connection_core.HostKeyRepository) {
      return derived as connection_core.HostKeyRepository;
    }
    throw ArgumentError(
      'A HostKeyRepository is required with a custom ConnectionRepository.',
    );
  }

  /// 根据 Module 稳定状态判断其数据库是否已经由 Owner 打开。
  static bool _isModuleDatabaseOpen(AppModule module) => switch (module.state) {
    ModuleState.registered || ModuleState.disposed => false,
    ModuleState.initialized ||
    ModuleState.active ||
    ModuleState.inactive => true,
  };
}

/// Construction-time rollback stack for partially-created App Scope resources.
///
/// Actions are attempted in reverse registration order and an individual
/// cleanup failure never prevents later actions from running. Successful
/// construction transfers ownership to [AppRuntime] via [commit].
final class _CleanupStack {
  _CleanupStack({this._observer});

  /// 可选回滚观察器；只用于生命周期回归测试记录回滚顺序。
  final void Function(String event)? _observer;
  final List<_CleanupAction> _actions = <_CleanupAction>[];
  bool _committed = false;

  void add(FutureOr<void> Function() action, {required int priority}) {
    if (_committed) {
      throw StateError('Cannot register cleanup after ownership transfer.');
    }
    _actions.add(_CleanupAction(callback: action, priority: priority));
  }

  void commit() {
    _committed = true;
    _actions.clear();
  }

  Future<_CleanupFailure?> dispose() async {
    if (_committed) return null;
    _committed = true;
    _CleanupFailure? firstFailure;
    final actions = [..._actions]
      ..sort((left, right) {
        final priority = right.priority.compareTo(left.priority);
        if (priority != 0) return priority;
        return right.sequence.compareTo(left.sequence);
      });
    for (final action in actions) {
      // 只用于生命周期回归测试观察回滚顺序；观察器异常不能改变释放结果。
      _observer?.call('rollback.priority-${action.priority}');
      try {
        await action.callback();
      } catch (error, stackTrace) {
        firstFailure ??= _CleanupFailure(error, stackTrace);
      }
    }
    _actions.clear();
    return firstFailure;
  }
}

final class _CleanupAction {
  _CleanupAction({required this.callback, required this.priority})
    : sequence = _nextSequence++;

  static int _nextSequence = 0;

  final FutureOr<void> Function() callback;
  final int priority;
  final int sequence;
}

/// Cleanup priorities encode the App Scope dependency graph while retaining
/// reverse registration order within each owner group.
abstract final class _CleanupPriority {
  static const logger = 0;
  static const settings = 10;
  static const database = 20;
  static const network = 30;
  static const metadata = 35;
  static const ssh = 40;
  static const sftp = 50;
  static const realtime = 60;
  static const module = 70;
  static const adapter = 80;
}

final class _CleanupFailure {
  const _CleanupFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
