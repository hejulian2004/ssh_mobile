import 'dart:convert';
import 'dart:typed_data';

/// Capture-frame coordinate. 65535 is the far edge of the frame.
final class ScreenShareAnnotationPoint {
  const ScreenShareAnnotationPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is ScreenShareAnnotationPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

enum ScreenShareAnnotationColor { red, amber, green, blue }

enum ScreenShareAnnotationTool { pen, laser }

const annotationSchemaVersion = 1;
const maxAnnotationMessageBytes = 4096;
const maxAnnotationOperationIdBytes = 64;
const maxAnnotationPointsPerMessage = 24;
const maxAnnotationStrokes = 48;
const defaultAnnotationWidth = 24;

/// Stroke width is thousandths of the capture frame's short side.
double annotationStrokeWidth({
  required int width,
  required double frameShortSide,
}) {
  if (frameShortSide <= 0) return 0;
  final unit = width.clamp(4, 80);
  return frameShortSide * unit / 1000;
}

/// Maps a point in the view back to the unrotated capture frame.
///
/// [quarterTurns] is the receiver-only clockwise rotation. Zero means the
/// point is already in capture-frame space.
ScreenShareAnnotationPoint? mapViewPointToFrame({
  required double dx,
  required double dy,
  required double viewWidth,
  required double viewHeight,
  int quarterTurns = 0,
}) {
  if (viewWidth <= 0 ||
      viewHeight <= 0 ||
      dx < 0 ||
      dy < 0 ||
      dx > viewWidth ||
      dy > viewHeight) {
    return null;
  }
  var nx = dx / viewWidth;
  var ny = dy / viewHeight;
  switch (quarterTurns & 3) {
    case 1:
      final sx = ny;
      final sy = 1 - nx;
      nx = sx;
      ny = sy;
    case 2:
      nx = 1 - nx;
      ny = 1 - ny;
    case 3:
      final sx = 1 - ny;
      final sy = nx;
      nx = sx;
      ny = sy;
  }
  return ScreenShareAnnotationPoint(
    (nx * 65535).round().clamp(0, 65535),
    (ny * 65535).round().clamp(0, 65535),
  );
}

sealed class ScreenShareAnnotationMessage {
  const ScreenShareAnnotationMessage({
    required this.sequence,
    required this.generation,
    required this.operationId,
  });

  final int sequence;
  final int generation;
  final String operationId;
}

final class AnnotationStrokeBegin extends ScreenShareAnnotationMessage {
  const AnnotationStrokeBegin({
    required super.sequence,
    required super.generation,
    required super.operationId,
    required this.strokeId,
    required this.color,
    required this.width,
  });

  final int strokeId;
  final ScreenShareAnnotationColor color;
  final int width;
}

final class AnnotationStrokePoints extends ScreenShareAnnotationMessage {
  const AnnotationStrokePoints({
    required super.sequence,
    required super.generation,
    required super.operationId,
    required this.strokeId,
    required this.points,
  });

  final int strokeId;
  final List<ScreenShareAnnotationPoint> points;
}

final class AnnotationStrokeEnd extends ScreenShareAnnotationMessage {
  const AnnotationStrokeEnd({
    required super.sequence,
    required super.generation,
    required super.operationId,
    required this.strokeId,
  });

  final int strokeId;
}

final class AnnotationUndo extends ScreenShareAnnotationMessage {
  const AnnotationUndo({
    required super.sequence,
    required super.generation,
    required super.operationId,
    required this.strokeId,
  });

  final int strokeId;
}

final class AnnotationClear extends ScreenShareAnnotationMessage {
  const AnnotationClear({
    required super.sequence,
    required super.generation,
    required super.operationId,
  });
}

final class AnnotationPointer extends ScreenShareAnnotationMessage {
  const AnnotationPointer({
    required super.sequence,
    required super.generation,
    required super.operationId,
    required this.visible,
    this.point,
  });

  final bool visible;
  final ScreenShareAnnotationPoint? point;
}

final class AnnotationRetire extends ScreenShareAnnotationMessage {
  const AnnotationRetire({
    required super.sequence,
    required super.generation,
    required super.operationId,
    required this.strokeId,
  });

  final int strokeId;
}

final class AnnotationDisplayReady extends ScreenShareAnnotationMessage {
  const AnnotationDisplayReady({
    required super.sequence,
    required super.generation,
    required super.operationId,
    required this.ready,
  });

  final bool ready;
}

/// Versioned annotation payload. Unknown versions decode as null.
abstract final class ScreenShareAnnotationCodec {
  static Uint8List encode(ScreenShareAnnotationMessage message) {
    final operation = utf8.encode(message.operationId);
    if (operation.isEmpty || operation.length > maxAnnotationOperationIdBytes) {
      throw ArgumentError.value(
        message.operationId,
        'operationId',
        'Operation id must contain 1-64 UTF-8 bytes.',
      );
    }
    final body = BytesBuilder(copy: false)
      ..addByte(annotationSchemaVersion)
      ..addByte(_kind(message))
      ..add(_u32(message.sequence))
      ..add(_u64(message.generation))
      ..addByte(operation.length)
      ..add(operation)
      ..add(_body(message));
    final bytes = body.toBytes();
    if (bytes.length > maxAnnotationMessageBytes) {
      throw ArgumentError('Annotation message exceeds 4096 bytes.');
    }
    return bytes;
  }

  static ScreenShareAnnotationMessage? decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxAnnotationMessageBytes) return null;
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    if (data.getUint8(offset) != annotationSchemaVersion) return null;
    offset += 1;
    final kind = data.getUint8(offset);
    offset += 1;
    if (offset + 4 + 8 + 1 > bytes.length) return null;
    final sequence = data.getUint32(offset);
    offset += 4;
    final generation = data.getUint64(offset);
    offset += 8;
    final operationLength = data.getUint8(offset);
    offset += 1;
    if (operationLength == 0 ||
        operationLength > maxAnnotationOperationIdBytes ||
        offset + operationLength > bytes.length) {
      return null;
    }
    final operationId = utf8.decode(
      bytes.sublist(offset, offset + operationLength),
      allowMalformed: false,
    );
    offset += operationLength;
    if (sequence == 0 || generation == 0) return null;
    return _decodeBody(
      kind,
      bytes,
      data,
      offset,
      sequence: sequence,
      generation: generation,
      operationId: operationId,
    );
  }
}

int _kind(ScreenShareAnnotationMessage message) => switch (message) {
  AnnotationStrokeBegin() => 1,
  AnnotationStrokePoints() => 2,
  AnnotationStrokeEnd() => 3,
  AnnotationUndo() => 4,
  AnnotationClear() => 5,
  AnnotationPointer() => 6,
  AnnotationRetire() => 7,
  AnnotationDisplayReady() => 8,
};

Uint8List _body(ScreenShareAnnotationMessage message) => switch (message) {
  AnnotationStrokeBegin(:final strokeId, :final color, :final width) =>
    (BytesBuilder(copy: false)
          ..add(_u32(strokeId))
          ..addByte(color.index + 1)
          ..add(_u16(width)))
        .toBytes(),
  AnnotationStrokePoints(:final strokeId, :final points) =>
    (BytesBuilder(copy: false)
          ..add(_u32(strokeId))
          ..addByte(points.length)
          ..add(
            points
                .expand((point) => <int>[..._u16(point.x), ..._u16(point.y)])
                .toList(growable: false),
          ))
        .toBytes(),
  AnnotationStrokeEnd(:final strokeId) => _u32(strokeId),
  AnnotationUndo(:final strokeId) => _u32(strokeId),
  AnnotationClear() => Uint8List(0),
  AnnotationPointer(:final visible, :final point) =>
    (BytesBuilder(copy: false)
          ..addByte(visible ? 1 : 0)
          ..add(_u16(point?.x ?? 0))
          ..add(_u16(point?.y ?? 0)))
        .toBytes(),
  AnnotationRetire(:final strokeId) => _u32(strokeId),
  AnnotationDisplayReady(:final ready) => Uint8List.fromList(<int>[
    ready ? 1 : 0,
  ]),
};

ScreenShareAnnotationMessage? _decodeBody(
  int kind,
  Uint8List bytes,
  ByteData data,
  int offset, {
  required int sequence,
  required int generation,
  required String operationId,
}) {
  int need(int size) => offset + size <= bytes.length ? size : -1;
  switch (kind) {
    case 1:
      if (need(7) < 0) return null;
      final color = data.getUint8(offset + 4);
      if (color < 1 || color > ScreenShareAnnotationColor.values.length) {
        return null;
      }
      return AnnotationStrokeBegin(
        sequence: sequence,
        generation: generation,
        operationId: operationId,
        strokeId: data.getUint32(offset),
        color: ScreenShareAnnotationColor.values[color - 1],
        width: data.getUint16(offset + 5),
      );
    case 2:
      if (need(5) < 0) return null;
      final count = data.getUint8(offset + 4);
      if (count == 0 || count > maxAnnotationPointsPerMessage) return null;
      if (need(5 + count * 4) < 0) return null;
      final points = <ScreenShareAnnotationPoint>[
        for (var i = 0; i < count; i++)
          ScreenShareAnnotationPoint(
            data.getUint16(offset + 5 + i * 4),
            data.getUint16(offset + 7 + i * 4),
          ),
      ];
      return AnnotationStrokePoints(
        sequence: sequence,
        generation: generation,
        operationId: operationId,
        strokeId: data.getUint32(offset),
        points: points,
      );
    case 3:
      if (need(4) < 0) return null;
      return AnnotationStrokeEnd(
        sequence: sequence,
        generation: generation,
        operationId: operationId,
        strokeId: data.getUint32(offset),
      );
    case 4:
      if (need(4) < 0) return null;
      return AnnotationUndo(
        sequence: sequence,
        generation: generation,
        operationId: operationId,
        strokeId: data.getUint32(offset),
      );
    case 5:
      return AnnotationClear(
        sequence: sequence,
        generation: generation,
        operationId: operationId,
      );
    case 6:
      if (need(5) < 0) return null;
      final visible = data.getUint8(offset) != 0;
      return AnnotationPointer(
        sequence: sequence,
        generation: generation,
        operationId: operationId,
        visible: visible,
        point: visible
            ? ScreenShareAnnotationPoint(
                data.getUint16(offset + 1),
                data.getUint16(offset + 3),
              )
            : null,
      );
    case 7:
      if (need(4) < 0) return null;
      return AnnotationRetire(
        sequence: sequence,
        generation: generation,
        operationId: operationId,
        strokeId: data.getUint32(offset),
      );
    case 8:
      if (need(1) < 0) return null;
      return AnnotationDisplayReady(
        sequence: sequence,
        generation: generation,
        operationId: operationId,
        ready: data.getUint8(offset) != 0,
      );
    default:
      return null;
  }
}

ScreenShareAnnotationMessage annotationMessageWithSequence(
  ScreenShareAnnotationMessage message,
  int sequence,
) => switch (message) {
  AnnotationStrokeBegin() => AnnotationStrokeBegin(
    sequence: sequence,
    generation: message.generation,
    operationId: message.operationId,
    strokeId: message.strokeId,
    color: message.color,
    width: message.width,
  ),
  AnnotationStrokePoints() => AnnotationStrokePoints(
    sequence: sequence,
    generation: message.generation,
    operationId: message.operationId,
    strokeId: message.strokeId,
    points: message.points,
  ),
  AnnotationStrokeEnd() => AnnotationStrokeEnd(
    sequence: sequence,
    generation: message.generation,
    operationId: message.operationId,
    strokeId: message.strokeId,
  ),
  AnnotationUndo() => AnnotationUndo(
    sequence: sequence,
    generation: message.generation,
    operationId: message.operationId,
    strokeId: message.strokeId,
  ),
  AnnotationClear() => AnnotationClear(
    sequence: sequence,
    generation: message.generation,
    operationId: message.operationId,
  ),
  AnnotationPointer() => AnnotationPointer(
    sequence: sequence,
    generation: message.generation,
    operationId: message.operationId,
    visible: message.visible,
    point: message.point,
  ),
  AnnotationRetire() => AnnotationRetire(
    sequence: sequence,
    generation: message.generation,
    operationId: message.operationId,
    strokeId: message.strokeId,
  ),
  AnnotationDisplayReady() => AnnotationDisplayReady(
    sequence: sequence,
    generation: message.generation,
    operationId: message.operationId,
    ready: message.ready,
  ),
};

Uint8List _u16(int value) {
  final data = ByteData(2)..setUint16(0, value);
  return data.buffer.asUint8List();
}

Uint8List _u32(int value) {
  final data = ByteData(4)..setUint32(0, value);
  return data.buffer.asUint8List();
}

Uint8List _u64(int value) {
  final data = ByteData(8)..setUint64(0, value);
  return data.buffer.asUint8List();
}
