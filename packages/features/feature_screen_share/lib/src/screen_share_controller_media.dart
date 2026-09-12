part of 'screen_share_controller.dart';

mixin _ScreenShareMediaLifecycle {
  bool get _mediaStartInFlight;

  set _mediaStartInFlight(bool value);

  bool get _disposed;

  ScreenShareOperationState get state;

  ScreenShareOperationSnapshot get _snapshot;

  int get _operationEpoch;

  ScreenShareMediaPort get _mediaPort;

  String get realtimeId;

  int get generation;

  bool _isCurrent(
    int epoch,
    String? operationId, {
    ScreenShareOperationState? expectedState,
    bool requireMediaReady = false,
  });

  void _setState(ScreenShareOperationState next);

  void _fail(String message);

  Future<void> _startCaptureIfReady() async {
    if (_mediaStartInFlight ||
        _disposed ||
        state != ScreenShareOperationState.accepted ||
        _snapshot.role != ScreenShareRole.sender ||
        !_snapshot.mediaReady) {
      return;
    }
    final id = _snapshot.operationId;
    if (id == null) return;
    final epoch = _operationEpoch;
    _mediaStartInFlight = true;
    try {
      await _mediaPort.startCapture(
        operationId: id,
        realtimeId: realtimeId,
        generation: generation,
      );
      if (!_isCurrent(
        epoch,
        id,
        expectedState: ScreenShareOperationState.accepted,
        requireMediaReady: true,
      )) {
        await _compensateMediaStart(id);
        return;
      }
      if (_isCurrent(
        epoch,
        id,
        expectedState: ScreenShareOperationState.accepted,
        requireMediaReady: true,
      )) {
        _setState(ScreenShareOperationState.active);
      }
    } on Object {
      await _compensateMediaStart(id);
      if (_isCurrent(epoch, id)) {
        _fail('Screen-share capture could not start.');
      }
    } finally {
      _mediaStartInFlight = false;
    }
  }

  Future<void> _startViewerIfReady() async {
    if (_mediaStartInFlight ||
        _disposed ||
        state != ScreenShareOperationState.accepted ||
        _snapshot.role != ScreenShareRole.receiver ||
        !_snapshot.mediaReady) {
      return;
    }
    final id = _snapshot.operationId;
    if (id == null) return;
    final epoch = _operationEpoch;
    _mediaStartInFlight = true;
    try {
      await _mediaPort.startViewer(
        operationId: id,
        realtimeId: realtimeId,
        generation: generation,
      );
      if (!_isCurrent(
        epoch,
        id,
        expectedState: ScreenShareOperationState.accepted,
        requireMediaReady: true,
      )) {
        await _compensateMediaStart(id);
        return;
      }
      if (_isCurrent(
        epoch,
        id,
        expectedState: ScreenShareOperationState.accepted,
        requireMediaReady: true,
      )) {
        _setState(ScreenShareOperationState.active);
      }
    } on Object {
      await _compensateMediaStart(id);
      if (_isCurrent(epoch, id)) {
        _fail('Screen-share viewer could not start.');
      }
    } finally {
      _mediaStartInFlight = false;
    }
  }

  Future<bool> _stopMediaIfActive() async {
    final id = _snapshot.operationId;
    if (id == null || state != ScreenShareOperationState.active) return true;
    try {
      await _mediaPort.stop(
        operationId: id,
        realtimeId: realtimeId,
        generation: generation,
      );
      return true;
    } on Object {
      _fail('Screen-share media cleanup failed.');
      return false;
    }
  }

  Future<void> _compensateMediaStart(String id) async {
    try {
      await _mediaPort.stop(
        operationId: id,
        realtimeId: realtimeId,
        generation: generation,
      );
    } on Object {
      // The native owner remains retryable; never resurrect a stale Feature
      // state merely because compensating cleanup failed.
    }
  }
}
