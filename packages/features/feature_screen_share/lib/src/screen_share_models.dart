import 'package:network_sdk/network_sdk.dart';

/// Business lifecycle for one consent operation.
enum ScreenShareOperationState {
  idle,
  outgoingPending,
  incomingPending,
  accepted,
  active,
  rejected,
  cancelled,
  expired,
  failed,
}

/// Whether this device requested the share or receives it.
enum ScreenShareRole { sender, receiver }

/// Pure source metadata exposed to Feature UI.
///
/// The id is an App-issued, route-scoped selection token. It is deliberately
/// not a native window handle or a platform source id.
enum ScreenShareSourceKind { display, window }

final class ScreenShareSourceOption {
  const ScreenShareSourceOption({
    required this.opaqueId,
    required this.kind,
    required this.label,
    required this.width,
    required this.height,
  });

  final String opaqueId;
  final ScreenShareSourceKind kind;
  final String label;
  final int width;
  final int height;
}

/// Platform/media failures observed by the Feature without exposing native
/// error implementation details.
enum ScreenShareMediaEventKind {
  sourceEnded,
  encoderFailed,
  decoderFailed,
  surfaceReleased,
  transportLost,
  stopped,
}

/// Low-frequency opaque media lifecycle event.
final class ScreenShareMediaEvent {
  const ScreenShareMediaEvent({
    required this.operationId,
    required this.realtimeId,
    required this.generation,
    required this.kind,
    this.message,
  });

  final String operationId;
  final String realtimeId;
  final int generation;
  final ScreenShareMediaEventKind kind;
  final String? message;
}

/// Immutable state projection suitable for UI and route diagnostics.
final class ScreenShareOperationSnapshot {
  const ScreenShareOperationSnapshot({
    required this.state,
    required this.role,
    required this.realtimeId,
    required this.generation,
    required this.operationId,
    required this.mediaReady,
    this.expiresAt,
    this.failure,
  });

  const ScreenShareOperationSnapshot.idle({
    required String realtimeId,
    required int generation,
  }) : this(
         state: ScreenShareOperationState.idle,
         role: null,
         realtimeId: realtimeId,
         generation: generation,
         operationId: null,
         mediaReady: false,
       );

  final ScreenShareOperationState state;
  final ScreenShareRole? role;
  final String realtimeId;
  final int generation;
  final String? operationId;
  final bool mediaReady;
  final DateTime? expiresAt;
  final String? failure;

  bool get isTerminal => switch (state) {
    ScreenShareOperationState.rejected ||
    ScreenShareOperationState.cancelled ||
    ScreenShareOperationState.expired ||
    ScreenShareOperationState.failed => true,
    _ => false,
  };
}

/// Creates a wire value with the common screen-share defaults.
RealtimeConsent buildScreenShareConsent({
  required String operationId,
  required String realtimeId,
  required String sharedSessionInstanceId,
  required DateTime issuedAt,
  required DateTime expiresAt,
  required RealtimeConsentDecision decision,
  required String senderPeerId,
  required int actionRevision,
}) => RealtimeConsent(
  operationId: operationId,
  realtimeId: realtimeId,
  sharedSessionInstanceId: sharedSessionInstanceId,
  issuedAt: issuedAt,
  expiresAt: expiresAt,
  decision: decision,
  senderPeerId: senderPeerId,
  actionRevision: actionRevision,
);
