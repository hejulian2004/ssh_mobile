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

  test(
    'stateful controller waits three seconds before each congestion step',
    () {
      final controller = RealtimeMediaAdaptationController();
      final first = DateTime.utc(2026, 9, 8, 12);
      const healthy = RealtimeMediaStats(width: 1920, height: 1080);
      const congested = RealtimeMediaStats(
        width: 1920,
        height: 1080,
        packetsReceived: 100,
        packetsLost: 5,
      );

      final steady = controller.decide(healthy, now: first);
      expect(steady.bitrateKbps, 3 * 1024);
      expect(steady.framerate, 15);

      final held = controller.decide(
        congested,
        now: first.add(const Duration(seconds: 2, milliseconds: 999)),
      );
      expect(held.bitrateKbps, 3 * 1024);
      expect(held.framerate, 15);

      final degraded = controller.decide(
        congested,
        now: first.add(const Duration(seconds: 3)),
      );
      expect(degraded.reason, RealtimeMediaAdaptationReason.congestion);
      expect(degraded.bitrateKbps, 2_304);
      expect(degraded.framerate, 10);

      final next = controller.decide(
        congested,
        now: first.add(const Duration(seconds: 5)),
      );
      expect(next.bitrateKbps, 2_304);
      final secondStep = controller.decide(
        congested,
        now: first.add(const Duration(seconds: 6)),
      );
      expect(secondStep.bitrateKbps, 1_728);
      expect(secondStep.framerate, 10);
    },
  );

  test(
    'severe congestion moves to bounded 720p10 and healthy recovers one level',
    () {
      final controller = RealtimeMediaAdaptationController();
      final first = DateTime.utc(2026, 9, 8, 12);
      const severe = RealtimeMediaStats(
        width: 1920,
        height: 1080,
        packetsReceived: 100,
        packetsLost: 10,
        rttMs: 400,
      );
      controller.decide(severe, now: first);
      final degraded = controller.decide(
        severe,
        now: first.add(const Duration(seconds: 3)),
      );
      expect(degraded.width, 1280);
      expect(degraded.height, 720);
      expect(degraded.framerate, 10);

      const healthy = RealtimeMediaStats(
        width: 1920,
        height: 1080,
        packetsReceived: 100,
      );
      final heldHealthy = controller.decide(
        healthy,
        now: first.add(const Duration(seconds: 12)),
      );
      expect(heldHealthy.reason, RealtimeMediaAdaptationReason.recovery);
      expect(heldHealthy.width, 1280);
      expect(heldHealthy.height, 720);

      final recovered = controller.decide(
        healthy,
        now: first.add(const Duration(seconds: 22)),
      );
      expect(recovered.reason, RealtimeMediaAdaptationReason.recovery);
      expect(recovered.width, 1920);
      expect(recovered.height, 1080);
      expect(recovered.framerate, 10);
      expect(recovered.bitrateKbps, greaterThan(1_296));
    },
  );

  test('controller clamps a backwards clock and keeps the queue bound', () {
    final controller = RealtimeMediaAdaptationController();
    final now = DateTime.utc(2026, 9, 8, 12);
    final first = controller.decide(
      const RealtimeMediaStats(width: 1920, height: 1080),
      now: now,
    );
    final backwards = controller.decide(
      const RealtimeMediaStats(width: 1920, height: 1080),
      now: now.subtract(const Duration(hours: 1)),
    );
    expect(backwards.bitrateKbps, first.bitrateKbps);
    expect(backwards.framerate, first.framerate);
    expect(backwards.width, 1920);
    expect(backwards.height, 1080);
    expect(backwards.reason, RealtimeMediaAdaptationReason.steady);
  });

  test('controller learns dimensions after an early metadata-only sample', () {
    final controller = RealtimeMediaAdaptationController();
    final first = DateTime.utc(2026, 9, 8, 12);
    const severeWithoutDimensions = RealtimeMediaStats(
      packetsReceived: 100,
      packetsLost: 10,
      rttMs: 400,
    );
    controller.decide(severeWithoutDimensions, now: first);
    final degraded = controller.decide(
      severeWithoutDimensions,
      now: first.add(const Duration(seconds: 3)),
    );
    expect(degraded.width, 1280);
    expect(degraded.height, 720);

    final dimensionsArrived = controller.decide(
      const RealtimeMediaStats(
        width: 1920,
        height: 1080,
        packetsReceived: 100,
        packetsLost: 10,
        rttMs: 400,
      ),
      now: first.add(const Duration(seconds: 4)),
    );
    expect(dimensionsArrived.width, 1280);
    expect(dimensionsArrived.height, 720);

    final healthy = controller.decide(
      const RealtimeMediaStats(width: 1920, height: 1080, packetsReceived: 100),
      now: first.add(const Duration(seconds: 14)),
    );
    expect(healthy.width, 1920);
    expect(healthy.height, 1080);
  });
}
