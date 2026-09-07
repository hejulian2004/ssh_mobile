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

/// Opaque native capability that binds a platform owner to one endpoint
/// identity. It is an identifier, never a Dart/native pointer. Native
/// platform code uses the same token for start/stop, renderer lifecycle, and
/// native-only H.264 push/pull; Dart only opens and closes the capability.
final class NativeRealtimeMediaOwnerToken {
  NativeRealtimeMediaOwnerToken(int value) : value = _validateEndpointId(value);

  final int value;
}

/// Outcome of registering one endpoint with the native platform owner.
final class NativeRealtimeMediaOwnerOpenResult {
  const NativeRealtimeMediaOwnerOpenResult({required this.status, this.token});

  final NativeOperationStatus status;
  final NativeRealtimeMediaOwnerToken? token;

  bool get isSuccess => status.isSuccess && token != null;
}

int _validateEndpointId(int value) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'endpoint ID', 'must be positive');
  }
  return value;
}
