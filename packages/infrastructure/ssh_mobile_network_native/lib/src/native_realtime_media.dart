import 'native_operation_status.dart';

/// Direction granted to one opaque native screen-media endpoint lease.
enum NativeRealtimeMediaDirection {
  send,
  receive;

  int get nativeValue => switch (this) {
    NativeRealtimeMediaDirection.send => 1,
    NativeRealtimeMediaDirection.receive => 2,
  };
}

/// Opaque native endpoint ID. It is valid only for its originating runtime and
/// realtime session generation.
final class NativeRealtimeMediaEndpointId {
  NativeRealtimeMediaEndpointId(int value) : value = _validateEndpointId(value);

  final int value;
}

/// Outcome of requesting one native screen-media endpoint lease.
///
/// The result deliberately contains only an opaque ID. Capture frames, encoded
/// video, peer connections, sockets, and renderer handles remain native-owned.
final class NativeRealtimeMediaEndpointCreateResult {
  const NativeRealtimeMediaEndpointCreateResult({
    required this.status,
    this.endpointId,
  });

  final NativeOperationStatus status;
  final NativeRealtimeMediaEndpointId? endpointId;

  bool get isSuccess => status.isSuccess && endpointId != null;
}

int _validateEndpointId(int value) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'endpoint ID', 'must be positive');
  }
  return value;
}
