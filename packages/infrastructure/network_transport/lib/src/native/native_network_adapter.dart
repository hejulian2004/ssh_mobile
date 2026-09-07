// ssh_mobile_network_native 的生命周期适配器。
//
// 本文件隔离 FFI 类型和 native status 映射；NetworkRuntimeImpl 只持有本文件
// 定义的 handle，确保 create/close 的 Owner 清晰且便于单元测试注入 Fake。

import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

import '../transport/transport_connection.dart';

/// Borrowed native-only media lifecycle operations. The App Shell uses this
/// boundary to create/release opaque screen endpoints; encoded frames never
/// cross into Dart.
abstract interface class NativeRealtimeMediaPort {
  NativeRealtimeMediaEndpointCreateResult createMediaEndpoint({
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  });

  NativeOperationStatus releaseMediaEndpoint(
    NativeRealtimeMediaEndpointId endpointId,
  );
}

/// 创建一个已启动的 native 网络 handle。
abstract interface class NativeNetworkAdapter {
  /// 创建并启动一个 native 网络运行时。
  Future<NativeNetworkHandle> create();
}

/// 已启动 native 网络运行时的最小可测试合约。
abstract interface class NativeNetworkHandle
    implements Disposable, NativeRealtimeMediaPort {
  /// helper isolate 发布的原始事件流。
  Stream<Uint8List> get rawEvents;

  /// 原生可靠传输监听器实际绑定的端口；配置前返回 null。
  int? get boundLocalPort;

  /// 向 native 运行时提交一帧已编码命令。
  TransportOperationStatus sendCommand(Uint8List command);

  /// 显式停止并销毁 native handle。
  Future<void> close();
}

/// 默认的 ssh_mobile_network_native adapter。
final class SshMobileNativeNetworkAdapter implements NativeNetworkAdapter {
  /// 创建无状态 adapter；真正的 native handle 由 [create] 延迟创建。
  const SshMobileNativeNetworkAdapter();

  @override
  Future<NativeNetworkHandle> create() async {
    final runtime = await const SshMobileNetworkNative().createRuntime();
    return _SshMobileNativeNetworkHandle(runtime);
  }
}

/// 将原生运行时映射为 network_transport 的 handle 合约。
final class _SshMobileNativeNetworkHandle implements NativeNetworkHandle {
  /// 接管一个已经启动的原生运行时；关闭责任转移到本对象。
  _SshMobileNativeNetworkHandle(this._runtime);

  final NativeNetworkRuntime _runtime;
  bool _closed = false;

  @override
  Stream<Uint8List> get rawEvents => _runtime.rawEvents;

  @override
  int? get boundLocalPort => _closed ? null : _runtime.boundLocalPort;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    if (_closed) return TransportOperationStatus.stopped;
    return switch (_runtime.sendCommand(command)) {
      NativeOperationStatus.success => TransportOperationStatus.success,
      NativeOperationStatus.invalidArgument =>
        TransportOperationStatus.invalidArgument,
      NativeOperationStatus.stopped => TransportOperationStatus.stopped,
      NativeOperationStatus.failure => TransportOperationStatus.failure,
      // Realtime-media lifecycle statuses are not returned by the generic
      // command ABI. If a future native implementation leaks one through
      // this adapter, preserve fail-closed transport semantics instead of
      // pretending the command succeeded or was merely malformed.
      NativeOperationStatus.unknownSession ||
      NativeOperationStatus.staleGeneration ||
      NativeOperationStatus.staleEndpoint ||
      NativeOperationStatus.directionMismatch ||
      NativeOperationStatus.duplicateEndpoint ||
      NativeOperationStatus.driverUnavailable ||
      NativeOperationStatus.peerMismatch ||
      NativeOperationStatus.frameRejected => TransportOperationStatus.failure,
    };
  }

  @override
  NativeRealtimeMediaEndpointCreateResult createMediaEndpoint({
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  }) => _closed
      ? const NativeRealtimeMediaEndpointCreateResult(
          status: NativeOperationStatus.stopped,
        )
      : _runtime.createRealtimeMediaEndpoint(
          realtimeId: realtimeId,
          peerId: peerId,
          generation: generation,
          direction: direction,
        );

  @override
  NativeOperationStatus releaseMediaEndpoint(
    NativeRealtimeMediaEndpointId endpointId,
  ) => _closed
      ? NativeOperationStatus.success
      : _runtime.releaseRealtimeMediaEndpoint(endpointId);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _runtime.dispose();
  }

  @override
  Future<void> dispose() => close();
}
