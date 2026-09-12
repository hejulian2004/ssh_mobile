/// Opaque identifier for a platform-selected capture source.
final class ScreenCaptureSourceId {
  ScreenCaptureSourceId(String value) : value = _validate(value, 'source ID');

  final String value;
}

/// Kinds of source that a future platform adapter may select.
enum ScreenCaptureSourceKind { display, window }

/// A selection descriptor, not a capture implementation or image buffer.
final class ScreenCaptureSource {
  ScreenCaptureSource({
    required this.id,
    required this.kind,
    this.label,
    this.width,
    this.height,
  }) {
    final sourceWidth = width;
    if (sourceWidth != null && (sourceWidth <= 0 || sourceWidth > 16_384)) {
      throw ArgumentError.value(sourceWidth, 'width');
    }
    final sourceHeight = height;
    if (sourceHeight != null && (sourceHeight <= 0 || sourceHeight > 16_384)) {
      throw ArgumentError.value(sourceHeight, 'height');
    }
    final sourceLabel = label;
    if (sourceLabel != null && sourceLabel.length > 128) {
      throw ArgumentError.value(sourceLabel, 'label');
    }
  }

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
