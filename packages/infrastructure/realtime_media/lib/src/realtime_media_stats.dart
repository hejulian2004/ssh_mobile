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
  });

  final int width;
  final int height;
  final int framesCaptured;
  final int framesSent;
  final int framesDropped;
  final int framesDecoded;
  final int framesRendered;
}
