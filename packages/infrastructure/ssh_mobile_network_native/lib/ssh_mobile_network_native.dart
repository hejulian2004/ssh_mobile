// ssh_mobile_network_native package 的 Network Protocol V2 Dart 绑定与
// 生命周期封装。
// 网络状态由 Rust 运行时拥有；Dart 只提交命令并轮询类型化线协议事件。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/native_operation_status.dart';
import 'src/native_realtime_media.dart';
import 'src/native_realtime_protocol.dart';
import 'src/network_native_isolate.dart';
export 'src/native_operation_status.dart';
export 'src/native_realtime_media.dart';
export 'src/native_realtime_protocol.dart';

part 'src/native_realtime_media_bindings.dart';

enum _NativeRuntimeLifecycle { running, stopping, stopped, destroyed }

/// ssh_mobile_network_native 的 C ABI FFI 绑定。

/// 返回原生库导出的独立 C ABI 版本。
@Native<Uint32 Function()>(symbol: 'ssh_net_abi_version')
external int _sshNetAbiVersionNative();

/// 创建原生运行时句柄，并写入 [outHandle]。
@Native<Int32 Function(Pointer<Pointer<Void>>)>(
  symbol: 'ssh_net_runtime_create',
)
external int _sshNetRuntimeCreateNative(Pointer<Pointer<Void>> outHandle);

/// 启动已创建的原生运行时。
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_start')
external int _sshNetRuntimeStartNative(Pointer<Void> handle);

/// 查询 native endpoint 实际绑定的 UDP 端口。
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_local_port')
external int _sshNetRuntimeLocalPortNative(Pointer<Void> handle);

/// 停止正在运行的原生运行时。
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_stop')
external int _sshNetRuntimeStopNative(Pointer<Void> handle);

/// 销毁已停止的原生运行时句柄。
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ssh_net_runtime_destroy')
external int _sshNetRuntimeDestroyNative(Pointer<Void> handle);

/// Dart 侧原生网络 SDK 操作的主入口。
class SshMobileNetworkNative {
  /// 创建无状态原生 SDK 外观。
  const SshMobileNetworkNative();

  /// 返回原生库报告的 ABI 版本。
  int getAbiVersion() => _sshNetAbiVersionNative();

  /// 创建并启动带事件轮询器的原生运行时。
  Future<NativeNetworkRuntime> createRuntime() async {
    final outHandle = calloc<Pointer<Void>>();
    try {
      final createResult = NativeOperationStatus.fromNativeCode(
        _sshNetRuntimeCreateNative(outHandle),
      );
      if (!createResult.isSuccess || outHandle.value == nullptr) {
        throw StateError(
          'Native network runtime creation failed (${createResult.name}).',
        );
      }
      final handle = outHandle.value;
      final startResult = NativeOperationStatus.fromNativeCode(
        _sshNetRuntimeStartNative(handle),
      );
      if (!startResult.isSuccess) {
        final stopResult = NativeOperationStatus.fromNativeCode(
          _sshNetRuntimeStopNative(handle),
        );
        if (!stopResult.isSuccess) {
          throw StateError(
            'Native network runtime start failed (${startResult.name}); '
            'cleanup stop failed (${stopResult.name}), handle was not destroyed.',
          );
        }
        final destroyResult = NativeOperationStatus.fromNativeCode(
          _sshNetRuntimeDestroyNative(handle),
        );
        if (!destroyResult.isSuccess) {
          throw StateError(
            'Native network runtime start failed (${startResult.name}); '
            'cleanup destroy failed (${destroyResult.name}).',
          );
        }
        throw StateError(
          'Native network runtime start failed (${startResult.name}).',
        );
      }
      final poller = NetworkNativeIsolate(handle);
      try {
        await poller.startPolling();
      } catch (error, stackTrace) {
        // The poller must confirm isolate exit before either native lifecycle
        // call. If that confirmation fails, do not risk destroying a handle
        // that the worker may still be using.
        await poller.stop();
        final stopResult = NativeOperationStatus.fromNativeCode(
          _sshNetRuntimeStopNative(handle),
        );
        if (!stopResult.isSuccess) {
          throw StateError(
            'Native network runtime startup cleanup stop failed '
            '(${stopResult.name}); handle was not destroyed.',
          );
        }
        final destroyResult = NativeOperationStatus.fromNativeCode(
          _sshNetRuntimeDestroyNative(handle),
        );
        if (!destroyResult.isSuccess) {
          throw StateError(
            'Native network runtime startup cleanup destroy failed '
            '(${destroyResult.name}).',
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      return NativeNetworkRuntime._(handle, poller);
    } finally {
      calloc.free(outHandle);
    }
  }
}

/// 拥有已启动原生运行时及其 helper isolate 事件轮询器。
class NativeNetworkRuntime {
  /// 创建内部运行时封装。
  NativeNetworkRuntime._(this._handle, this._poller);

  Pointer<Void> _handle;
  final NetworkNativeIsolate _poller;
  int _commandSequence = 0;
  _NativeRuntimeLifecycle _lifecycle = _NativeRuntimeLifecycle.running;
  Future<NativeOperationStatus>? _stopFuture;
  Future<void>? _disposeFuture;

  /// 发布 helper isolate 收到的原始 Network Protocol V2 事件帧。
  Stream<Uint8List> get rawEvents => _poller.rawEvents;

  /// Typed native command/event stream. Unknown future events are ignored by
  /// the decoder; [rawEvents] remains available for protocol diagnostics.
  Stream<NativeNetworkEvent> get events => _poller.rawEvents
      .map(_decodeTypedEvent)
      .where((event) => event != null)
      .cast<NativeNetworkEvent>();

  /// 返回 native QUIC endpoint 实际绑定的 UDP 端口。
  ///
  /// 该 getter 仅用于受控集成测试和诊断，不是 NetworkService、Feature 或
  /// 客户端业务 API。runtime 尚未配置监听地址或已经停止时返回 `null`。
  int? get boundLocalPort {
    if (_handle == nullptr || _lifecycle != _NativeRuntimeLifecycle.running) {
      return null;
    }
    final port = _sshNetRuntimeLocalPortNative(_handle);
    return port > 0 ? port : null;
  }

  /// 向原生运行时提交一个已编码命令。
  NativeOperationStatus sendCommand(Uint8List command) {
    if (_handle == nullptr || _lifecycle != _NativeRuntimeLifecycle.running) {
      return NativeOperationStatus.stopped;
    }
    return _poller.sendCommand(command);
  }

  /// Queues an explicit V2 peer configuration without exposing native state.
  NativeOperationStatus upsertPeerV2(NativePeerConfig config) {
    try {
      return sendCommand(
        NativeNetworkProtocol.upsertPeerV2Command(
          commandId: _nextCommandId('peer-upsert-v2'),
          config: config,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  NativeOperationStatus removePeerV2({required String peerId}) {
    try {
      return sendCommand(
        NativeNetworkProtocol.removePeerCommand(
          commandId: _nextCommandId('peer-remove-v2'),
          peerId: peerId,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  NativeOperationStatus sendMessageV2({
    required String peerId,
    required String messageId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
    NativeE2eePolicy e2eePolicy = NativeE2eePolicy.required,
  }) {
    try {
      return sendCommand(
        NativeNetworkProtocol.sendMessageV2Command(
          commandId: _nextCommandId('message-v2'),
          peerId: peerId,
          messageId: messageId,
          channelId: channelId,
          payload: payload,
          deliveryPolicy: deliveryPolicy,
          e2eePolicy: e2eePolicy,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  NativeOperationStatus transferV2({
    required String peerId,
    required String transferId,
    required String filePath,
    int confirmedOffset = 0,
    bool resume = false,
  }) {
    try {
      return sendCommand(
        NativeNetworkProtocol.transferCommand(
          commandId: _nextCommandId('transfer-v2'),
          peerId: peerId,
          transferId: transferId,
          filePath: filePath,
          confirmedOffset: confirmedOffset,
          resume: resume,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  /// Starts a Session-owned WebRTC Realtime route.
  NativeOperationStatus startRealtimeSession({
    required String realtimeId,
    required String peerId,
  }) {
    try {
      return sendCommand(
        NativeNetworkProtocol.startRealtimeSessionCommand(
          commandId: _nextCommandId('realtime-start'),
          realtimeId: realtimeId,
          peerId: peerId,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  /// Stops a Session-owned WebRTC Realtime route.
  NativeOperationStatus stopRealtimeSession({required String realtimeId}) {
    try {
      return sendCommand(
        NativeNetworkProtocol.stopRealtimeSessionCommand(
          commandId: _nextCommandId('realtime-stop'),
          realtimeId: realtimeId,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  /// Requests one native-only media endpoint for the active realtime session.
  ///
  /// Dart receives only the opaque lease ID. The native capture, encoder,
  /// decoder, RTP path, and renderer retain all high-frequency media data.
  NativeRealtimeMediaEndpointCreateResult createRealtimeMediaEndpoint({
    required String realtimeId,
    required String peerId,
    required NativeRealtimeMediaDirection direction,
    required int generation,
  }) {
    if (_handle == nullptr || _lifecycle != _NativeRuntimeLifecycle.running) {
      return const NativeRealtimeMediaEndpointCreateResult(
        status: NativeOperationStatus.stopped,
      );
    }
    if (!_isValidRealtimeMediaId(realtimeId) ||
        !_isValidRealtimeMediaPeerId(peerId) ||
        generation <= 0) {
      return const NativeRealtimeMediaEndpointCreateResult(
        status: NativeOperationStatus.invalidArgument,
      );
    }

    final realtimeIdBytes = utf8.encode(realtimeId);
    final peerIdBytes = utf8.encode(peerId);
    final realtimeIdPointer = realtimeId.toNativeUtf8();
    final peerIdPointer = peerId.toNativeUtf8();
    final outEndpoint = calloc<Uint64>();
    try {
      final status = NativeOperationStatus.fromRealtimeMediaCode(
        _sshNetRealtimeMediaEndpointCreateNative(
          _handle,
          realtimeIdPointer.cast<Uint8>(),
          realtimeIdBytes.length,
          peerIdPointer.cast<Uint8>(),
          peerIdBytes.length,
          generation,
          direction.nativeValue,
          outEndpoint,
        ),
      );
      if (!status.isSuccess || outEndpoint.value == 0) {
        return NativeRealtimeMediaEndpointCreateResult(status: status);
      }
      return NativeRealtimeMediaEndpointCreateResult(
        status: status,
        endpointId: NativeRealtimeMediaEndpointId(outEndpoint.value),
      );
    } finally {
      calloc.free(realtimeIdPointer);
      calloc.free(peerIdPointer);
      calloc.free(outEndpoint);
    }
  }

  /// Releases a media endpoint ID. Releasing after native shutdown is a safe
  /// no-op because shutdown invalidates the whole endpoint generation first.
  NativeOperationStatus releaseRealtimeMediaEndpoint(
    NativeRealtimeMediaEndpointId endpointId,
  ) {
    if (_handle == nullptr || _lifecycle != _NativeRuntimeLifecycle.running) {
      return NativeOperationStatus.success;
    }
    return NativeOperationStatus.fromRealtimeMediaCode(
      _sshNetRealtimeMediaEndpointReleaseNative(_handle, endpointId.value),
    );
  }

  /// Sends a bounded SDP/ICE/close signal through the native control plane.
  NativeOperationStatus sendRealtimeSignal({
    required String realtimeId,
    required String peerId,
    required NativeRealtimeSignalKind kind,
    required int revision,
    required Uint8List payload,
  }) {
    try {
      return sendCommand(
        NativeNetworkProtocol.sendRealtimeSignalCommand(
          commandId: _nextCommandId('realtime-signal'),
          realtimeId: realtimeId,
          peerId: peerId,
          kind: kind,
          revision: revision,
          payload: payload,
        ),
      );
    } on ArgumentError {
      return NativeOperationStatus.invalidArgument;
    }
  }

  /// 在停止原生运行时前停止 helper isolate。
  Future<NativeOperationStatus> stop() {
    if (_lifecycle == _NativeRuntimeLifecycle.destroyed ||
        _lifecycle == _NativeRuntimeLifecycle.stopped) {
      return Future<NativeOperationStatus>.value(NativeOperationStatus.success);
    }
    final inFlight = _stopFuture;
    if (inFlight != null) return inFlight;
    _lifecycle = _NativeRuntimeLifecycle.stopping;
    final future = _stopInternal();
    _stopFuture = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_stopFuture, future)) _stopFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_stopFuture, future)) _stopFuture = null;
        },
      ),
    );
    return future;
  }

  /// 恰好执行一次运行时停止和销毁。
  Future<void> dispose() {
    if (_lifecycle == _NativeRuntimeLifecycle.destroyed) {
      return Future<void>.value();
    }
    final inFlight = _disposeFuture;
    if (inFlight != null) return inFlight;
    final future = _disposeInternal();
    _disposeFuture = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_disposeFuture, future)) _disposeFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_disposeFuture, future)) _disposeFuture = null;
        },
      ),
    );
    return future;
  }

  Future<NativeOperationStatus> _stopInternal() async {
    await _poller.stop();
    final handle = _handle;
    if (handle == nullptr) {
      _lifecycle = _NativeRuntimeLifecycle.destroyed;
      return NativeOperationStatus.success;
    }
    final result = NativeOperationStatus.fromNativeCode(
      _sshNetRuntimeStopNative(handle),
    );
    if (result.isSuccess) _lifecycle = _NativeRuntimeLifecycle.stopped;
    return result;
  }

  Future<void> _disposeInternal() async {
    final stopResult = await stop();
    if (!stopResult.isSuccess) {
      throw StateError(
        'Native network runtime stop failed (${stopResult.name}).',
      );
    }
    final handle = _handle;
    if (handle == nullptr) {
      throw StateError(
        'Native network runtime handle disappeared before destroy.',
      );
    }
    final result = NativeOperationStatus.fromNativeCode(
      _sshNetRuntimeDestroyNative(handle),
    );
    if (!result.isSuccess) {
      throw StateError(
        'Native network runtime destroy failed (${result.name}).',
      );
    }
    _handle = nullptr;
    _lifecycle = _NativeRuntimeLifecycle.destroyed;
  }

  String _nextCommandId(String operation) {
    _commandSequence = (_commandSequence + 1) & 0x7fffffff;
    return '$operation-${DateTime.now().microsecondsSinceEpoch}-$_commandSequence';
  }

  static NativeNetworkEvent? _decodeTypedEvent(Uint8List bytes) {
    try {
      return NativeNetworkProtocol.decodeEvent(bytes);
    } on FormatException {
      return null;
    }
  }
}

bool _isValidRealtimeMediaId(String value) =>
    RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

bool _isValidRealtimeMediaPeerId(String value) {
  final bytes = utf8.encode(value);
  return value.trim().isNotEmpty && bytes.length <= 128;
}
