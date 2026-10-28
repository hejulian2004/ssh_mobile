import 'dart:async';
import 'dart:typed_data';

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('codec round-trips marks and ignores an unknown version', () {
    const begin = AnnotationStrokeBegin(
      sequence: 1,
      generation: 7,
      operationId: 'operation-a',
      strokeId: 3,
      color: ScreenShareAnnotationColor.amber,
      width: 24,
    );
    final decoded = ScreenShareAnnotationCodec.decode(
      ScreenShareAnnotationCodec.encode(begin),
    );
    expect(decoded, isA<AnnotationStrokeBegin>());
    final stroke = decoded! as AnnotationStrokeBegin;
    expect(stroke.strokeId, 3);
    expect(stroke.color, ScreenShareAnnotationColor.amber);
    expect(stroke.width, 24);
    expect(stroke.generation, 7);

    final points =
        ScreenShareAnnotationCodec.decode(
              ScreenShareAnnotationCodec.encode(
                const AnnotationStrokePoints(
                  sequence: 2,
                  generation: 7,
                  operationId: 'operation-a',
                  strokeId: 3,
                  points: [ScreenShareAnnotationPoint(0, 65535)],
                ),
              ),
            )!
            as AnnotationStrokePoints;
    expect(points.points.single, const ScreenShareAnnotationPoint(0, 65535));

    final hidden =
        ScreenShareAnnotationCodec.decode(
              ScreenShareAnnotationCodec.encode(
                const AnnotationPointer(
                  sequence: 3,
                  generation: 7,
                  operationId: 'operation-a',
                  visible: false,
                ),
              ),
            )!
            as AnnotationPointer;
    expect(hidden.visible, isFalse);
    expect(hidden.point, isNull);

    final unknown = Uint8List.fromList(
      ScreenShareAnnotationCodec.encode(begin),
    );
    unknown[0] = 2;
    expect(ScreenShareAnnotationCodec.decode(unknown), isNull);
    expect(
      ScreenShareAnnotationCodec.decode(Uint8List.fromList(const [1, 99])),
      isNull,
    );
  });

  test('view points invert clockwise quarter turns and reject the margin', () {
    expect(
      mapViewPointToFrame(dx: 0, dy: 0, viewWidth: 100, viewHeight: 100),
      const ScreenShareAnnotationPoint(0, 0),
    );
    expect(
      mapViewPointToFrame(
        dx: 100,
        dy: 0,
        viewWidth: 100,
        viewHeight: 100,
        quarterTurns: 1,
      ),
      const ScreenShareAnnotationPoint(0, 0),
    );
    expect(
      mapViewPointToFrame(
        dx: 0,
        dy: 0,
        viewWidth: 100,
        viewHeight: 100,
        quarterTurns: 1,
      ),
      const ScreenShareAnnotationPoint(0, 65535),
    );
    expect(
      mapViewPointToFrame(
        dx: 100,
        dy: 100,
        viewWidth: 100,
        viewHeight: 100,
        quarterTurns: 2,
      ),
      const ScreenShareAnnotationPoint(0, 0),
    );
    expect(
      mapViewPointToFrame(
        dx: 0,
        dy: 0,
        viewWidth: 100,
        viewHeight: 100,
        quarterTurns: 3,
      ),
      const ScreenShareAnnotationPoint(65535, 0),
    );
    expect(
      mapViewPointToFrame(dx: -1, dy: 0, viewWidth: 100, viewHeight: 100),
      isNull,
    );
    expect(
      mapViewPointToFrame(dx: 101, dy: 0, viewWidth: 100, viewHeight: 100),
      isNull,
    );
    expect(annotationStrokeWidth(width: 24, frameShortSide: 1000), 24);
    expect(annotationStrokeWidth(width: 1, frameShortSide: 1000), 4);
  });

  test(
    'stale generation, closed channel, and the stroke cap stay local',
    () async {
      final transport = _Transport();
      final session = ScreenShareAnnotationSession(
        operationId: 'operation-a',
        generation: 7,
        transport: transport,
      );
      session.start();
      expect(
        session.beginStroke(const ScreenShareAnnotationPoint(1, 1)),
        isFalse,
      );

      transport.open = true;
      transport.channel.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(
        session.beginStroke(const ScreenShareAnnotationPoint(1, 1), width: 1),
        isTrue,
      );
      expect(session.strokes.single.width, 4);
      expect(session.endStroke(), isTrue);

      transport.data.add(
        ScreenShareAnnotationCodec.encode(
          const AnnotationStrokeBegin(
            sequence: 1,
            generation: 9,
            operationId: 'operation-a',
            strokeId: 99,
            color: ScreenShareAnnotationColor.blue,
            width: 24,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.strokes, hasLength(1));

      for (var i = 0; i < maxAnnotationStrokes - 1; i++) {
        expect(session.beginStroke(ScreenShareAnnotationPoint(i, i)), isTrue);
        expect(session.endStroke(), isTrue);
      }
      expect(session.strokes, hasLength(maxAnnotationStrokes));
      expect(
        session.beginStroke(const ScreenShareAnnotationPoint(8, 8)),
        isTrue,
      );
      expect(session.strokes, hasLength(maxAnnotationStrokes));
      expect(
        transport.sent
            .map(ScreenShareAnnotationCodec.decode)
            .whereType<AnnotationRetire>(),
        isNotEmpty,
      );

      transport.failSend = true;
      transport.channel.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.strokes, isEmpty);
      expect(session.canPaint, isFalse);
      session.dispose();
    },
  );

  test('a laser pointer does not leave ink and collapses a burst', () async {
    final transport = _Transport();
    transport.open = true;
    void Function()? pending;
    var now = DateTime.utc(2026);
    final session = ScreenShareAnnotationSession(
      operationId: 'operation-a',
      generation: 7,
      transport: transport,
      clock: () => now,
      schedule: (delay, callback) => pending = callback,
    );
    session.start();
    expect(session.showPointer(const ScreenShareAnnotationPoint(4, 5)), isTrue);
    expect(session.showPointer(const ScreenShareAnnotationPoint(6, 7)), isTrue);
    expect(session.strokes, isEmpty);
    expect(session.pointer, const ScreenShareAnnotationPoint(6, 7));
    expect(
      transport.sent
          .map(ScreenShareAnnotationCodec.decode)
          .whereType<AnnotationPointer>(),
      hasLength(1),
    );
    pending!.call();
    expect(
      transport.sent
          .map(ScreenShareAnnotationCodec.decode)
          .whereType<AnnotationPointer>(),
      hasLength(2),
    );
    expect(session.hidePointer(), isTrue);
    expect(session.pointer, isNull);

    final display = ScreenShareAnnotationSession(
      operationId: 'operation-a',
      generation: 7,
      transport: transport,
      canDraw: false,
    );
    display.start();
    display.publishDisplayReady(false);
    final ready =
        ScreenShareAnnotationCodec.decode(transport.sent.last)!
            as AnnotationDisplayReady;
    expect(ready.ready, isFalse);
    session.dispose();
    display.dispose();
  });

  test('a display session keeps incoming stroke points', () async {
    final transport = _Transport();
    final session = ScreenShareAnnotationSession(
      operationId: 'operation-a',
      generation: 7,
      transport: transport,
      canDraw: false,
    );
    session.start();
    transport.data.add(
      ScreenShareAnnotationCodec.encode(
        const AnnotationStrokeBegin(
          sequence: 1,
          generation: 7,
          operationId: 'operation-a',
          strokeId: 3,
          color: ScreenShareAnnotationColor.red,
          width: 80,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    transport.data.add(
      ScreenShareAnnotationCodec.encode(
        const AnnotationStrokePoints(
          sequence: 2,
          generation: 7,
          operationId: 'operation-a',
          strokeId: 3,
          points: [
            ScreenShareAnnotationPoint(4000, 8000),
            ScreenShareAnnotationPoint(62000, 56000),
          ],
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.strokes.single.points, [
      const ScreenShareAnnotationPoint(4000, 8000),
      const ScreenShareAnnotationPoint(62000, 56000),
    ]);
    session.dispose();
  });

  testWidgets('the canvas draws inside the frame and ignores a closed pen', (
    tester,
  ) async {
    final transport = _Transport();
    final session = ScreenShareAnnotationSession(
      operationId: 'operation-a',
      generation: 7,
      transport: transport,
    )..start();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 400,
              child: ScreenShareAnnotationCanvas(
                session: session,
                painting: true,
                tool: ScreenShareAnnotationTool.pen,
                color: ScreenShareAnnotationColor.red,
              ),
            ),
          ),
        ),
      ),
    );
    expect(session.canPaint, isFalse);
    transport.channel.add(true);
    await tester.pump();
    expect(session.canPaint, isTrue);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ScreenShareAnnotationCanvas)),
    );
    await gesture.moveBy(const Offset(12, 4));
    await gesture.up();
    await tester.pump();
    expect(session.strokes, hasLength(1));
    expect(session.strokes.single.points, isNotEmpty);
    session.dispose();
  });
}

final class _Transport implements ScreenShareAnnotationTransport {
  final StreamController<bool> channel = StreamController<bool>.broadcast();
  final StreamController<Uint8List> data =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> sent = <Uint8List>[];
  bool open = false;
  bool failSend = false;

  @override
  bool get channelOpen => open;

  @override
  Stream<bool> get channelEvents => channel.stream;

  @override
  Stream<Uint8List> get incoming => data.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    if (failSend) throw StateError('closed');
    sent.add(Uint8List.fromList(bytes));
  }
}
