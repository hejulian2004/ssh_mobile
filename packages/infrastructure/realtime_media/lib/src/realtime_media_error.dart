/// Typed failures surfaced by the media lifecycle boundary.
enum RealtimeMediaErrorCode {
  invalidArgument,
  unknownSession,
  duplicateAttach,
  invalidDirection,
  directionMismatch,
  duplicateEndpoint,
  driverUnavailable,
  peerMismatch,
  frameRejected,
  staleGeneration,
  staleEndpoint,
  useAfterRelease,
  failedState,
  sessionReleased,
  backendFailure,
}

/// Failure that is safe for a business-layer caller to classify and present.
final class RealtimeMediaException implements Exception {
  const RealtimeMediaException(this.code, this.message);

  final RealtimeMediaErrorCode code;
  final String message;

  @override
  String toString() => 'RealtimeMediaException($code, $message)';
}
