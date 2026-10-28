import 'dart:async';

import 'package:flutter/foundation.dart';

import 'screen_share_annotation_codec.dart';

/// Sends and receives opaque annotation bytes for one screen-share generation.
abstract interface class ScreenShareAnnotationTransport {
  bool get channelOpen;
  Stream<bool> get channelEvents;
  Stream<Uint8List> get incoming;
  Future<void> send(Uint8List bytes);
}

/// One completed or in-progress mark in capture-frame coordinates.
final class ScreenShareAnnotationStroke {
  ScreenShareAnnotationStroke({
    required this.id,
    required this.color,
    required this.width,
    required this.points,
    required this.complete,
  });

  final int id;
  final ScreenShareAnnotationColor color;
  final int width;
  final List<ScreenShareAnnotationPoint> points;
  final bool complete;
}

/// Receiver drawing and sender display state for one share operation.
///
/// The session does not know about WebRTC. A closed channel refuses new
/// marks. A peer that cannot show marks still accepts local drawing.
final class ScreenShareAnnotationSession extends ChangeNotifier {
  ScreenShareAnnotationSession({
    required this.operationId,
    required this.generation,
    required ScreenShareAnnotationTransport transport,
    this.canDraw = true,
    DateTime Function()? clock,
    this.schedule,
  }) : _transport = transport,
       _clock = clock ?? DateTime.now;

  final String operationId;
  final int generation;
  final bool canDraw;
  final void Function(Duration delay, void Function() callback)? schedule;
  final ScreenShareAnnotationTransport _transport;
  final DateTime Function() _clock;
  final List<ScreenShareAnnotationStroke> _strokes = [];
  final List<ScreenShareAnnotationPoint> _pending = [];
  StreamSubscription<bool>? _channelSubscription;
  StreamSubscription<Uint8List>? _incomingSubscription;
  ScreenShareAnnotationStroke? _active;
  ScreenShareAnnotationPoint? _pointer;
  bool _channelOpen = false;
  bool? _remoteDisplayReady;
  bool _disposed = false;
  int _sequence = 0;
  int _inboundSequence = 0;
  int _nextStrokeId = 1;
  int _pointerEpoch = 0;
  DateTime? _lastFlush;
  DateTime? _lastPointerSend;
  Timer? _pointerTimer;
  bool _pointerArmed = false;
  ScreenShareAnnotationPoint? _pendingPointer;

  bool get channelOpen => _channelOpen;
  bool? get remoteDisplayReady => _remoteDisplayReady;
  ScreenShareAnnotationPoint? get pointer => _pointer;
  List<ScreenShareAnnotationStroke> get strokes => List.unmodifiable(_strokes);

  bool get canPaint => canDraw && _channelOpen && !_disposed;

  void start() {
    if (_channelSubscription != null || _disposed) return;
    _channelOpen = _transport.channelOpen;
    _channelSubscription = _transport.channelEvents.listen((open) {
      _channelOpen = open;
      if (!open) _clearLocal();
      _notify();
    });
    _incomingSubscription = _transport.incoming.listen(_ingest);
    if (_channelOpen) _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelPointerSend();
    unawaited(_channelSubscription?.cancel() ?? Future<void>.value());
    unawaited(_incomingSubscription?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  /// Drops every mark and tells a peer that can still receive.
  void releaseMarks() {
    if (_disposed) return;
    final notifyPeer =
        _channelOpen && (_strokes.isNotEmpty || _pointer != null);
    _clearLocal();
    if (notifyPeer) {
      _send(
        AnnotationClear(
          sequence: 0,
          generation: generation,
          operationId: operationId,
        ),
      );
    }
    _notify();
  }

  bool beginStroke(
    ScreenShareAnnotationPoint point, {
    ScreenShareAnnotationColor color = ScreenShareAnnotationColor.red,
    int width = defaultAnnotationWidth,
  }) {
    if (!canPaint || _active != null) return false;
    final retired = _makeRoom();
    final stroke = ScreenShareAnnotationStroke(
      id: _nextStrokeId++,
      color: color,
      width: width.clamp(4, 80),
      points: [point],
      complete: false,
    );
    _active = stroke;
    _strokes.add(stroke);
    for (final message in retired) {
      _send(message);
    }
    _send(
      AnnotationStrokeBegin(
        sequence: 0,
        generation: generation,
        operationId: operationId,
        strokeId: stroke.id,
        color: stroke.color,
        width: stroke.width,
      ),
    );
    _pending
      ..clear()
      ..add(point);
    _flushPoints(force: true);
    _notify();
    return true;
  }

  bool extendStroke(ScreenShareAnnotationPoint point) {
    final stroke = _active;
    if (!canPaint || stroke == null) return false;
    stroke.points.add(point);
    _pending.add(point);
    final now = _clock();
    final due =
        _lastFlush == null ||
        now.difference(_lastFlush!) >= const Duration(milliseconds: 33) ||
        _pending.length >= maxAnnotationPointsPerMessage;
    if (due) _flushPoints(force: true);
    _notify();
    return true;
  }

  bool endStroke() {
    final stroke = _active;
    if (!canPaint || stroke == null) return false;
    _flushPoints(force: true);
    _replace(stroke, complete: true);
    _active = null;
    _send(
      AnnotationStrokeEnd(
        sequence: 0,
        generation: generation,
        operationId: operationId,
        strokeId: stroke.id,
      ),
    );
    _notify();
    return true;
  }

  bool showPointer(ScreenShareAnnotationPoint point) {
    if (!canPaint) return false;
    _pointer = point;
    _pendingPointer = point;
    _notify();
    _queuePointer();
    return true;
  }

  bool hidePointer() {
    if (!canPaint || _pointer == null) return false;
    _pointer = null;
    _cancelPointerSend();
    _send(
      AnnotationPointer(
        sequence: 0,
        generation: generation,
        operationId: operationId,
        visible: false,
      ),
    );
    _notify();
    return true;
  }

  bool undo() {
    if (!canPaint) return false;
    if (_active != null) {
      final id = _active!.id;
      _strokes.removeWhere((stroke) => stroke.id == id);
      _active = null;
      _pending.clear();
      _send(
        AnnotationRetire(
          sequence: 0,
          generation: generation,
          operationId: operationId,
          strokeId: id,
        ),
      );
      _notify();
      return true;
    }
    if (_strokes.isEmpty) return false;
    final id = _strokes.last.id;
    _strokes.removeLast();
    _send(
      AnnotationUndo(
        sequence: 0,
        generation: generation,
        operationId: operationId,
        strokeId: id,
      ),
    );
    _notify();
    return true;
  }

  bool clear() {
    if (!canPaint || (_strokes.isEmpty && _pointer == null)) return false;
    _clearLocal();
    _send(
      AnnotationClear(
        sequence: 0,
        generation: generation,
        operationId: operationId,
      ),
    );
    _notify();
    return true;
  }

  void publishDisplayReady(bool ready) {
    if (!_channelOpen || _disposed || canDraw) return;
    _send(
      AnnotationDisplayReady(
        sequence: 0,
        generation: generation,
        operationId: operationId,
        ready: ready,
      ),
    );
  }

  void _ingest(Uint8List bytes) {
    final message = ScreenShareAnnotationCodec.decode(bytes);
    if (message == null ||
        message.operationId != operationId ||
        message.generation != generation ||
        message.sequence <= _inboundSequence) {
      return;
    }
    _inboundSequence = message.sequence;
    switch (message) {
      case AnnotationStrokeBegin():
        if (_strokes.any((stroke) => stroke.id == message.strokeId)) return;
        _strokes.add(
          ScreenShareAnnotationStroke(
            id: message.strokeId,
            color: message.color,
            width: message.width.clamp(4, 80),
            points: <ScreenShareAnnotationPoint>[],
            complete: false,
          ),
        );
      case AnnotationStrokePoints():
        final stroke = _find(message.strokeId);
        stroke?.points.addAll(message.points);
      case AnnotationStrokeEnd():
        final stroke = _find(message.strokeId);
        if (stroke != null) _replace(stroke, complete: true);
      case AnnotationUndo(:final strokeId) || AnnotationRetire(:final strokeId):
        _strokes.removeWhere((stroke) => stroke.id == strokeId);
        if (_active?.id == strokeId) _active = null;
      case AnnotationClear():
        _clearLocal();
      case AnnotationPointer():
        _pointer = message.visible ? message.point : null;
      case AnnotationDisplayReady():
        _remoteDisplayReady = message.ready;
    }
    while (_strokes.length > maxAnnotationStrokes) {
      _strokes.removeAt(0);
    }
    _notify();
  }

  List<ScreenShareAnnotationMessage> _makeRoom() {
    final retired = <ScreenShareAnnotationMessage>[];
    while (_strokes.length >= maxAnnotationStrokes) {
      final oldest = _strokes.firstWhere((stroke) => stroke.complete);
      _strokes.remove(oldest);
      retired.add(
        AnnotationRetire(
          sequence: 0,
          generation: generation,
          operationId: operationId,
          strokeId: oldest.id,
        ),
      );
    }
    return retired;
  }

  void _flushPoints({required bool force}) {
    if (_pending.isEmpty) return;
    final stroke = _active;
    if (stroke == null) {
      _pending.clear();
      return;
    }
    if (!force && _pending.length < maxAnnotationPointsPerMessage) return;
    final batch = List<ScreenShareAnnotationPoint>.of(
      _pending.take(maxAnnotationPointsPerMessage),
    );
    _pending.removeRange(0, batch.length);
    _lastFlush = _clock();
    _send(
      AnnotationStrokePoints(
        sequence: 0,
        generation: generation,
        operationId: operationId,
        strokeId: stroke.id,
        points: batch,
      ),
    );
    if (_pending.isNotEmpty) _flushPoints(force: true);
  }

  void _send(ScreenShareAnnotationMessage message) {
    final sequenced = annotationMessageWithSequence(message, ++_sequence);
    final bytes = ScreenShareAnnotationCodec.encode(sequenced);
    unawaited(
      _transport.send(bytes).catchError((Object _) {
        if (_disposed) return;
        _channelOpen = false;
        _clearLocal();
        _notify();
      }),
    );
  }

  void _queuePointer() {
    final now = _clock();
    final last = _lastPointerSend;
    if (last == null ||
        now.difference(last) >= const Duration(milliseconds: 33)) {
      _emitPointer();
      return;
    }
    if (_pointerArmed) return;
    final wait = const Duration(milliseconds: 33) - now.difference(last);
    final epoch = _pointerEpoch;
    void fire() {
      if (epoch != _pointerEpoch || _disposed) return;
      _pointerArmed = false;
      _pointerTimer = null;
      _emitPointer();
    }

    _pointerArmed = true;
    final custom = schedule;
    if (custom != null) {
      custom(wait, fire);
    } else {
      _pointerTimer = Timer(wait, fire);
    }
  }

  void _emitPointer() {
    final point = _pendingPointer;
    if (point == null || !canPaint) return;
    _pendingPointer = null;
    _pointerArmed = false;
    _lastPointerSend = _clock();
    _send(
      AnnotationPointer(
        sequence: 0,
        generation: generation,
        operationId: operationId,
        visible: true,
        point: point,
      ),
    );
  }

  void _cancelPointerSend() {
    _pointerEpoch++;
    _pointerArmed = false;
    _pointerTimer?.cancel();
    _pointerTimer = null;
    _pendingPointer = null;
  }

  ScreenShareAnnotationStroke? _find(int id) {
    for (final stroke in _strokes) {
      if (stroke.id == id) return stroke;
    }
    return null;
  }

  void _replace(ScreenShareAnnotationStroke stroke, {required bool complete}) {
    final index = _strokes.indexWhere((candidate) => candidate.id == stroke.id);
    if (index < 0) return;
    _strokes[index] = ScreenShareAnnotationStroke(
      id: stroke.id,
      color: stroke.color,
      width: stroke.width,
      points: stroke.points,
      complete: complete,
    );
    if (_active?.id == stroke.id && complete) _active = null;
  }

  void _clearLocal() {
    _cancelPointerSend();
    _strokes.clear();
    _active = null;
    _pending.clear();
    _pointer = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
