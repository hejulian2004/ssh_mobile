import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:app_notifications/app_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'app_log_service.dart';

import 'package:connection_core/connection_core.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../core/services/ssh_client_factory.dart';
import '../core/services/ssh_host_key_policy.dart';
import 'background_service_lifecycle.dart';
import 'ssh/ssh_connection_attempt.dart';

/// 后台 isolate 可选的 native SSH 流连接器。
///
/// FFI `SshNetRuntimeHandle` 不是多 isolate 安全的，因此后台 isolate 默认不使用
/// native 传输；启用 native 时 SSH 会改走 UI isolate 的本地路径（见
/// `SshService._usesBackgroundService`）。该静态 hook 仅为显式后台 native 适配
/// 预留，保持 socket 接缝可替换。
ssh_core.SshNativeStreamConnector? sshBackgroundNativeStreamConnector;

/// Test seam for exercising the background session lifecycle without opening a
/// real SSH socket. Production always leaves this unset and follows the normal
/// socket, authentication, and shell construction path below.
typedef BackgroundSshSessionFactory =
    Future<SSHClient> Function(Map<String, dynamic> data);

/// Starts an isolated background SSH runtime with an optional test session
/// factory. The platform entry point uses [sshBackgroundServiceEntryPoint]
/// directly and therefore retains the production transport path.
@visibleForTesting
void startBackgroundSshRuntimeForTesting(
  ServiceInstance service, {
  BackgroundSshSessionFactory? sessionFactory,
}) {
  _BackgroundSshRuntime(service, sessionFactory: sessionFactory).start();
}

/// Opens a background SSH socket through the same native-first/fallback
/// boundary used by the production isolate.
@visibleForTesting
Future<SSHSocket> openBackgroundSshSocketForTesting({
  required String host,
  required int port,
  String? peerId,
}) => _openBackgroundSshSocket(host: host, port: port, peerId: peerId);

/// 打开后台 SSH socket：native ReliableStream 优先，原始 TCP 回退。
Future<SSHSocket> _openBackgroundSshSocket({
  required String host,
  required int port,
  String? peerId,
}) async {
  final connector = sshBackgroundNativeStreamConnector;
  if (connector != null && peerId != null && peerId.trim().isNotEmpty) {
    final stream = await connector.open(peerId: peerId, service: 'ssh');
    return ssh_core.SshNativeSocket(stream: stream);
  }
  return SSHSocket.connect(host, port, timeout: const Duration(seconds: 15));
}

final class _SupersededSshConnection implements Exception {
  const _SupersededSshConnection();
}

/// Android/iOS 前台服务管理。
///
/// 职责：
/// 1. 启动/停止前台服务（flutter_background_service）
/// 2. 通知渠道创建 + 权限请求
/// 3. WakeLock 获取/释放（通过 MethodChannel 'ssh_mobile/power'）
/// 4. 电池优化豁免引导
///
/// sshBackgroundServiceEntryPoint：后台 SSH 入口点函数，与 UI 进程隔离运行。
/// 完整实现 SSH 客户端、Shell 管理、心跳保活和重连逻辑。
class BackgroundServiceManager {
  static const String _channelId = 'ssh_mobile_foreground';
  static const int _notificationId = 1001;
  static const MethodChannel _powerChannel = MethodChannel('ssh_mobile/power');
  static bool _configured = false;
  static bool _notificationPermissionChecked = false;
  static Future<void>? _prewarmFuture;
  static final BackgroundServiceLifecycle _lifecycle =
      BackgroundServiceLifecycle(
        isRunning: () => FlutterBackgroundService().isRunning(),
        startService: () => FlutterBackgroundService().startService(),
        stoppedEvents: () => FlutterBackgroundService()
            .on('sshServiceStopped')
            .map<void>((_) {}),
        requestStop: () => FlutterBackgroundService().invoke('stopService'),
        acquirePowerLocks: _acquirePowerLocks,
        releasePowerLocks: _releasePowerLocks,
      );

  static bool get _supportsNativeBackgroundService {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
  }

  static Future<void> initialize() async {
    if (!_supportsNativeBackgroundService) return;
    AppLogService.instance.info(
      '[BackgroundManager] Initializing background service manager',
    );
    await _requestNotificationPermission();
    await prewarm();
  }

  static Future<void> prewarm() async {
    if (!_supportsNativeBackgroundService) return;
    if (_configured) return;
    final existing = _prewarmFuture;
    if (existing != null) {
      await existing;
      return;
    }

    AppLogService.instance.info('Prewarming BackgroundServiceManager');
    final future = _configureService();
    _prewarmFuture = future;
    try {
      AppLogService.instance.info(
        '[BackgroundManager] Prewarming background service configuration',
      );
      await future;
      AppLogService.instance.info(
        'BackgroundServiceManager prewarmed successfully',
      );
    } catch (e) {
      AppLogService.instance.error(
        'BackgroundServiceManager prewarm failed',
        error: e,
      );
    } finally {
      _prewarmFuture = null;
    }
  }

  static Future<void> _configureService() async {
    if (_configured) return;
    try {
      await _createNotificationChannel();
      AppLogService.instance.info(
        '[BackgroundManager] Notification channel created successfully',
      );
    } catch (e) {
      AppLogService.instance.warning(
        '[BackgroundManager] Failed to create notification channel: $e',
      );
    }

    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: sshBackgroundServiceEntryPoint,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'SSH Mobile',
        initialNotificationContent: 'SSH service is ready',
        foregroundServiceNotificationId: _notificationId,
        foregroundServiceTypes: const [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: sshBackgroundServiceEntryPoint,
      ),
    );

    _configured = true;
    AppLogService.instance.info(
      '[BackgroundManager] Background service configured successfully',
    );
  }

  static Future<void> start({
    String? connectionName,
    bool showConnectionName = false,
  }) async {
    if (!_supportsNativeBackgroundService) return;
    AppLogService.instance.info(
      '[BackgroundManager] Starting background service',
    );
    await initialize();
    try {
      final service = FlutterBackgroundService();
      final started = await _lifecycle.start();
      AppLogService.instance.info(
        '[BackgroundManager] Background service start result',
        details: 'started=$started',
      );
      if (!started) {
        AppLogService.instance.warning(
          '[BackgroundManager] Platform declined background service startup',
        );
        return;
      }
      unawaited(_requestBatteryOptimizationExemption());

      service.invoke('update', {
        'title': 'SSH Mobile',
        'content': _notificationContent(
          connectionName,
          showConnectionName: showConnectionName,
        ),
      });
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        '[BackgroundManager] Error starting background service',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  static Future<void> stop() async {
    if (!_supportsNativeBackgroundService) return;
    AppLogService.instance.info(
      '[BackgroundManager] Stopping background service',
    );
    final acknowledged = await _lifecycle.stop();
    if (!acknowledged) {
      AppLogService.instance.warning(
        '[BackgroundManager] Timed out waiting for SSH resource shutdown',
      );
    }
    AppLogService.instance.info('Background SSH Service stopped');
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _powerChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (e) {
      AppLogService.instance.warning(
        '[BackgroundManager] Error checking battery optimizations: $e',
      );
      return false;
    }
  }

  static Future<void> requestBatteryOptimizationExemption() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _powerChannel.invokeMethod<bool>(
        'requestBatteryOptimizationExemption',
      );
    } catch (e) {
      AppLogService.instance.warning(
        '[BackgroundManager] Error requesting battery optimizations: $e',
      );
    }
  }

  static Future<void> openAppSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _powerChannel.invokeMethod<bool>('openAppSettings');
    } catch (e) {
      AppLogService.instance.warning(
        '[BackgroundManager] Error opening app settings: $e',
      );
    }
  }

  static void updateStatus(String content) {
    if (!_supportsNativeBackgroundService) return;
    FlutterBackgroundService().invoke('update', {
      'title': 'SSH Mobile',
      'content': content,
    });
  }

  static Future<void> _requestNotificationPermission() async {
    if (_notificationPermissionChecked) return;
    _notificationPermissionChecked = true;

    final status = await Permission.notification.status;
    AppLogService.instance.info(
      '[BackgroundManager] Current notification permission status: $status',
    );
    if (status.isDenied || status.isRestricted || status.isLimited) {
      final result = await Permission.notification.request();
      AppLogService.instance.info(
        '[BackgroundManager] Requested notification permission, result: $result',
      );
    }
  }

  static Future<void> _createNotificationChannel() async {
    final ready = await AppNotificationCenter.shared.ensureInitialized(
      identity: AppNotificationIdentity.full,
    );
    if (!ready) {
      throw StateError('notification center is not initialized');
    }
    await AppNotificationCenter.shared.ensureAndroidChannel(
      id: _channelId,
      name: 'SSH connection',
      description: 'Keeps active SSH sessions alive in a foreground service.',
      highPriority: false,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );
  }

  static Future<void> _acquirePowerLocks() async {
    try {
      await _powerChannel.invokeMethod<bool>('acquireLocks');
      AppLogService.instance.info(
        '[BackgroundManager] Power locks acquired successfully',
      );
    } catch (e) {
      AppLogService.instance.warning(
        '[BackgroundManager] Failed to acquire power locks: $e',
      );
    }
  }

  static Future<void> _releasePowerLocks() async {
    try {
      await _powerChannel.invokeMethod<bool>('releaseLocks');
      AppLogService.instance.info(
        '[BackgroundManager] Power locks released successfully',
      );
    } catch (e) {
      AppLogService.instance.warning(
        '[BackgroundManager] Failed to release power locks: $e',
      );
    }
  }

  static Future<void> _requestBatteryOptimizationExemption() async {
    try {
      final ignoring =
          await _powerChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
      AppLogService.instance.info(
        '[BackgroundManager] Battery optimization ignoring check: $ignoring',
      );
      if (!ignoring) {
        await _powerChannel.invokeMethod<bool>(
          'requestBatteryOptimizationExemption',
        );
        AppLogService.instance.info(
          '[BackgroundManager] Requested battery optimization exemption',
        );
      }
    } catch (e) {
      AppLogService.instance.warning(
        '[BackgroundManager] Failed battery optimization exemption request: $e',
      );
    }
  }

  static String _notificationContent(
    String? connectionName, {
    required bool showConnectionName,
  }) {
    if (!showConnectionName ||
        connectionName == null ||
        connectionName.isEmpty) {
      return 'SSH service is running';
    }
    return 'Connected to $connectionName';
  }
}

Map<String, dynamic> sanitizeBackgroundReconnectData(
  Map<String, dynamic> data,
) {
  return Map<String, dynamic>.from(data)
    ..remove('password')
    ..remove('privateKey');
}

class BackgroundReconnectDecision {
  final bool reconnectInBackground;
  final bool requiresAppReconnect;
  final String message;

  const BackgroundReconnectDecision({
    required this.reconnectInBackground,
    required this.requiresAppReconnect,
    required this.message,
  });
}

BackgroundReconnectDecision decideBackgroundUnexpectedDisconnect({
  required String launchMode,
  required String reason,
}) {
  if (launchMode == 'tmux') {
    return BackgroundReconnectDecision(
      reconnectInBackground: false,
      requiresAppReconnect: true,
      message:
          'Connection lost: $reason. Reconnect from the app to restore this tmux session.',
    );
  }

  return BackgroundReconnectDecision(
    reconnectInBackground: false,
    requiresAppReconnect: false,
    message: 'Connection lost: $reason',
  );
}

@pragma('vm:entry-point')
void sshBackgroundServiceEntryPoint(ServiceInstance service) =>
    _BackgroundSshRuntime(service).start();

/// 后台 isolate 的 SSH session、事件订阅、tmux 和 keepalive 生命周期 Owner。
///
/// UI isolate 的 [BackgroundServiceManager] 只负责平台前台服务和电源资源；本类
/// 只消费 [ServiceInstance] 事件总线，不调用通知权限或 power MethodChannel。
final class _BackgroundSshRuntime {
  /// 为一个后台 isolate service 创建独立运行时。
  _BackgroundSshRuntime(this.service, {this._sessionFactory});

  final ServiceInstance service;
  final BackgroundSshSessionFactory? _sessionFactory;
  final Map<String, _BackgroundSshSession> sessions = {};
  final SshSessionConnectGate _connectGate = SshSessionConnectGate();
  final Set<Future<void>> _connectOperations = <Future<void>>{};
  final List<StreamSubscription<Map<String, dynamic>?>> _eventSubscriptions =
      <StreamSubscription<Map<String, dynamic>?>>[];
  bool _stopping = false;

  void emitLog(String level, String message, {String? details}) {
    service.invoke('sshLogReceived', {
      'level': level,
      'message': message,
      if (details != null && details.isNotEmpty) 'details': details,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void emitOverview() {
    final byConnection = <String, Map<String, dynamic>>{};
    for (final session in sessions.values) {
      final connId = session.connectionId;
      if (connId != null) {
        final current = byConnection.putIfAbsent(
          connId,
          () => {'count': 0, 'latestState': 'connected', 'hasConnected': true},
        );
        current['count'] = (current['count'] as int) + 1;
      }
    }

    service.invoke('sshOverviewUpdated', {
      'overview': byConnection,
      'windowCount': sessions.length,
    });
  }

  void setNotification(String content) {
    final instance = service;
    if (instance is AndroidServiceInstance) {
      instance.setAsForegroundService();
      instance.setForegroundNotificationInfo(
        title: 'SSH Mobile',
        content: content,
      );
    }
  }

  void emitState(
    String state, {
    required String sessionId,
    String? message,
    String? connectionId,
    String? connectionName,
  }) {
    emitLog(
      'service',
      'SSH state: $state',
      details:
          'sessionId=$sessionId connection=${connectionName ?? connectionId ?? ''}'
          '${message == null ? '' : ' message=$message'}',
    );
    service.invoke('sshStateChanged', {
      'sessionId': sessionId,
      'state': state,
      'message': ?message,
      'connectionId': ?connectionId,
      'connectionName': ?connectionName,
    });
  }

  String notificationSummary() {
    final count = sessions.length;
    if (count == 0) return 'SSH service is running';
    if (count == 1) {
      final session = sessions.values.first;
      if (session.showServerNameInNotification) {
        return 'Connected to ${session.connectionName}';
      }
      return '1 SSH session running';
    }
    return '$count SSH sessions running';
  }

  Future<void> closeSsh(
    String sessionId, {
    bool notify = true,
    String? message,
    bool destroyTmux = false,
    bool cancelPending = true,
  }) async {
    if (cancelPending) _connectGate.cancel(sessionId);
    final session = sessions.remove(sessionId);
    if (session == null) return;
    emitLog(
      'service',
      'Closing SSH session',
      details:
          'sessionId=$sessionId notify=$notify destroyTmux=$destroyTmux mode=${session.launchMode}',
    );
    if (destroyTmux) {
      await session.killTmuxSession();
    }
    try {
      await session.close();
    } catch (error) {
      emitLog(
        'error',
        'SSH session resource cleanup failed',
        details: 'sessionId=$sessionId error=$error',
      );
    }
    if (notify) {
      emitState(
        'disconnected',
        sessionId: sessionId,
        message: message ?? 'Connection closed',
        connectionId: session.connectionId,
        connectionName: session.connectionName,
      );
      setNotification(notificationSummary());
    }
    emitOverview();
  }

  Future<void> closeAll({bool notify = true, bool destroyTmux = true}) async {
    _connectGate.cancelAll();
    final ids = sessions.keys.toList();
    emitLog(
      'service',
      'Closing all SSH sessions',
      details: 'count=${ids.length} notify=$notify',
    );
    for (final sessionId in ids) {
      await closeSsh(sessionId, notify: notify, destroyTmux: destroyTmux);
    }
    await Future.wait<void>(_connectOperations.toList(growable: false));
    setNotification('SSH service is running');
  }

  Future<void> handleUnexpectedDisconnect(
    _BackgroundSshSession runtime,
    String reason,
  ) async {
    if (!identical(sessions[runtime.sessionId], runtime)) {
      return;
    }

    final decision = decideBackgroundUnexpectedDisconnect(
      launchMode: runtime.launchMode,
      reason: reason,
    );
    if (decision.requiresAppReconnect) {
      emitLog(
        'warning',
        'Background tmux reconnect requires app credentials',
        details:
            'sessionId=${runtime.sessionId} tmux=${runtime.tmuxSessionName} reason=$reason',
      );
    }

    await closeSsh(runtime.sessionId, message: decision.message);
  }

  String sanitizeTmuxSessionName(String name) {
    final sanitized = name
        .trim()
        // tmux treats "." as a target separator: session.window. Keep session
        // names to plain safe characters so domains like hejulian.cn do not
        // become an invalid tmux target.
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isEmpty) return 'ssh_mobile';
    return sanitized.length > 80 ? sanitized.substring(0, 80) : sanitized;
  }

  String shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  String buildTmuxAttachCommand(String sessionName, int autoDeleteSeconds) {
    final safeName = sanitizeTmuxSessionName(sessionName);
    final quotedName = shellQuote(safeName);
    final seconds = autoDeleteSeconds.clamp(30, 86400);
    final idleWatcher =
        'idle_start=0; interval=5; '
        'while tmux has-session -t $quotedName 2>/dev/null; do '
        'if tmux list-clients -t $quotedName 2>/dev/null | grep -q .; then '
        'idle_start=0; '
        'else now=\$(date +%s); '
        'if [ "\$idle_start" -eq 0 ]; then idle_start=\$now; fi; '
        'if [ \$((now - idle_start)) -ge $seconds ]; then '
        'tmux kill-session -t $quotedName 2>/dev/null; exit; fi; '
        'fi; sleep \$interval; done';
    return 'if command -v tmux >/dev/null 2>&1; then '
        'tmux has-session -t $quotedName 2>/dev/null || '
        'tmux new-session -d -s $quotedName; '
        'tmux set-option -t $quotedName -q @ssh_mobile_auto_delete_seconds $seconds; '
        'tmux set-option -t $quotedName -q status off; '
        'tmux run-shell -b ${shellQuote(idleWatcher)}; '
        'tmux attach-session -t $quotedName; '
        'else echo "tmux is not installed on this server"; exit 127; fi';
  }

  Future<void> ensureTmuxInstalled({required SSHClient client}) async {
    late final SSHRunResult tmuxCheck;
    try {
      emitLog('service', 'Checking tmux installation');
      tmuxCheck = await client
          .runWithResult('command -v tmux >/dev/null 2>&1')
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      emitLog('error', 'Unable to check tmux', details: e.toString());
      throw StateError(
        'Unable to check tmux on this server. Please install tmux manually '
        'on the server and try again. Detail: $e',
      );
    }
    if (tmuxCheck.exitCode == 0) return;

    emitLog('warning', 'tmux is not installed on server');
    throw StateError(
      'tmux is not installed on this server. Please install tmux manually '
      'on the server and try again.',
    );
  }

  Future<void> connectSsh(Map<String, dynamic> data) async {
    if (_stopping) return;
    final rawSessionId = data['sessionId'];
    if (rawSessionId is! String || rawSessionId.isEmpty) {
      emitLog('warning', 'Ignoring sshConnect without sessionId');
      return;
    }
    final sessionId = rawSessionId;
    final connectToken = _connectGate.begin(sessionId);
    final owner = SshConnectionAttemptOwner();
    final connectionId = data['id'] is String ? data['id'] as String : null;
    final name = data['name'] is String ? data['name'] as String : 'server';
    final showServerNameInNotification =
        data['showServerNameInNotification'] == true;

    try {
      await closeSsh(sessionId, notify: false, cancelPending: false);
      _ensureConnectCurrent(sessionId, connectToken);
      emitState(
        'connecting',
        sessionId: sessionId,
        connectionId: connectionId,
        connectionName: name,
      );
      setNotification(
        showServerNameInNotification
            ? 'Connecting to $name...'
            : 'Connecting...',
      );
      emitLog(
        'service',
        'Connecting SSH socket',
        details: 'sessionId=$sessionId host=${data['host']}:${data['port']}',
      );

      final host = data['host'] as String;
      final port = (data['port'] as num?)?.toInt() ?? 22;
      final username = data['username'] as String;
      final authMethod = data['authMethod'] as String? ?? 'password';
      final password = data['password'] as String?;
      final privateKey = data['privateKey'] as String?;
      final width = (data['terminalWidth'] as num?)?.toInt() ?? 80;
      final height = (data['terminalHeight'] as num?)?.toInt() ?? 24;
      final keepAliveSeconds =
          (data['keepAliveInterval'] as num?)?.toInt() ?? 3;
      final launchMode = data['launchMode'] as String? ?? 'ssh';
      final tmuxSessionName = sanitizeTmuxSessionName(
        data['tmuxSessionName'] as String? ?? name,
      );
      final tmuxAutoDeleteSeconds =
          ((data['tmuxAutoDeleteSeconds'] as num?)?.toInt() ?? 600).clamp(
            30,
            86400,
          );
      final peerId = data['peerId'] as String?;
      final config = ConnectionConfig(
        id: connectionId ?? sessionId,
        name: name,
        host: host,
        port: port,
        username: username,
        authMethod: AuthMethod.fromName(authMethod),
        hostKeyFingerprint: data['hostKeyFingerprint'] as String?,
        hostKeyAlgorithm: data['hostKeyAlgorithm'] as String?,
        hostKeyTrustedAt: DateTime.tryParse(
          data['hostKeyTrustedAt'] as String? ?? '',
        ),
      );
      final credentials = SshCredentials(
        password: password,
        privateKey: privateKey,
      );
      // The background isolate does not go through
      // SshClientFactory.connectClient when it constructs the client itself.
      // Keep the same fail-closed credential contract before opening a socket
      // or invoking a test seam.
      SshClientFactory.validateAuthSecrets(
        config: config,
        password: credentials.password,
        privateKey: credentials.privateKey,
      );
      late final SSHClient client;
      final sessionFactory = _sessionFactory;
      if (sessionFactory != null) {
        client = await sessionFactory(data);
      } else {
        final socket = await _openBackgroundSshSocket(
          host: host,
          port: port,
          peerId: peerId,
        );
        owner.ownSocket(socket.destroy);
        _ensureConnectCurrent(sessionId, connectToken);
        emitLog(
          'service',
          'SSH socket connected',
          details: 'sessionId=$sessionId host=$host:$port',
        );

        final hostKeyPolicy = SshHostKeyPolicy();

        final identities = await SshClientFactory.identitiesFor(
          config,
          credentials,
        );
        _ensureConnectCurrent(sessionId, connectToken);

        final authOptions = SshClientFactory.buildAuthOptions(
          config: config,
          credentials: credentials,
          identities: identities,
        );

        client = SSHClient(
          socket,
          username: username,
          onVerifyHostKey: (algorithm, fingerprint) =>
              hostKeyPolicy.verifyHostKey(
                config: config,
                algorithm: algorithm,
                md5Fingerprint: fingerprint,
              ),
          identities: authOptions.identities,
          onPasswordRequest: authOptions.onPasswordRequest,
          onUserInfoRequest: authOptions.onUserInfoRequest,
        );
      }
      owner.ownClient(client.close);

      await client.authenticated.timeout(const Duration(seconds: 15));
      _ensureConnectCurrent(sessionId, connectToken);

      if (launchMode == 'tmux') {
        await ensureTmuxInstalled(client: client);
        _ensureConnectCurrent(sessionId, connectToken);
        emitLog(
          'service',
          'tmux available',
          details: 'sessionId=$sessionId tmux=$tmuxSessionName',
        );
      }

      final shell = await client
          .shell(
            pty: SSHPtyConfig(
              width: width,
              height: height,
              type: 'xterm-256color',
            ),
          )
          .timeout(const Duration(seconds: 15));
      owner.ownShell(shell.close);
      _ensureConnectCurrent(sessionId, connectToken);
      emitLog(
        'service',
        'SSH shell opened',
        details: 'sessionId=$sessionId size=${width}x$height mode=$launchMode',
      );

      final runtime = _BackgroundSshSession(
        sessionId: sessionId,
        connectionId: connectionId,
        connectionName: name,
        tmuxSessionName: launchMode == 'tmux' ? tmuxSessionName : null,
        tmuxAutoDeleteSeconds: tmuxAutoDeleteSeconds,
        launchMode: launchMode,
        showServerNameInNotification: showServerNameInNotification,
        reconnectData: sanitizeBackgroundReconnectData(data),
        client: client,
        shell: shell,
      );
      owner.ownRuntime(runtime.close);

      runtime.stdoutSub = shell.stdout.listen(
        (bytes) {
          service.invoke('sshDataReceived', {
            'sessionId': sessionId,
            'data': utf8.decode(bytes, allowMalformed: true),
          });
        },
        onError: (Object error) {
          emitLog(
            'error',
            'SSH stdout stream error',
            details: 'sessionId=$sessionId error=$error',
          );
          unawaited(handleUnexpectedDisconnect(runtime, error.toString()));
        },
        onDone: () {
          emitLog(
            'service',
            'SSH stdout stream closed',
            details: 'sessionId=$sessionId',
          );
          unawaited(handleUnexpectedDisconnect(runtime, 'stdout closed'));
        },
      );

      runtime.stderrSub = shell.stderr.listen((bytes) {
        service.invoke('sshDataReceived', {
          'sessionId': sessionId,
          'data': utf8.decode(bytes, allowMalformed: true),
        });
      });

      if (launchMode == 'tmux') {
        final command = buildTmuxAttachCommand(
          tmuxSessionName,
          tmuxAutoDeleteSeconds,
        );
        emitLog(
          'service',
          'Attaching tmux session',
          details:
              'sessionId=$sessionId tmux=$tmuxSessionName autoDelete=${tmuxAutoDeleteSeconds}s',
        );
        shell.stdin.add(utf8.encode('$command\r'));
      }

      runtime.keepAliveTimer = Timer.periodic(
        Duration(seconds: keepAliveSeconds.clamp(3, 30)),
        (_) async {
          if (runtime.pingInFlight) return;
          runtime.pingInFlight = true;
          try {
            await runtime.client.ping().timeout(const Duration(seconds: 10));
            runtime.keepAliveFailures = 0;
            service.invoke('sshKeepAlive', {
              'sessionId': sessionId,
              'ok': true,
              'timestamp': DateTime.now().toIso8601String(),
            });
          } catch (e) {
            emitLog(
              'warning',
              'SSH keep-alive failed',
              details:
                  'sessionId=${runtime.sessionId} failures=${runtime.keepAliveFailures + 1} error=$e',
            );
            service.invoke('sshKeepAlive', {
              'sessionId': sessionId,
              'ok': false,
              'error': e.toString(),
              'timestamp': DateTime.now().toIso8601String(),
            });
            runtime.keepAliveFailures++;
            await handleUnexpectedDisconnect(runtime, e.toString());
          } finally {
            runtime.pingInFlight = false;
          }
        },
      );

      _ensureConnectCurrent(sessionId, connectToken);
      sessions[sessionId] = runtime;
      owner.commit();

      emitState(
        'connected',
        sessionId: sessionId,
        connectionId: connectionId,
        connectionName: name,
      );
      emitOverview();
      setNotification(notificationSummary());
      emitLog(
        'service',
        'SSH session connected',
        details: 'sessionId=$sessionId connection=$name mode=$launchMode',
      );
    } on _SupersededSshConnection {
      emitLog(
        'service',
        'Discarding superseded SSH connection attempt',
        details: 'sessionId=$sessionId connection=$name',
      );
    } catch (e) {
      if (!_connectGate.isCurrent(sessionId, connectToken)) return;
      await closeSsh(sessionId, notify: false, cancelPending: false);
      emitLog(
        'error',
        'SSH connection failed',
        details: 'sessionId=$sessionId connection=$name error=$e',
      );
      emitState(
        'error',
        sessionId: sessionId,
        message: 'Connection failed: $e',
        connectionId: connectionId,
        connectionName: name,
      );
      setNotification('SSH connection failed');
    } finally {
      try {
        await owner.rollback();
      } catch (error) {
        emitLog(
          'error',
          'Failed to release SSH connection attempt resources',
          details: 'sessionId=$sessionId error=$error',
        );
      }
      _connectGate.finish(sessionId, connectToken);
    }
  }

  void _ensureConnectCurrent(String sessionId, int token) {
    if (_stopping || !_connectGate.isCurrent(sessionId, token)) {
      throw const _SupersededSshConnection();
    }
  }

  Future<void> _trackConnect(Map<String, dynamic> data) {
    if (_stopping) return Future<void>.value();
    late final Future<void> operation;
    operation = connectSsh(data)
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            emitLog(
              'error',
              'Unhandled background SSH connection failure',
              details: 'error=$error\n$stackTrace',
            );
          },
        )
        .whenComplete(() => _connectOperations.remove(operation));
    _connectOperations.add(operation);
    return operation;
  }

  void _listen(String event, void Function(Map<String, dynamic>? data) onData) {
    _eventSubscriptions.add(service.on(event).listen(onData));
  }

  Future<void> _cancelEventSubscriptions() async {
    final subscriptions = _eventSubscriptions.toList(growable: false);
    _eventSubscriptions.clear();
    await Future.wait<void>(
      subscriptions.map((subscription) => subscription.cancel()),
    );
  }

  /// 注册后台事件订阅并发布初始运行状态。
  void start() {
    setNotification('SSH service is running');
    emitLog('service', 'Background SSH service started');

    _listen('sshConnect', (event) {
      if (event != null) {
        emitLog(
          'service',
          'Received sshConnect request',
          details:
              'sessionId=${event['sessionId']} connection=${event['name']}',
        );
        unawaited(_trackConnect(event));
      }
    });

    _listen('sshInput', (event) {
      final sessionId = event?['sessionId'] as String?;
      final data = event?['data'] as String?;
      final session = sessionId == null ? null : sessions[sessionId];
      if (data != null && session != null) {
        session.shell.stdin.add(utf8.encode(data));
      } else if (sessionId != null) {
        emitLog(
          'warning',
          'Ignoring input for missing SSH session',
          details: 'sessionId=$sessionId',
        );
      }
    });

    _listen('sshResize', (event) {
      final sessionId = event?['sessionId'] as String?;
      final width = (event?['width'] as num?)?.toInt();
      final height = (event?['height'] as num?)?.toInt();
      final session = sessionId == null ? null : sessions[sessionId];
      if (width != null && height != null && session != null) {
        session.shell.resizeTerminal(width, height);
        emitLog(
          'service',
          'Resized SSH terminal',
          details: 'sessionId=$sessionId size=${width}x$height',
        );
      }
    });

    _listen('sshDisconnect', (event) {
      final sessionId = event?['sessionId'] as String?;
      if (sessionId != null) {
        emitLog(
          'service',
          'Received sshDisconnect request',
          details: 'sessionId=$sessionId',
        );
        unawaited(closeSsh(sessionId, destroyTmux: true));
      }
    });

    _listen('sshDisconnectAll', (event) async {
      emitLog('service', 'Received sshDisconnectAll request');
      await closeAll();
    });

    _listen('update', (event) {
      setNotification(event?['content'] as String? ?? 'SSH service is running');
    });

    _listen('stopService', (event) async {
      if (_stopping) return;
      emitLog('service', 'Stopping background SSH service');
      _stopping = true;
      try {
        // App shutdown 只释放 SSH transport；tmux 远端 session 仍由恢复记录拥有。
        await closeAll(notify: false, destroyTmux: false);
        await _cancelEventSubscriptions();
      } catch (error) {
        emitLog(
          'error',
          'Background SSH shutdown cleanup failed',
          details: error.toString(),
        );
      } finally {
        service.invoke('sshServiceStopped', {
          'timestamp': DateTime.now().toIso8601String(),
        });
        service.stopSelf();
      }
    });
  }
}

class _BackgroundSshSession {
  final String sessionId;
  final String? connectionId;
  final String connectionName;
  final String? tmuxSessionName;
  final int tmuxAutoDeleteSeconds;
  final String launchMode;
  final bool showServerNameInNotification;
  final Map<String, dynamic> reconnectData;
  final SSHClient client;
  final SSHSession shell;
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
  Timer? keepAliveTimer;
  bool pingInFlight = false;
  int keepAliveFailures = 0;
  Future<void>? _closeFuture;

  _BackgroundSshSession({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.tmuxSessionName,
    required this.tmuxAutoDeleteSeconds,
    required this.launchMode,
    required this.showServerNameInNotification,
    required this.reconnectData,
    required this.client,
    required this.shell,
  });

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    keepAliveTimer?.cancel();
    keepAliveTimer = null;
    final subscriptions = <StreamSubscription<List<int>>>[
      ?stdoutSub,
      ?stderrSub,
    ];
    stdoutSub = null;
    stderrSub = null;
    try {
      await Future.wait<void>(
        subscriptions.map((subscription) => subscription.cancel()),
      );
    } finally {
      shell.close();
      client.close();
      pingInFlight = false;
    }
  }

  Future<void> killTmuxSession() async {
    final name = tmuxSessionName;
    if (launchMode != 'tmux' || name == null || name.isEmpty) return;
    try {
      final quotedName = "'${name.replaceAll("'", "'\"'\"'")}'";
      final command = 'tmux kill-session -t $quotedName 2>/dev/null || true';
      await client
          .runWithResult(command, stdout: false, stderr: false)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
