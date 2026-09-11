import 'realtime_media_endpoint.dart';

/// Opaque capability for a platform-native media owner.
///
/// The value is an identifier allocated by the native runtime. It is not a
/// pointer, endpoint payload, texture handle, or Dart frame buffer. A token is
/// bound to one endpoint identity and must never be reused after close.
final class RealtimeMediaNativeOwnerToken {
  RealtimeMediaNativeOwnerToken(String value) : value = _validate(value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is RealtimeMediaNativeOwnerToken && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// Optional capability implemented by an App-owned endpoint backend that can
/// register the endpoint with the native platform owner. The capability is
/// deliberately separate from [RealtimeMediaBackend] so non-platform tests and
/// Phase 2 callers remain unchanged.
abstract interface class RealtimeMediaNativeOwnerBackend {
  Future<RealtimeMediaNativeOwnerToken> openNativeOwner({
    required RealtimeMediaEndpointId endpointId,
    required RealtimeMediaEndpointIdentity identity,
  });

  Future<void> closeNativeOwner({
    required RealtimeMediaNativeOwnerToken token,
    required RealtimeMediaEndpointIdentity identity,
  });
}

String _validate(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw ArgumentError.value(
      value,
      'native owner token',
      'must contain 1 to 128 characters',
    );
  }
  return normalized;
}
