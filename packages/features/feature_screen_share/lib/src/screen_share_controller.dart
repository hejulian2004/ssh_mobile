import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart';

import 'screen_share_models.dart';
import 'screen_share_ports.dart';

/// Coordinates consent and platform-media readiness for one Realtime session.
///
/// The controller owns only business state. It never starts a capture source
/// for an incoming request until an explicit acceptance has been exchanged and
/// the App has reported matching native media readiness.
final class ScreenShareController extends ChangeNotifier {
  ScreenShareController({
    required ScreenShareConsentPort consentPort,
    required ScreenShareMediaPort mediaPort,
    required this.realtimeId,
    required this.generation,
    required this.localPeerId,
    required this.remotePeerId,
    DateTime Function()? now,
    Duration requestLifetime = const Duration(minutes: 2),
  }) : _consentPort = consentPort,
       _mediaPort = mediaPort,
       _now = now ?? DateTime.now,
       _requestLifetime = requestLifetime {
    _validateIdentity(realtimeId, 'realtimeId');
    _validateIdentity(localPeerId, 'localPeerId');
    _validateIdentity(remotePeerId, 'remotePeerId');
    if (generation <= 0) {
      throw ArgumentError.value(generation, 'generation');
    }
    if (requestLifetime <= Duration.zero ||
        requestLifetime > const Duration(minutes: 2)) {
      throw ArgumentError.value(requestLifetime, 'requestLifetime');
    }
    _consentSubscription = consentPort.consents.listen(_onConsent);
    _mediaSubscription = mediaPort.events.listen(_onMediaEvent);
  }

  final ScreenShareConsentPort _consentPort;
  final ScreenShareMediaPort _mediaPort;
  final DateTime Function() _now;
  final Duration _requestLifetime;
  late final StreamSubscription<RealtimeConsent> _consentSubscription;
  late final StreamSubscription<ScreenShareMediaEvent> _mediaSubscription;
  Timer? _expiryTimer;
  bool _disposed = false;
  bool _mediaStartInFlight = false;
  // Action revisions are monotonic per (operation_id, sender_peer_id), so a
  // local request/decision and a remote decision each have their own lane.
  int _nextLocalActionRevision = 0;
  int _lastRemoteActionRevision = 0;
  late ScreenShareOperationSnapshot _snapshot =
      ScreenShareOperationSnapshot.idle(
        realtimeId: realtimeId,
        generation: generation,
      );

  final String realtimeId;
  final int generation;
  final String localPeerId;
  final String remotePeerId;

  ScreenShareOperationSnapshot get snapshot => _snapshot;
  ScreenShareOperationState get state => _snapshot.state;
  String? get operationId => _snapshot.operationId;
  bool get mediaReady => _snapshot.mediaReady;

  /// Starts an outgoing request. A supplied operation ID is useful for a
  /// caller that persists the pending UI intent; otherwise one is generated
  /// locally without becoming a protocol identity outside this operation.
  Future<void> startOutgoing({String? operationId}) async {
    _ensureUsable();
    if (state != ScreenShareOperationState.idle) return;
    final id = operationId ?? _newOperationId();
    final issued = _now();
    final expires = issued.add(_requestLifetime);
    _nextLocalActionRevision = 1;
    _lastRemoteActionRevision = 0;
    _setSnapshot(
      ScreenShareOperationSnapshot(
        state: ScreenShareOperationState.outgoingPending,
        role: ScreenShareRole.sender,
        realtimeId: realtimeId,
        generation: generation,
        operationId: id,
        mediaReady: _snapshot.mediaReady,
        expiresAt: expires,
      ),
    );
    _armExpiry(expires);
    final result = await _send(
      buildScreenShareConsent(
        operationId: id,
        realtimeId: realtimeId,
        generation: generation,
        issuedAt: issued,
        expiresAt: expires,
        decision: RealtimeConsentDecision.request,
        senderPeerId: localPeerId,
        actionRevision: _nextLocalActionRevision,
      ),
    );
    if (!result && !_disposed) {
      _fail('Unable to send screen-share request.');
    }
  }

  Future<void> acceptIncoming() async {
    _ensureUsable();
    if (state != ScreenShareOperationState.incomingPending) return;
    final id = _snapshot.operationId;
    final expires = _snapshot.expiresAt;
    if (id == null || expires == null || !_now().isBefore(expires)) {
      _expire();
      return;
    }
    _nextLocalActionRevision++;
    final result = await _send(
      buildScreenShareConsent(
        operationId: id,
        realtimeId: realtimeId,
        generation: generation,
        issuedAt: _now(),
        expiresAt: expires,
        decision: RealtimeConsentDecision.accept,
        senderPeerId: localPeerId,
        actionRevision: _nextLocalActionRevision,
      ),
    );
    if (!result) {
      _fail('Unable to send screen-share acceptance.');
      return;
    }
    _setState(ScreenShareOperationState.accepted);
    await _startViewerIfReady();
  }

  Future<void> rejectIncoming() async {
    await _finishPending(
      RealtimeConsentDecision.reject,
      ScreenShareOperationState.rejected,
    );
  }

  Future<void> cancel() async {
    _ensureUsable();
    final current = state;
    if (current == ScreenShareOperationState.idle ||
        current == ScreenShareOperationState.cancelled ||
        current == ScreenShareOperationState.rejected ||
        current == ScreenShareOperationState.expired) {
      return;
    }
    final id = _snapshot.operationId;
    final expires = _snapshot.expiresAt;
    if (id != null && expires != null && _now().isBefore(expires)) {
      _nextLocalActionRevision++;
      await _send(
        buildScreenShareConsent(
          operationId: id,
          realtimeId: realtimeId,
          generation: generation,
          issuedAt: _now(),
          expiresAt: expires,
          decision: RealtimeConsentDecision.cancel,
          senderPeerId: localPeerId,
          actionRevision: _nextLocalActionRevision,
        ),
      );
    }
    if (!await _stopMediaIfActive()) return;
    _setState(ScreenShareOperationState.cancelled);
  }

  Future<void> stop() => cancel();

  /// Reports that the platform owner has created the matching native media
  /// capability. It is intentionally a boolean, not a handle or frame.
  Future<void> setMediaReady(bool ready) async {
    _ensureUsable();
    _setSnapshot(
      ScreenShareOperationSnapshot(
        state: state,
        role: _snapshot.role,
        realtimeId: realtimeId,
        generation: generation,
        operationId: _snapshot.operationId,
        mediaReady: ready,
        expiresAt: _snapshot.expiresAt,
        failure: _snapshot.failure,
      ),
    );
    if (!ready) {
      if (state == ScreenShareOperationState.active &&
          await _stopMediaIfActive()) {
        _setState(ScreenShareOperationState.accepted);
      }
      return;
    }
    if (state == ScreenShareOperationState.accepted) {
      if (_snapshot.role == ScreenShareRole.sender) {
        await _startCaptureIfReady();
      } else {
        await _startViewerIfReady();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _expiryTimer?.cancel();
    unawaited(_consentSubscription.cancel());
    unawaited(_mediaSubscription.cancel());
    if (state == ScreenShareOperationState.active) {
      final id = _snapshot.operationId;
      if (id != null) {
        unawaited(
          _mediaPort.stop(
            operationId: id,
            realtimeId: realtimeId,
            generation: generation,
          ),
        );
      }
    }
    super.dispose();
  }

  void _onConsent(RealtimeConsent consent) {
    if (_disposed ||
        consent.realtimeId != realtimeId ||
        consent.generation != generation ||
        consent.senderPeerId != remotePeerId ||
        consent.isExpired(_now())) {
      return;
    }
    final currentId = _snapshot.operationId;
    if (consent.decision == RealtimeConsentDecision.request) {
      if (state == ScreenShareOperationState.idle) {
        _lastRemoteActionRevision = consent.actionRevision;
        _setSnapshot(
          ScreenShareOperationSnapshot(
            state: ScreenShareOperationState.incomingPending,
            role: ScreenShareRole.receiver,
            realtimeId: realtimeId,
            generation: generation,
            operationId: consent.operationId,
            mediaReady: _snapshot.mediaReady,
            expiresAt: consent.expiresAt,
          ),
        );
        _armExpiry(consent.expiresAt);
      }
      return;
    }
    if (currentId == null || currentId != consent.operationId) return;
    if (consent.actionRevision <= _lastRemoteActionRevision) return;
    if (_lastRemoteActionRevision > 0 &&
        consent.actionRevision != _lastRemoteActionRevision + 1) {
      _fail('Screen-share consent action revision is not contiguous.');
      return;
    }
    _lastRemoteActionRevision = consent.actionRevision;
    switch (consent.decision) {
      case RealtimeConsentDecision.accept:
        if (state == ScreenShareOperationState.outgoingPending) {
          _setState(ScreenShareOperationState.accepted);
          unawaited(_startCaptureIfReady());
        }
      case RealtimeConsentDecision.reject:
        if (state == ScreenShareOperationState.outgoingPending ||
            state == ScreenShareOperationState.accepted) {
          unawaited(_stopMediaIfActive());
          _setState(ScreenShareOperationState.rejected);
        }
      case RealtimeConsentDecision.cancel:
        if (!snapshot.isTerminal) {
          unawaited(_stopMediaIfActive());
          _setState(ScreenShareOperationState.cancelled);
        }
      case RealtimeConsentDecision.request:
        break;
    }
  }

  void _onMediaEvent(ScreenShareMediaEvent event) {
    if (_disposed ||
        event.realtimeId != realtimeId ||
        event.generation != generation ||
        event.operationId != _snapshot.operationId) {
      return;
    }
    switch (event.kind) {
      case ScreenShareMediaEventKind.stopped:
        if (state == ScreenShareOperationState.active) {
          _setState(ScreenShareOperationState.accepted);
        }
      case ScreenShareMediaEventKind.sourceEnded:
      case ScreenShareMediaEventKind.encoderFailed:
      case ScreenShareMediaEventKind.decoderFailed:
      case ScreenShareMediaEventKind.surfaceReleased:
      case ScreenShareMediaEventKind.transportLost:
        _fail(event.message ?? 'Screen-share media stopped unexpectedly.');
    }
  }

  Future<bool> _send(RealtimeConsent consent) async {
    try {
      final result = await _consentPort.sendConsent(consent);
      return result is SdkSuccess<void>;
    } on Object {
      return false;
    }
  }

  Future<void> _finishPending(
    RealtimeConsentDecision decision,
    ScreenShareOperationState finalState,
  ) async {
    _ensureUsable();
    if (state != ScreenShareOperationState.incomingPending &&
        state != ScreenShareOperationState.outgoingPending) {
      return;
    }
    final id = _snapshot.operationId;
    final expires = _snapshot.expiresAt;
    if (id != null && expires != null && _now().isBefore(expires)) {
      _nextLocalActionRevision++;
      final sent = await _send(
        buildScreenShareConsent(
          operationId: id,
          realtimeId: realtimeId,
          generation: generation,
          issuedAt: _now(),
          expiresAt: expires,
          decision: decision,
          senderPeerId: localPeerId,
          actionRevision: _nextLocalActionRevision,
        ),
      );
      if (!sent) {
        _fail('Unable to send screen-share decision.');
        return;
      }
    }
    _setState(finalState);
  }

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
    _mediaStartInFlight = true;
    try {
      await _mediaPort.startCapture(
        operationId: id,
        realtimeId: realtimeId,
        generation: generation,
      );
      if (!_disposed && state == ScreenShareOperationState.accepted) {
        _setState(ScreenShareOperationState.active);
      }
    } on Object {
      _fail('Screen-share capture could not start.');
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
    _mediaStartInFlight = true;
    try {
      await _mediaPort.startViewer(
        operationId: id,
        realtimeId: realtimeId,
        generation: generation,
      );
      if (!_disposed && state == ScreenShareOperationState.accepted) {
        _setState(ScreenShareOperationState.active);
      }
    } on Object {
      _fail('Screen-share viewer could not start.');
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

  void _armExpiry(DateTime expiresAt) {
    _expiryTimer?.cancel();
    final delay = expiresAt.difference(_now());
    if (delay <= Duration.zero) {
      _expire();
      return;
    }
    _expiryTimer = Timer(delay, _expire);
  }

  void _expire() {
    if (_disposed || snapshot.isTerminal || snapshot.operationId == null) {
      return;
    }
    unawaited(_stopMediaIfActive());
    _setState(ScreenShareOperationState.expired);
  }

  void _fail(String message) {
    if (_disposed || state == ScreenShareOperationState.failed) return;
    _expiryTimer?.cancel();
    _setSnapshot(
      ScreenShareOperationSnapshot(
        state: ScreenShareOperationState.failed,
        role: _snapshot.role,
        realtimeId: realtimeId,
        generation: generation,
        operationId: _snapshot.operationId,
        mediaReady: false,
        expiresAt: _snapshot.expiresAt,
        failure: message,
      ),
    );
  }

  void _setState(ScreenShareOperationState next) {
    _setSnapshot(
      ScreenShareOperationSnapshot(
        state: next,
        role: _snapshot.role,
        realtimeId: realtimeId,
        generation: generation,
        operationId: _snapshot.operationId,
        mediaReady: _snapshot.mediaReady,
        expiresAt: _snapshot.expiresAt,
        failure: _snapshot.failure,
      ),
    );
  }

  void _setSnapshot(ScreenShareOperationSnapshot next) {
    _snapshot = next;
    notifyListeners();
  }

  String _newOperationId() =>
      '${_now().microsecondsSinceEpoch.toRadixString(16)}-${localPeerId.hashCode.toRadixString(16)}';

  void _ensureUsable() {
    if (_disposed) throw StateError('Screen-share controller is disposed.');
  }

  static void _validateIdentity(String value, String name) {
    if (value.trim().isEmpty || value.length > 128) {
      throw ArgumentError.value(value, name);
    }
  }
}
