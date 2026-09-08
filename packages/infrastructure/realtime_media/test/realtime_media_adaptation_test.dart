import 'package:realtime_media/realtime_media.dart';
import 'package:test/test.dart';

void main() {
  const policy = RealtimeMediaAdaptationPolicy();

  test('steady state keeps bounded full target and dimensions', () {
    final decision = policy.decide(
      const RealtimeMediaStats(width: 1920, height: 1080),
    );
    expect(decision.reason, RealtimeMediaAdaptationReason.steady);
    expect(decision.bitrateKbps, 3 * 1024);
    expect(decision.framerate, 15);
    expect(decision.width, 1920);
    expect(decision.height, 1080);
  });

  test('loss, jitter and full queue select a bounded congestion target', () {
    final decision = policy.decide(
      const RealtimeMediaStats(
        width: 3840,
        height: 2160,
        packetsLost: 2,
        jitterMs: 120,
        rttMs: 300,
        queueDepth: 3,
      ),
    );
    expect(decision.reason, RealtimeMediaAdaptationReason.congestion);
    expect(decision.bitrateKbps, 1536);
    expect(decision.framerate, 7);
    expect(decision.width, 1920);
    expect(decision.height, 1080);
  });

  test('recovery target remains finite and never changes queue capacity', () {
    final decision = policy.decide(
      const RealtimeMediaStats(
        width: 1280,
        height: 720,
        framesRecovered: 1,
        keyframeRequests: 1,
      ),
    );
    expect(decision.reason, RealtimeMediaAdaptationReason.recovery);
    expect(decision.bitrateKbps, 2304);
    expect(decision.framerate, 11);
    expect(const RealtimeMediaStats().queueCapacity, 3);
    expect(
      () => RealtimeMediaStats(queueDepth: 4),
      throwsA(isA<AssertionError>()),
    );
  });

  test('keyframe limiter bounds a burst without mutating the media queue', () {
    final limiter = RealtimeMediaKeyframeRequestLimiter(
      minimumInterval: const Duration(seconds: 1),
    );
    final first = DateTime.utc(2026, 9, 8, 12);
    expect(limiter.allow(first), isTrue);
    expect(
      limiter.allow(first.add(const Duration(milliseconds: 999))),
      isFalse,
    );
    expect(limiter.allow(first.add(const Duration(seconds: 1))), isTrue);
  });
}
