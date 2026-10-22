// LAN Relay enrollment 与原生数据面生命周期协调器。
//
// 该 Owner 持有 Relay 状态、凭据刷新、有限重连和事件订阅；借用 Receiver 创建的
// NetworkFacade，但不停止、释放或替换 App Scope 的 NetworkRuntime。

import 'dart:async';

import 'package:network_sdk/network_sdk.dart';

import '../../../domain/lan_relay_ports.dart';
import 'lan_relay_state.dart';

export 'lan_relay_state.dart' show LanRelayLinkState, LanRelayStatus;

/// 创建一个 Relay 重连计时器。
typedef LanRelayTimerFactory =
    Timer Function(Duration delay, void Function() callback);

Timer _createRelayTimer(Duration delay, void Function() callback) =>
    Timer(delay, callback);

/// 独立拥有 Relay enrollment、连接、刷新和退避状态机。
///
/// [LanReceiverCoordinator] 只在原生 Facade 可用时通过 [attachFacade] 借给本类。
/// 本类关闭时只撤销订阅和 enrollment client，不释放借入的 Facade/Runtime。
final class LanRelayCoordinator {
  /// 创建 Relay 生命周期 Owner，并开始观察 endpoint 配置变化。
  LanRelayCoordinator({
    required this.appSettings,
    required this.logger,
    required this.enrollmentService,
    required this.capability,
    required this.onChanged,
    List<Duration> retryDelays = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
    this.timerFactory = _createRelayTimer,
  }) : _retryPolicy = LanRelayRetryPolicy(retryDelays),
       _observedEndpoint = appSettings.relayEndpoint {
    appSettings.addListener(_onAppSettingsChanged);
  }

  /// App Scope 的 Relay endpoint 设置。
  final LanRelaySettingsPort appSettings;

  /// 注入日志端口，只记录不含凭据的错误。
  final LanRelayLoggerPort logger;

  /// 本 Owner 持有的 enrollment 与安全存储客户端。
  final LanRelayEnrollmentPort enrollmentService;

  /// App Scope Runtime 的能力检查适配器；本 Owner 不持有 Runtime。
  final LanRelayCapabilityPort capability;

  /// 状态变化通知，由 Receiver 转发给路由级观察者。
  final void Function() onChanged;

  final LanRelayRetryPolicy _retryPolicy;
  final LanRelayTimerFactory timerFactory;

  NetworkFacade? _networkFacade;
  StreamSubscription<NetworkEvent>? _networkEventSubscription;
  bool _nativeRelayActive = false;
  RelayConnectionState _connectionState = RelayConnectionState.disconnected;
  NetworkError? _error;
  bool _enrolled = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  Future<NetworkResult<void>>? _connectFuture;
  Future<void>? _refreshFuture;
  bool _reconnectEnabled = true;
  bool _explicitlyDisconnected = false;
  bool _applyingEndpoint = false;
  String _observedEndpoint;
  bool _closed = false;
  Future<void>? _closeFuture;

  /// 当前 Relay 配置、连接和自动重连状态。
  LanRelayStatus get status => LanRelayStatus(
    endpoint: appSettings.relayEndpoint,
    state: _connectionState,
    enrolled: _enrolled,
    reconnectAttempt: _reconnectAttempt,
    error: _error,
  );

  /// 原生 Relay 是否已报告连接成功。
  bool get nativeRelayActive => _nativeRelayActive;

  /// 借用一个 Receiver 创建的 Facade，并独占 Relay 生命周期事件订阅。
  Future<void> attachFacade(NetworkFacade facade) async {
    if (_closed) throw StateError('LAN Relay coordinator is closed.');
    if (identical(_networkFacade, facade)) return;
    await _networkEventSubscription?.cancel();
    _networkFacade = facade;
    _networkEventSubscription = facade.events.listen(_handleNetworkEvent);
  }

  /// 撤销 Facade 借用；不停止或释放 Facade。
  Future<void> detachFacade() async {
    await _networkEventSubscription?.cancel();
    _networkEventSubscription = null;
    _networkFacade = null;
    _nativeRelayActive = false;
    _connectionState = RelayConnectionState.disconnected;
  }

  /// 仅保存 Relay origin；端点变化会断开旧 socket 并清除旧 enrollment。
  Future<NetworkResult<void>> saveEndpoint(Uri endpoint) async {
    if (!_isValidEndpoint(endpoint)) {
      return _failure(
        NetworkErrorCode.invalidArgument,
        'Relay endpoint must be an HTTPS origin',
        NetworkOperation.connectRelay,
      );
    }
    final normalized = endpoint
        .replace(path: '', query: null, fragment: null)
        .toString();
    if (normalized != appSettings.relayEndpoint) {
      _disableReconnect();
      await _waitForConnect();
      final disconnected = await _disconnectSocket();
      if (disconnected is NetworkFailure<void>) return disconnected;
      await enrollmentService.clearEnrollment();
      _enrolled = false;
    }
    try {
      _applyingEndpoint = true;
      await appSettings.setRelayEndpoint(normalized);
    } on ArgumentError catch (error) {
      return _failure(
        NetworkErrorCode.invalidArgument,
        error.message?.toString() ?? 'Relay endpoint is invalid',
        NetworkOperation.connectRelay,
      );
    } finally {
      _applyingEndpoint = false;
    }
    _error = null;
    _notify();
    return const NetworkSuccess<void>(null);
  }

  /// 完成凭据 enrollment，并配置原生 Relay 数据面。
  Future<NetworkResult<void>> enroll({
    required Uri endpoint,
    required String enrollmentToken,
  }) async {
    if (!_isValidEndpoint(endpoint)) {
      return _failure(
        NetworkErrorCode.invalidArgument,
        'Relay enrollment endpoint must be an HTTPS origin',
        NetworkOperation.enrollRelay,
      );
    }
    _disableReconnect();
    await _waitForConnect();
    final disconnected = await _disconnectSocket();
    if (disconnected is NetworkFailure<void>) return disconnected;

    final settings = RelaySettings(
      endpoint: endpoint.replace(path: '', query: null, fragment: null),
    );
    final enrollment = await enrollmentService.enroll(
      settings,
      enrollmentToken.trim(),
    );
    if (enrollment is NetworkFailure<void>) {
      _enrolled = false;
      _error = enrollment.error;
      _notify();
      return enrollment;
    }
    try {
      _applyingEndpoint = true;
      await appSettings.setRelayEndpoint(settings.endpoint.toString());
    } finally {
      _applyingEndpoint = false;
    }
    _reconnectEnabled = true;
    _explicitlyDisconnected = false;
    _enrolled = true;
    _error = null;
    final result = await _connect(settings);
    if (result is NetworkFailure<void>) _error = result.error;
    _notify();
    return result;
  }

  /// 加载已存储 enrollment，并配置原生 Relay 连接。
  Future<NetworkResult<void>> connectConfigured() async {
    _stopReconnect();
    _reconnectEnabled = true;
    _explicitlyDisconnected = false;
    return _connectConfigured();
  }

  /// 主动断开 Relay，但保留 endpoint 和 enrollment 供下次连接使用。
  Future<NetworkResult<void>> disconnect() async {
    _disableReconnect();
    await _waitForConnect();
    final result = await _disconnectSocket();
    _notify();
    return result;
  }

  /// 清除 endpoint 与短期 enrollment credential，但保留设备签名种子。
  Future<NetworkResult<void>> clearEnrollment() async {
    _disableReconnect();
    await _waitForConnect();
    final disconnected = await _disconnectSocket();
    await enrollmentService.clearEnrollment();
    _enrolled = false;
    _error = null;
    try {
      _applyingEndpoint = true;
      await appSettings.setRelayEndpoint('');
    } finally {
      _applyingEndpoint = false;
    }
    _notify();
    return disconnected;
  }

  Future<NetworkResult<void>> _connect(RelaySettings settings) async {
    final existing = _connectFuture;
    if (existing != null) return existing;
    final operation = _doConnect(settings);
    _connectFuture = operation;
    try {
      return await operation;
    } finally {
      if (identical(_connectFuture, operation)) _connectFuture = null;
    }
  }

  Future<void> _waitForConnect() async {
    final operation = _connectFuture;
    if (operation == null) return;
    try {
      await operation;
    } on Object {
      // 连接结果通过 NetworkResult 传播；这里仅等待其生命周期结束。
    }
  }

  Future<NetworkResult<void>> _requireCapability() async {
    try {
      await capability.ensureWebSocketRelay();
      return const NetworkSuccess<void>(null);
    } on Object {
      return _failure(
        NetworkErrorCode.relayError,
        'WebSocket Relay capability is unavailable',
        NetworkOperation.connectRelay,
      );
    }
  }

  Future<NetworkResult<void>> _doConnect(RelaySettings settings) async {
    final capability = await _requireCapability();
    if (capability is NetworkFailure<void>) return capability;
    final facade = _networkFacade;
    if (facade == null) {
      return _failure(
        NetworkErrorCode.noRoute,
        'native network runtime is unavailable',
        NetworkOperation.connectRelay,
      );
    }
    final configuration = await enrollmentService.nativeConfiguration(settings);
    if (configuration == null) {
      if (await enrollmentService.hasStoredCredential(settings)) {
        _enrolled = true;
        return _failure(
          NetworkErrorCode.credentialExpired,
          'Relay credential expired; refreshing.',
          NetworkOperation.connectRelay,
        );
      }
      _enrolled = false;
      return _failure(
        NetworkErrorCode.authenticationFailed,
        'Relay enrollment is required',
        NetworkOperation.connectRelay,
      );
    }
    if (_nativeRelayActive ||
        _connectionState == RelayConnectionState.connected ||
        _connectionState == RelayConnectionState.connecting) {
      final disconnected = await _disconnectSocket();
      if (disconnected is NetworkFailure<void>) return disconnected;
    }
    final result = await facade.configureRelay(
      RelayConfig(
        relayUrl: configuration.endpoint.toString(),
        relayCredential: configuration.credential,
        relaySigningSeed: configuration.signingSeed,
      ),
    );
    _nativeRelayActive = result is NetworkSuccess<void>;
    if (result is NetworkFailure<void>) _error = result.error;
    return result;
  }

  Future<NetworkResult<void>> _connectConfigured() async {
    final capability = await _requireCapability();
    if (capability is NetworkFailure<void>) return capability;
    final endpoint = Uri.tryParse(appSettings.relayEndpoint);
    if (endpoint == null || !_isValidEndpoint(endpoint)) {
      return _failure(
        NetworkErrorCode.relayError,
        'Relay configuration is unavailable',
        NetworkOperation.connectRelay,
      );
    }
    final settings = RelaySettings(endpoint: endpoint);
    _enrolled = await enrollmentService.isEnrolled(settings);
    if (!_enrolled) {
      if (await enrollmentService.hasStoredCredential(settings)) {
        _enrolled = true;
        _error = const NetworkError(
          code: NetworkErrorCode.credentialExpired,
          message: 'Relay credential expired; refreshing.',
          operation: NetworkOperation.connectRelay,
        );
        _scheduleReconnect();
        _notify();
        return _failure(
          NetworkErrorCode.credentialExpired,
          'Relay credential expired; refreshing.',
          NetworkOperation.connectRelay,
        );
      }
      final failure = _failure(
        NetworkErrorCode.authenticationFailed,
        'Relay enrollment is required',
        NetworkOperation.connectRelay,
      );
      _error = failure.error;
      _notify();
      return failure;
    }
    final result = await _connect(settings);
    if (result is NetworkFailure<void>) {
      _error = result.error;
      _scheduleReconnect();
    }
    _notify();
    return result;
  }

  Future<NetworkResult<void>> _disconnectSocket() async {
    final facade = _networkFacade;
    _nativeRelayActive = false;
    if (facade == null) {
      _connectionState = RelayConnectionState.disconnected;
      return const NetworkSuccess<void>(null);
    }
    final result = await facade.disconnectRelay();
    if (result is NetworkSuccess<void>) {
      _connectionState = RelayConnectionState.disconnected;
      _error = null;
    }
    return result;
  }

  bool _isValidEndpoint(Uri endpoint) =>
      endpoint.scheme == 'https' &&
      endpoint.host.isNotEmpty &&
      endpoint.userInfo.isEmpty &&
      endpoint.query.isEmpty &&
      endpoint.fragment.isEmpty &&
      (endpoint.path.isEmpty || endpoint.path == '/');

  void _onAppSettingsChanged() {
    final endpoint = appSettings.relayEndpoint;
    if (_observedEndpoint == endpoint) return;
    final previous = _observedEndpoint;
    _observedEndpoint = endpoint;
    if (_applyingEndpoint || previous.isEmpty) return;
    unawaited(_handleExternalEndpointChange());
  }

  Future<void> _handleExternalEndpointChange() async {
    _disableReconnect();
    await _waitForConnect();
    await _disconnectSocket();
    await enrollmentService.clearEnrollment();
    _enrolled = false;
    _error = null;
    _notify();
  }

  void _handleNetworkEvent(NetworkEvent event) {
    if (event is! RelayStateChanged) return;
    _connectionState = event.state;
    _error = event.error;
    _nativeRelayActive = event.state == RelayConnectionState.connected;
    if (event.state == RelayConnectionState.connected) {
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _error = null;
    } else if (event.state == RelayConnectionState.failed ||
        event.state == RelayConnectionState.disconnected) {
      _nativeRelayActive = false;
      if (_reconnectEnabled && !_explicitlyDisconnected && _enrolled) {
        _scheduleReconnect();
      }
    }
    _notify();
  }

  void _scheduleReconnect() {
    final decision = _retryPolicy.decide(
      timerScheduled: _reconnectTimer != null,
      reconnectEnabled: _reconnectEnabled,
      explicitlyDisconnected: _explicitlyDisconnected,
      enrolled: _enrolled,
      state: _connectionState,
      error: _error,
      attempt: _reconnectAttempt,
    );
    if (decision.action == LanRelayRetryAction.none) return;
    if (decision.action == LanRelayRetryAction.stop) {
      _stopReconnect();
      _reconnectEnabled = false;
      _notify();
      return;
    }
    if (decision.action == LanRelayRetryAction.refreshCredential) {
      _stopReconnect();
      unawaited(_refreshAndReconnect());
      _notify();
      return;
    }
    _reconnectAttempt++;
    _reconnectTimer = timerFactory(decision.delay!, () {
      _reconnectTimer = null;
      if (_reconnectEnabled && !_explicitlyDisconnected) {
        unawaited(_connectConfigured());
      }
    });
    _notify();
  }

  Future<void> _refreshAndReconnect() {
    final existing = _refreshFuture;
    if (existing != null) return existing;
    final operation = _refreshAndReconnectInternal();
    _refreshFuture = operation;
    operation.whenComplete(() {
      if (identical(_refreshFuture, operation)) _refreshFuture = null;
    });
    return operation;
  }

  Future<void> _refreshAndReconnectInternal() async {
    try {
      final endpoint = Uri.tryParse(appSettings.relayEndpoint);
      if (endpoint == null || !_isValidEndpoint(endpoint)) {
        _error = _failure(
          NetworkErrorCode.relayError,
          'Relay configuration is unavailable',
          NetworkOperation.connectRelay,
        ).error;
        _notify();
        return;
      }
      final settings = RelaySettings(endpoint: endpoint);
      final refresh = await enrollmentService.refreshCredential(settings);
      if (refresh is NetworkFailure<void>) {
        _stopReconnect();
        if (refresh.error.code == NetworkErrorCode.noRoute) {
          _reconnectEnabled = false;
          _enrolled = false;
        }
        _error = refresh.error;
        _notify();
        return;
      }
      _enrolled = true;
      _error = null;
      final result = await _connect(settings);
      if (result is NetworkFailure<void>) {
        _error = result.error;
        _scheduleReconnect();
      }
      _notify();
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Relay credential refresh failed',
        details: '$error\n$stackTrace',
      );
      _error = _failure(
        NetworkErrorCode.relayError,
        'Relay credential refresh failed.',
        NetworkOperation.connectRelay,
      ).error;
      _notify();
    }
  }

  /// 在后台尝试恢复已保存的 Relay enrollment。
  void connectConfiguredInBackground() {
    final endpoint = Uri.tryParse(appSettings.relayEndpoint);
    if (endpoint == null || !_isValidEndpoint(endpoint)) return;
    _reconnectEnabled = true;
    _explicitlyDisconnected = false;
    unawaited(_connectConfiguredInBackground());
  }

  Future<void> _connectConfiguredInBackground() async {
    try {
      final result = await _connectConfigured();
      if (result is NetworkFailure<void>) {
        logger.warning(
          'Configured Relay connection failed',
          details: result.error.toString(),
        );
      }
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Configured Relay connection failed',
        details: '$error\n$stackTrace',
      );
    }
  }

  void _disableReconnect() {
    _stopReconnect();
    _reconnectEnabled = false;
    _explicitlyDisconnected = true;
  }

  void _stopReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
  }

  void _notify() {
    if (!_closed) onChanged();
  }

  NetworkFailure<void> _failure(
    NetworkErrorCode code,
    String message,
    NetworkOperation operation,
  ) => NetworkFailure(
    NetworkError(code: code, message: message, operation: operation),
  );

  /// 撤销监听器、计时器和 enrollment client；不关闭借入 Facade/Runtime。
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    if (_closed) return;
    _closed = true;
    appSettings.removeListener(_onAppSettingsChanged);
    _disableReconnect();
    await _waitForConnect();
    await detachFacade();
    await enrollmentService.dispose();
  }
}
