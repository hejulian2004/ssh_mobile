/// Opaque identifier for a platform-selected capture source.
final class ScreenCaptureSourceId {
  ScreenCaptureSourceId(String value) : value = _validate(value, 'source ID');

  final String value;
}

/// Kinds of source that a future platform adapter may select.
enum ScreenCaptureSourceKind { display, window }

/// A selection descriptor, not a capture implementation or image buffer.
final class ScreenCaptureSource {
  const ScreenCaptureSource({
    required this.id,
    required this.kind,
    this.label,
    this.width,
    this.height,
  }) : assert(width == null || width > 0),
       assert(height == null || height > 0),
       assert(label == null || label.length <= 128),
       assert(width == null || width <= 16_384),
       assert(height == null || height <= 16_384);

  final ScreenCaptureSourceId id;
  final ScreenCaptureSourceKind kind;

  /// Bounded display/window label supplied by the platform, when available.
  ///
  /// This is UI metadata only. It must never contain a native window handle.
  final String? label;

  /// Native source dimensions, when the platform can determine them without
  /// starting capture.
  final int? width;

  /// Native source dimensions, when the platform can determine them without
  /// starting capture.
  final int? height;
}

String _validate(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw ArgumentError.value(value, name, 'must contain 1 to 128 characters');
  }
  return normalized;
}
