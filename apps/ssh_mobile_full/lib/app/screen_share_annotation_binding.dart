import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart';

/// One path snapshot for the sender overlay. It carries no media frames.
final class ScreenShareGuidanceFrame {
  const ScreenShareGuidanceFrame({
    required this.width,
    required this.height,
    required this.strokes,
    required this.pointer,
  });

  final int width;
  final int height;
  final List<ScreenShareAnnotationStroke> strokes;
  final ScreenShareAnnotationPoint? pointer;
}

/// Shows capture-frame marks above other apps. Denial returns false.
abstract interface class ScreenShareGuidanceDisplay {
  Future<bool> present(ScreenShareGuidanceFrame frame);
  Future<void> hide();
}

/// Adapts a Realtime session's opaque application channel to annotation bytes.
final class RealtimeAnnotationTransport
    implements ScreenShareAnnotationTransport {
  RealtimeAnnotationTransport(this._session);

  final RealtimeSession _session;

  @override
  bool get channelOpen => _session.applicationChannelOpen;

  @override
  Stream<bool> get channelEvents => _session.applicationChannelEvents;

  @override
  Stream<Uint8List> get incoming => _session.applicationData;

  @override
  Future<void> send(Uint8List bytes) async {
    final result = await _session.sendApplicationData(bytes);
    if (result is SdkFailure<void>) {
      throw StateError(result.error.message);
    }
  }
}

/// Keeps annotation state with the screen-share operation, not the page.
final class AppScreenShareAnnotationBinding {
  AppScreenShareAnnotationBinding({
    required RealtimeSession realtime,
    required Listenable operation,
    required ScreenShareOperationSnapshot Function() snapshot,
    required ValueListenable<Size?> frameSize,
    required this.onChanged,
    ScreenShareGuidanceDisplay? overlay,
  }) : _realtime = realtime,
       _operation = operation,
       _snapshot = snapshot,
       _frameSize = frameSize,
       _overlay = overlay;

  final RealtimeSession _realtime;
  final Listenable _operation;
  final ScreenShareOperationSnapshot Function() _snapshot;
  final ValueListenable<Size?> _frameSize;
  final ScreenShareGuidanceDisplay? _overlay;
  final void Function() onChanged;
  ScreenShareAnnotationSession? _session;
  Size? _frame;
  bool _disposed = false;
  bool? _publishedReady;
  Future<void> _overlayUpdate = Future<void>.value();

  ScreenShareAnnotationSession? get session => _session;

  bool get interactive =>
      _session != null &&
      _session!.canDraw &&
      _snapshot().state == ScreenShareOperationState.active;

  void start() {
    _operation.addListener(_sync);
    _frameSize.addListener(_onFrame);
    _onFrame();
    _sync();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _operation.removeListener(_sync);
    _frameSize.removeListener(_onFrame);
    final current = _session;
    _session = null;
    current?.removeListener(_onSession);
    current?.releaseMarks();
    current?.dispose();
    _publishedReady = null;
    final overlay = _overlay;
    if (overlay != null) unawaited(overlay.hide());
  }

  void _sync() {
    if (_disposed) return;
    final snap = _snapshot();
    if (snap.operationId == null || snap.isTerminal) {
      _endSession();
      onChanged();
      return;
    }
    final operationId = snap.operationId!;
    final existing = _session;
    if (existing != null &&
        (existing.operationId != operationId ||
            existing.generation != snap.generation)) {
      _endSession();
    }
    _session ??= _openSession(operationId, snap.generation, snap.role);
    if (snap.state == ScreenShareOperationState.active) _scheduleOverlay();
    onChanged();
  }

  ScreenShareAnnotationSession _openSession(
    String operationId,
    int generation,
    ScreenShareRole? role,
  ) {
    final session = ScreenShareAnnotationSession(
      operationId: operationId,
      generation: generation,
      transport: RealtimeAnnotationTransport(_realtime),
      canDraw: role == ScreenShareRole.receiver,
    );
    session.start();
    session.addListener(_onSession);
    return session;
  }

  void _endSession() {
    final current = _session;
    if (current == null) {
      _hideOverlay();
      return;
    }
    _session = null;
    current.removeListener(_onSession);
    current.releaseMarks();
    current.dispose();
    _publishedReady = null;
    _hideOverlay();
  }

  void _onFrame() {
    if (_disposed) return;
    final size = _frameSize.value;
    if (size == null ||
        !size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return;
    }
    final previous = _frame;
    _frame = size;
    if (previous != null &&
        (previous.width != size.width || previous.height != size.height)) {
      _session?.releaseMarks();
    }
    _scheduleOverlay();
  }

  void _onSession() {
    if (_disposed) return;
    _scheduleOverlay();
    onChanged();
  }

  void _scheduleOverlay() {
    final overlay = _overlay;
    final current = _session;
    final size = _frame;
    if (overlay == null ||
        current == null ||
        current.canDraw ||
        size == null ||
        _snapshot().state != ScreenShareOperationState.active) {
      return;
    }
    final frame = ScreenShareGuidanceFrame(
      width: size.width.round(),
      height: size.height.round(),
      strokes: current.strokes,
      pointer: current.pointer,
    );
    _overlayUpdate = _overlayUpdate.then((_) async {
      if (_disposed || !identical(_session, current)) return;
      final ready = await overlay.present(frame);
      if (_disposed || !identical(_session, current)) {
        if (ready) await overlay.hide();
        return;
      }
      if (ready != _publishedReady) {
        _publishedReady = ready;
        current.publishDisplayReady(ready);
      }
    });
  }

  void _hideOverlay() {
    final overlay = _overlay;
    if (overlay == null) return;
    _overlayUpdate = _overlayUpdate.then((_) => overlay.hide());
  }
}
