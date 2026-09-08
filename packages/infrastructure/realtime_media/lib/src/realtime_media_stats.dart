/// Low-frequency, payload-free media counters supplied by a platform adapter.
final class RealtimeMediaStats {
  const RealtimeMediaStats({
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
  }) : assert(width >= 0),
       assert(height >= 0),
       assert(framesCaptured >= 0),
       assert(framesSent >= 0),
       assert(framesDropped >= 0),
       assert(framesDecoded >= 0),
       assert(framesRendered >= 0),
       assert(packetsSent >= 0),
       assert(packetsReceived >= 0),
       assert(packetsLost >= 0),
       assert(framesRecovered >= 0),
       assert(keyframeRequests >= 0),
       assert(jitterMs >= 0),
       assert(rttMs >= 0),
       assert(queueDepth >= 0 && queueDepth <= 3),
       assert(queueCapacity == 3);

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
}
