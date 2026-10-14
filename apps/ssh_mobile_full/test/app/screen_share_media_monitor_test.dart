import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:ssh_mobile/app/screen_share_media_monitor.dart';

void main() {
  _testWithClock('logs bounded progress and cancels on disposal', (clock) {
    final logger = _Logger();
    var reads = 0;
    RealtimeMediaStats? observed;
    final monitor = AppScreenShareMediaMonitor(
      direction: RealtimeMediaDirection.receive,
      logger: logger,
      onStats: (stats) => observed = stats,
      isCurrent: () => true,
      onFailure: (_) => fail('healthy worker must not fail'),
      readStats: () async {
        reads++;
        return RealtimeMediaStats(
          width: 1080,
          height: 2424,
          packetsReceived: 15,
          framesDecoded: 3,
          framesRendered: 2,
          queueDepth: 2,
          keyframeRequests: 7,
        );
      },
    );
    _pump(clock, const Duration(seconds: 5));
    expect(
      logger.messages.single,
      contains('received=15 decoded=3 rendered=2'),
    );
    expect(logger.messages.single, contains('size=1080x2424'));
    expect(logger.messages.single, contains('queue=2 keyframes=7'));
    expect(observed?.width, 1080);
    monitor.dispose();
    monitor.dispose();
    _pump(clock, const Duration(seconds: 10));
    expect(reads, 1);
  });

  for (final code in [
    RealtimeMediaErrorCode.encoderFailed,
    RealtimeMediaErrorCode.encoderUnavailable,
    RealtimeMediaErrorCode.decoderFailed,
    RealtimeMediaErrorCode.decoderUnavailable,
    RealtimeMediaErrorCode.captureSourceEnded,
    RealtimeMediaErrorCode.permissionDenied,
    RealtimeMediaErrorCode.frameRejected,
    RealtimeMediaErrorCode.recreateRequired,
  ]) {
    _testWithClock('reports ${code.name} once without native payload', (clock) {
      final logger = _Logger();
      final errors = <RealtimeMediaErrorCode>[];
      final monitor = AppScreenShareMediaMonitor(
        direction: RealtimeMediaDirection.send,
        logger: logger,
        isCurrent: () => true,
        onFailure: errors.add,
        readStats: () async =>
            throw RealtimeMediaException(code, 'private-payload'),
      );
      _pump(clock, const Duration(seconds: 5));
      _pump(clock, const Duration(seconds: 10));
      expect(errors, [code]);
      expect(logger.messages, ['Screen-share media send failed: ${code.name}']);
      monitor.dispose();
    });
  }

  _testWithClock('temporary and untyped statistics errors are retryable', (
    clock,
  ) {
    var reads = 0;
    final logger = _Logger();
    final monitor = AppScreenShareMediaMonitor(
      direction: RealtimeMediaDirection.receive,
      logger: logger,
      isCurrent: () => true,
      onFailure: (_) => fail('unavailable snapshot must not fail media'),
      readStats: () async {
        reads++;
        if (reads == 1) {
          throw const RealtimeMediaException(
            RealtimeMediaErrorCode.backendFailure,
            'private-payload',
          );
        }
        if (reads == 2) throw StateError('private-payload');
        return RealtimeMediaStats();
      },
    );
    for (var tick = 0; tick < 3; tick++) {
      _pump(clock, const Duration(seconds: 5));
    }
    expect(reads, 3);
    expect(logger.messages, hasLength(3));
    expect(logger.messages.join(), isNot(contains('private-payload')));
    monitor.dispose();
  });

  _testWithClock('does not overlap requests or publish late results', (clock) {
    final pending = Completer<RealtimeMediaStats>();
    var reads = 0;
    final logger = _Logger();
    final monitor = AppScreenShareMediaMonitor(
      direction: RealtimeMediaDirection.send,
      logger: logger,
      isCurrent: () => true,
      onFailure: (_) => fail('disposed owner must not report a late error'),
      readStats: () {
        reads++;
        return pending.future;
      },
    );
    _pump(clock, const Duration(seconds: 5));
    _pump(clock, const Duration(seconds: 10));
    expect(reads, 1);
    monitor.dispose();
    pending.completeError(
      const RealtimeMediaException(
        RealtimeMediaErrorCode.encoderFailed,
        'private-payload',
      ),
    );
    _pump(clock);
    expect(logger.messages, isEmpty);
  });

  _testWithClock('invalid generation cancels before sampling', (clock) {
    final monitor = AppScreenShareMediaMonitor(
      direction: RealtimeMediaDirection.receive,
      isCurrent: () => false,
      onFailure: (_) => fail('stale owner must not report an error'),
      readStats: () async => throw StateError('must not sample stale owner'),
    );
    _pump(clock, const Duration(seconds: 20));
    monitor.dispose();
  });

  _testWithClock(
    'generation replacement suppresses a pending successful read',
    (clock) {
      var current = true;
      final pending = Completer<RealtimeMediaStats>();
      final logger = _Logger();
      final monitor = AppScreenShareMediaMonitor(
        direction: RealtimeMediaDirection.receive,
        logger: logger,
        isCurrent: () => current,
        onFailure: (_) => fail('stale owner must not report an error'),
        readStats: () => pending.future,
      );
      _pump(clock, const Duration(seconds: 5));
      current = false;
      pending.complete(RealtimeMediaStats());
      _pump(clock);
      _pump(clock, const Duration(seconds: 5));
      expect(logger.messages, isEmpty);
      monitor.dispose();
    },
  );

  _testWithClock('healthy monitoring does not require a logger', (clock) {
    final monitor = AppScreenShareMediaMonitor(
      direction: RealtimeMediaDirection.receive,
      isCurrent: () => true,
      onFailure: (_) => fail('healthy worker must not fail'),
      readStats: () async => RealtimeMediaStats(),
    );
    _pump(clock, const Duration(seconds: 5));
    monitor.dispose();
  });
}

final class _Logger implements AppLogger {
  final messages = <String>[];
  @override
  void log(LogRecord record) => messages.add(record.message);
  @override
  AppLogger scope(String name) => this;
}

void _testWithClock(String name, void Function(FakeAsync) body) {
  test(name, () => fakeAsync(body));
}

void _pump(FakeAsync clock, [Duration duration = Duration.zero]) {
  clock.elapse(duration);
  clock.flushMicrotasks();
}
