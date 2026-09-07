/// Opaque identifier for a platform-selected capture source.
final class ScreenCaptureSourceId {
  ScreenCaptureSourceId(String value) : value = _validate(value, 'source ID');

  final String value;
}

/// Kinds of source that a future platform adapter may select.
enum ScreenCaptureSourceKind { display, window }

/// A selection descriptor, not a capture implementation or image buffer.
final class ScreenCaptureSource {
  const ScreenCaptureSource({required this.id, required this.kind});

  final ScreenCaptureSourceId id;
  final ScreenCaptureSourceKind kind;
}

String _validate(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw ArgumentError.value(value, name, 'must contain 1 to 128 characters');
  }
  return normalized;
}
