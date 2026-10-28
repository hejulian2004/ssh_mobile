import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'screen_share_annotation_codec.dart';
import 'screen_share_annotation_session.dart';

/// Capture-frame ink drawn inside the unrotated video child.
final class ScreenShareAnnotationCanvas extends StatelessWidget {
  const ScreenShareAnnotationCanvas({
    required this.session,
    required this.painting,
    required this.tool,
    required this.color,
    super.key,
  });

  final ScreenShareAnnotationSession session;
  final bool painting;
  final ScreenShareAnnotationTool tool;
  final ScreenShareAnnotationColor color;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final open = painting && session.canPaint;
      return IgnorePointer(
        ignoring: !open,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) =>
                  _begin(event.localPosition, width, height),
              onPointerMove: (event) =>
                  _move(event.localPosition, width, height),
              onPointerUp: (_) => _end(),
              onPointerCancel: (_) => _end(),
              child: CustomPaint(
                painter: _AnnotationPainter(
                  strokes: session.strokes,
                  pointer: session.pointer,
                ),
                child: const SizedBox.expand(),
              ),
            );
          },
        ),
      );
    },
  );

  void _begin(Offset position, double width, double height) {
    final point = _point(position, width, height);
    if (point == null) return;
    if (tool == ScreenShareAnnotationTool.laser) {
      session.showPointer(point);
      return;
    }
    session.beginStroke(point, color: color);
  }

  void _move(Offset position, double width, double height) {
    final point = _point(position, width, height);
    if (point == null) return;
    if (tool == ScreenShareAnnotationTool.laser) {
      session.showPointer(point);
      return;
    }
    session.extendStroke(point);
  }

  void _end() {
    if (tool == ScreenShareAnnotationTool.laser) {
      session.hidePointer();
      return;
    }
    session.endStroke();
  }

  ScreenShareAnnotationPoint? _point(
    Offset position,
    double width,
    double height,
  ) => mapViewPointToFrame(
    dx: position.dx,
    dy: position.dy,
    viewWidth: width,
    viewHeight: height,
  );
}

final class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter({required this.strokes, required this.pointer});

  final List<ScreenShareAnnotationStroke> strokes;
  final ScreenShareAnnotationPoint? pointer;

  @override
  void paint(Canvas canvas, Size size) {
    final shortSide = math.min(size.width, size.height);
    for (final stroke in strokes) {
      final points = stroke.points;
      if (points.isEmpty) continue;
      final paint = Paint()
        ..color = _color(stroke.color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = annotationStrokeWidth(
          width: stroke.width,
          frameShortSide: shortSide,
        )
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()
        ..moveTo(_dx(points.first.x, size), _dy(points.first.y, size));
      for (final point in points.skip(1)) {
        path.lineTo(_dx(point.x, size), _dy(point.y, size));
      }
      canvas.drawPath(path, paint);
    }
    final mark = pointer;
    if (mark == null) return;
    canvas.drawCircle(
      Offset(_dx(mark.x, size), _dy(mark.y, size)),
      math.max(12, shortSide * 0.02),
      Paint()..color = const Color(0xD9E53935),
    );
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) => true;

  double _dx(int value, Size size) => value / 65535 * size.width;
  double _dy(int value, Size size) => value / 65535 * size.height;
}

Color _color(ScreenShareAnnotationColor color) => switch (color) {
  ScreenShareAnnotationColor.red => const Color(0xD9E53935),
  ScreenShareAnnotationColor.amber => const Color(0xD9FFB300),
  ScreenShareAnnotationColor.green => const Color(0xD943A047),
  ScreenShareAnnotationColor.blue => const Color(0xD91E88E5),
};
