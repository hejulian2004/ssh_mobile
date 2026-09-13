part of 'screen_share_controller.dart';

void _handleScreenShareConsent(
  ScreenShareController controller,
  RealtimeConsent consent,
) {
  if (controller._disposed ||
      consent.realtimeId != controller.realtimeId ||
      consent.sharedSessionInstanceId != controller.sharedSessionInstanceId ||
      consent.senderPeerId != controller.remotePeerId ||
      !consent.isFresh(controller._now())) {
    return;
  }
  final currentId = controller._snapshot.operationId;
  if (consent.decision == RealtimeConsentDecision.request) {
    if (consent.actionRevision != 1) return;
    if (controller.state == ScreenShareOperationState.idle) {
      controller._lastRemoteActionRevision = consent.actionRevision;
      controller._setSnapshot(
        ScreenShareOperationSnapshot(
          state: ScreenShareOperationState.incomingPending,
          role: ScreenShareRole.receiver,
          realtimeId: controller.realtimeId,
          generation: controller.generation,
          operationId: consent.operationId,
          mediaReady: controller._snapshot.mediaReady,
          expiresAt: consent.expiresAt,
        ),
      );
      controller._armExpiry(consent.expiresAt);
    } else if (controller.state == ScreenShareOperationState.outgoingPending &&
        currentId != null) {
      if (compareScreenShareIntents(
            leftInitiatorPeerId: controller.localPeerId,
            leftOperationId: currentId,
            rightInitiatorPeerId: controller.remotePeerId,
            rightOperationId: consent.operationId,
          ) <
          0) {
        // The local tuple wins. The remote request is a losing collision
        // proposal; no extra response is needed because the winner is
        // deterministic and the losing operation has not acquired media.
        return;
      }
      _replaceOutgoingWithIncoming(controller, consent);
    }
    return;
  }
  if (currentId == null || currentId != consent.operationId) return;
  if (consent.actionRevision <= controller._lastRemoteActionRevision) return;
  if (controller._lastRemoteActionRevision == 0 &&
      consent.actionRevision != 1) {
    controller._fail('Screen-share consent action revision is not contiguous.');
    return;
  }
  if (controller._lastRemoteActionRevision > 0 &&
      consent.actionRevision != controller._lastRemoteActionRevision + 1) {
    controller._fail('Screen-share consent action revision is not contiguous.');
    return;
  }
  controller._lastRemoteActionRevision = consent.actionRevision;
  switch (consent.decision) {
    case RealtimeConsentDecision.accept:
      if (controller.state == ScreenShareOperationState.outgoingPending) {
        controller._setState(ScreenShareOperationState.accepted);
        unawaited(controller._startCaptureIfReady());
      }
    case RealtimeConsentDecision.reject:
      if (controller.state == ScreenShareOperationState.outgoingPending ||
          controller.state == ScreenShareOperationState.accepted) {
        ++controller._operationEpoch;
        unawaited(controller._stopMediaIfActive());
        controller._setState(ScreenShareOperationState.rejected);
      }
    case RealtimeConsentDecision.cancel:
      if (!controller._snapshot.isTerminal) {
        ++controller._operationEpoch;
        unawaited(controller._stopMediaIfActive());
        controller._setState(ScreenShareOperationState.cancelled);
      }
    case RealtimeConsentDecision.request:
      break;
  }
}

void _replaceOutgoingWithIncoming(
  ScreenShareController controller,
  RealtimeConsent consent,
) {
  ++controller._operationEpoch;
  controller._expiryTimer?.cancel();
  controller._nextLocalActionRevision = 0;
  controller._lastRemoteActionRevision = consent.actionRevision;
  controller._setSnapshot(
    ScreenShareOperationSnapshot(
      state: ScreenShareOperationState.incomingPending,
      role: ScreenShareRole.receiver,
      realtimeId: controller.realtimeId,
      generation: controller.generation,
      operationId: consent.operationId,
      mediaReady: controller._snapshot.mediaReady,
      expiresAt: consent.expiresAt,
    ),
  );
  controller._armExpiry(consent.expiresAt);
}
