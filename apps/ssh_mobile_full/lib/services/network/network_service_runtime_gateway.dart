part of 'network_service.dart';

/// 将 native runtime 适配为共享 gateway；gateway 不拥有 runtime。
final class _NativeRuntimeCommandGateway implements NetworkCommandGateway {
  _NativeRuntimeCommandGateway(this._runtime);

  final NativeNetworkRuntime _runtime;

  @override
  Stream<Uint8List> get events => _runtime.rawEvents;

  @override
  TransportOperationStatus sendCommand(Uint8List command) =>
      switch (_runtime.sendCommand(command)) {
        NativeOperationStatus.success => TransportOperationStatus.success,
        NativeOperationStatus.invalidArgument =>
          TransportOperationStatus.invalidArgument,
        NativeOperationStatus.stopped => TransportOperationStatus.stopped,
        // coverage:ignore-start
        // Native FFI failure codes are exercised by the native Windows/CI
        // smoke gate; the Flutter runner cannot inject a failing ABI handle.
        NativeOperationStatus.failure => TransportOperationStatus.failure,
        NativeOperationStatus.unknownSession ||
        NativeOperationStatus.staleGeneration ||
        NativeOperationStatus.staleEndpoint ||
        NativeOperationStatus.directionMismatch ||
        NativeOperationStatus.duplicateEndpoint ||
        NativeOperationStatus.driverUnavailable ||
        NativeOperationStatus.peerMismatch ||
        NativeOperationStatus.frameRejected => TransportOperationStatus.failure,
        // coverage:ignore-end
      };
}
