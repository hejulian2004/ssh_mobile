/// Low-frequency, payload-free media counters supplied by a platform adapter.
final class RealtimeMediaStats {
  RealtimeMediaStats({
    this.width = 0,
    this.height = 0,
    this.framesCaptured = 0,
    this.framesSent = 0,
    this.framesDropped = 0,
    this.framesDecoded = 0,
    this.framesRendered = 0,
    this.packetsSent = 0,
    this.packetsReceived = 0,
    this.packetsLost = 0,
    this.framesRecovered = 0,
    this.keyframeRequests = 0,
    this.jitterMs = 0,
    this.rttMs = 0,
    this.queueDepth = 0,
    this.queueCapacity = 3,
  }) {
    _requireNonNegative(width, 'width');
    _requireNonNegative(height, 'height');
    _requireNonNegative(framesCaptured, 'framesCaptured');
    _requireNonNegative(framesSent, 'framesSent');
    _requireNonNegative(framesDropped, 'framesDropped');
    _requireNonNegative(framesDecoded, 'framesDecoded');
    _requireNonNegative(framesRendered, 'framesRendered');
    _requireNonNegative(packetsSent, 'packetsSent');
    _requireNonNegative(packetsReceived, 'packetsReceived');
    _requireNonNegative(packetsLost, 'packetsLost');
    _requireNonNegative(framesRecovered, 'framesRecovered');
    _requireNonNegative(keyframeRequests, 'keyframeRequests');
    _requireNonNegative(jitterMs, 'jitterMs');
    _requireNonNegative(rttMs, 'rttMs');
    if (queueDepth < 0 || queueDepth > 3) {
      throw ArgumentError.value(queueDepth, 'queueDepth');
    }
    if (queueCapacity != 3) {
      throw ArgumentError.value(queueCapacity, 'queueCapacity');
    }
  }

  final int width;
  final int height;
  final int framesCaptured;
  final int framesSent;
  final int framesDropped;
  final int framesDecoded;
  final int framesRendered;

  /// Native counters sampled at a low frequency (normally about 1 Hz).
  final int packetsSent;
  final int packetsReceived;
  final int packetsLost;
  final int framesRecovered;
  final int keyframeRequests;
  final int jitterMs;
  final int rttMs;

  /// Current bounded media queue occupancy. Screen video remains capped at
  /// three frames; this value is observational and never a resize request.
  final int queueDepth;
  final int queueCapacity;

  RealtimeMediaStats copyWith({
    int? width,
    int? height,
    int? framesCaptured,
    int? framesSent,
    int? framesDropped,
    int? framesDecoded,
    int? framesRendered,
    int? packetsSent,
    int? packetsReceived,
    int? packetsLost,
    int? framesRecovered,
    int? keyframeRequests,
    int? jitterMs,
    int? rttMs,
    int? queueDepth,
    int? queueCapacity,
  }) => RealtimeMediaStats(
    width: width ?? this.width,
    height: height ?? this.height,
    framesCaptured: framesCaptured ?? this.framesCaptured,
    framesSent: framesSent ?? this.framesSent,
    framesDropped: framesDropped ?? this.framesDropped,
    framesDecoded: framesDecoded ?? this.framesDecoded,
    framesRendered: framesRendered ?? this.framesRendered,
    packetsSent: packetsSent ?? this.packetsSent,
    packetsReceived: packetsReceived ?? this.packetsReceived,
    packetsLost: packetsLost ?? this.packetsLost,
    framesRecovered: framesRecovered ?? this.framesRecovered,
    keyframeRequests: keyframeRequests ?? this.keyframeRequests,
    jitterMs: jitterMs ?? this.jitterMs,
    rttMs: rttMs ?? this.rttMs,
    queueDepth: queueDepth ?? this.queueDepth,
    queueCapacity: queueCapacity ?? this.queueCapacity,
  );

  static void _requireNonNegative(int value, String name) {
    if (value < 0) throw ArgumentError.value(value, name);
  }
}
