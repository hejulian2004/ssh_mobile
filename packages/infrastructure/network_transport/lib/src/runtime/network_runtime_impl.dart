// NetworkRuntime 的默认实现。
//
// 实现只负责 Capability 状态机和 native handle Owner，不实现任何具体网络
// 协议。一个 AppRuntime 只应创建一个实例，并在 App 退出时调用 dispose。

import 'dart:async';
import 'dart:typed_data';

import '../config/network_config.dart';
import '../native/network_command_gateway.dart';
import '../native/native_network_adapter.dart';
import '../realtime/network_realtime_gateway.dart';
import '../transport/transport_connection.dart';
import 'network_capability.dart';
import 'network_runtime.dart';

/// `network_transport` 的默认 App Scope 实现。
final class NetworkRuntimeImpl implements NetworkRuntime {
  /// 创建一个未初始化的网络运行时。
  ///
  /// [nativeAdapter] 仅用于 Composition Root 的平台装配和测试替换，Feature
  /// 不应自行创建本实现。
  NetworkRuntimeImpl({
    this.config = const NetworkConfig(),
    NativeNetworkAdapter? nativeAdapter,
  }) : _nativeAdapter = nativeAdapter ?? const SshMobileNativeNetworkAdapter();

  /// 当前 Runtime 允许初始化的 Capability 配置。
  final NetworkConfig config;
  final NativeNetworkAdapter _nativeAdapter;
  final Set<NetworkCapability> _readyCapabilities = <NetworkCapability>{};
  final Map<NetworkCapability, Future<void>> _capabilityInitializations =
      <NetworkCapability, Future<void>>{};
  Future<NativeNetworkHandle>? _nativeHandleInitialization;
  NativeNetworkHandle? _nativeHandle;
  Future<void>? _disposeFuture;
  NetworkRuntimeState _state = NetworkRuntimeState.idle;
  bool _disposed = false;

  @override
  NetworkRuntimeState get state => _state;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: _state,
    // 具体协议连接由 Feature/Service Owner 管理，当前 Facade 不登记它们。
    activeConnections: 0,
    nativeHandles: _nativeHandle == null ? 0 : 1,
    boundLocalPort: _nativeHandle?.boundLocalPort,
    readyCapabilities: _readyCapabilities,
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) {
    _ensureUsable();
    if (!config.allows(capability)) {
      throw UnsupportedError(
        'Network capability is unavailable: ${capability.label}',
      );
    }
    if (_readyCapabilities.contains(capability)) return Future<void>.value();

    final existing = _capabilityInitializations[capability];
    if (existing != null) return existing;

    late final Future<void> initialization;
    initialization = _initializeCapability(capability);
    _capabilityInitializations[capability] = initialization;
    initialization.then<void>(
      (_) {
        if (!identical(
          _capabilityInitializations[capability],
          initialization,
        )) {
          return;
        }
        _capabilityInitializations.remove(capability);
        if (!_disposed) {
          _readyCapabilities.add(capability);
          _state = NetworkRuntimeState.ready;
        }
      },
      onError: (Object _, StackTrace _) {
        // 失败后必须移除 in-flight Future，使下一次调用可以重试。
        if (identical(_capabilityInitializations[capability], initialization)) {
          _capabilityInitializations.remove(capability);
        }
        if (!_disposed && _capabilityInitializations.isEmpty) {
          _state = _nativeHandle == null
              ? NetworkRuntimeState.idle
              : NetworkRuntimeState.ready;
        }
      },
    );
    return initialization;
  }

  @override
  bool isCapabilityReady(NetworkCapability capability) =>
      _readyCapabilities.contains(capability);

  @override
  Future<NetworkCommandGateway> openCommandGateway() async {
    _ensureUsable();
    await ensureCapability(NetworkCapability.runtime);
    final handle = _nativeHandle;
    if (handle == null) {
      throw StateError('Network native handle is unavailable.');
    }
    return _RuntimeCommandGateway(handle);
  }

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async {
    _ensureUsable();
    await ensureCapability(NetworkCapability.realtime);
    final handle = _nativeHandle;
    if (handle == null) {
      throw StateError('Network native handle is unavailable.');
    }
    return RuntimeNetworkRealtimeGateway(
      _RuntimeCommandGateway(handle),
      handle,
    );
  }

  Future<void> _initializeCapability(NetworkCapability capability) async {
    _state = NetworkRuntimeState.starting;
    switch (capability) {
      case NetworkCapability.quic:
      case NetworkCapability.webSocketRelay:
      case NetworkCapability.runtime:
      case NetworkCapability.realtime:
        await _ensureNativeHandle();
      case NetworkCapability.tcp:
      case NetworkCapability.udp:
        // NetworkConfig 已经挡住这两个能力；保留显式分支避免未来新增默认
        // 配置时把未实现协议误当成已初始化。
        throw UnsupportedError(
          'Network capability is not implemented: ${capability.label}',
        );
    }
  }

  Future<NativeNetworkHandle> _ensureNativeHandle() {
    final existing = _nativeHandle;
    if (existing != null) return Future<NativeNetworkHandle>.value(existing);
    final initializing = _nativeHandleInitialization;
    if (initializing != null) return initializing;

    final future = _nativeAdapter.create();
    _nativeHandleInitialization = future;
    future.then<void>(
      (handle) {
        if (identical(_nativeHandleInitialization, future)) {
          _nativeHandleInitialization = null;
        }
        if (!_disposed) _nativeHandle = handle;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_nativeHandleInitialization, future)) {
          _nativeHandleInitialization = null;
        }
      },
    );
    return future;
  }

  @override
  Future<void> dispose() {
    final inFlight = _disposeFuture;
    if (inFlight != null) return inFlight;
    if (_disposed) return Future<void>.value();

    _disposed = true;
    _state = NetworkRuntimeState.stopping;
    final future = _disposeResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    NativeNetworkHandle? handle = _nativeHandle;
    _nativeHandle = null;
    if (handle == null) {
      final initializing = _nativeHandleInitialization;
      if (initializing != null) {
        try {
          handle = await initializing;
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }
    }
    _nativeHandleInitialization = null;
    if (handle != null) await attempt(handle.close);

    _readyCapabilities.clear();
    _capabilityInitializations.clear();
    _state = NetworkRuntimeState.disposed;

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStackTrace ?? StackTrace.current);
    }
  }

  void _ensureUsable() {
    if (_disposed || _state == NetworkRuntimeState.disposed) {
      throw StateError('NetworkRuntime has been disposed.');
    }
  }
}

/// 将 Runtime-owned native handle 暴露为不拥有资源的 gateway。
final class _RuntimeCommandGateway implements NetworkCommandGateway {
  _RuntimeCommandGateway(this._handle);

  final NativeNetworkHandle _handle;

  @override
  Stream<Uint8List> get events => _handle.rawEvents;

  @override
  TransportOperationStatus sendCommand(Uint8List command) =>
      _handle.sendCommand(command);
}
