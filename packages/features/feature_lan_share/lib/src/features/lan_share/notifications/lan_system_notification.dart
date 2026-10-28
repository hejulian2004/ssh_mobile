import '../../../services/lan_share/lan_share_models.dart';

/// LAN events that an app may turn into a system notification.
enum LanNotificationKind {
  message,
  transferRequest,
  transferSucceeded,
  transferFailed,
}

/// A persisted LAN event. Message text and file paths do not belong here.
final class LanNotificationEvent {
  const LanNotificationEvent({
    required this.kind,
    required this.businessId,
    required this.peerId,
    this.displayName,
  });

  final LanNotificationKind kind;
  final String businessId;
  final String peerId;
  final String? displayName;
}

/// App-owned presentation of a LAN notification event.
abstract interface class LanSystemNotificationPort {
  Future<void> present(LanNotificationEvent event);
}

/// Returns a message event only after an incoming text or clipboard message.
LanNotificationEvent? incomingMessageNotification(LanMessage message) {
  if (!message.isIncoming || message.isRecalled) return null;
  if (message.payloadType != LanPayloadType.text &&
      message.payloadType != LanPayloadType.clipboard) {
    return null;
  }
  if (message.id.isEmpty || message.senderId.isEmpty) return null;
  return LanNotificationEvent(
    kind: LanNotificationKind.message,
    businessId: message.id,
    peerId: message.senderId,
    displayName: message.senderAlias,
  );
}

/// Returns a file-request event without the file name or path.
LanNotificationEvent? transferRequestNotification({
  required String sessionId,
  required String peerId,
  required bool expired,
}) {
  if (expired || sessionId.isEmpty || peerId.isEmpty) return null;
  return LanNotificationEvent(
    kind: LanNotificationKind.transferRequest,
    businessId: sessionId,
    peerId: peerId,
  );
}

/// Returns one terminal event for an incoming transfer, never for progress.
LanNotificationEvent? incomingTransferTerminalNotification({
  required bool isIncoming,
  required bool succeeded,
  required String transferId,
  required String peerId,
  String? displayName,
}) {
  if (!isIncoming || transferId.isEmpty || peerId.isEmpty) return null;
  return LanNotificationEvent(
    kind: succeeded
        ? LanNotificationKind.transferSucceeded
        : LanNotificationKind.transferFailed,
    businessId: transferId,
    peerId: peerId,
    displayName: displayName,
  );
}

/// What a notification click is allowed to do.
sealed class LanNotificationClick {
  const LanNotificationClick();
}

/// Open the existing chat route for [peerId].
final class LanNotificationOpenChat extends LanNotificationClick {
  const LanNotificationOpenChat(this.peerId);

  final String peerId;
}

/// Bring the app forward without accepting a request.
final class LanNotificationShowApp extends LanNotificationClick {
  const LanNotificationShowApp();
}

/// Drop a recalled, mismatched, or empty click.
final class LanNotificationIgnore extends LanNotificationClick {
  const LanNotificationIgnore();
}

/// Chooses a click result from history that is already loaded.
///
/// A missing history row still opens chat: the event was persisted before the
/// notification was published. A recalled row or a different peer does not.
LanNotificationClick decideLanNotificationClick({
  required LanNotificationKind kind,
  required String peerId,
  required String businessId,
  required Iterable<LanMessage> history,
  String? visiblePeerId,
}) {
  if (peerId.isEmpty || businessId.isEmpty) {
    return const LanNotificationIgnore();
  }
  for (final message in history) {
    if (message.id != businessId) continue;
    if (message.isRecalled) return const LanNotificationIgnore();
    final expected = message.isIncoming ? message.senderId : message.receiverId;
    if (expected != peerId) return const LanNotificationIgnore();
    break;
  }
  if (kind == LanNotificationKind.transferRequest || visiblePeerId == peerId) {
    return const LanNotificationShowApp();
  }
  return LanNotificationOpenChat(peerId);
}
