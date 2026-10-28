import 'dart:convert';

import 'package:flutter/widgets.dart';

/// Business events that can raise a system notification.
enum AppNotificationKind {
  message,
  transferRequest,
  transferSucceeded,
  transferFailed,
}

/// Whether the app is visible to the person using this device.
enum NotificationVisibility { foreground, background }

/// What a notification click is allowed to do.
enum NotificationActivation { openChat, showApp, ignore }

/// Stable identity for one Windows toast registration.
final class AppNotificationIdentity {
  const AppNotificationIdentity({
    required this.appName,
    required this.appUserModelId,
    required this.guid,
  });

  static const full = AppNotificationIdentity(
    appName: 'SSH Mobile',
    appUserModelId: 'Hejulian.SSHMobile',
    guid: 'A4E1C2B7-6D30-4F58-9A1B-2C8E5D0F7A64',
  );

  static const network = AppNotificationIdentity(
    appName: 'SSH Mobile Network',
    appUserModelId: 'Hejulian.SSHMobile.Network',
    guid: 'B5F2D3C8-7E41-4059-8B2C-3D9F6E108B75',
  );

  final String appName;
  final String appUserModelId;
  final String guid;
}

/// Fields stored in a notification payload. Message text never belongs here.
final class AppNotificationPayload {
  const AppNotificationPayload({
    required this.kind,
    required this.peerId,
    required this.businessId,
  });

  final AppNotificationKind kind;
  final String peerId;
  final String businessId;
}

/// A request to show a notification. [displayName] is optional and filtered.
final class AppNotificationRequest {
  const AppNotificationRequest({
    required this.kind,
    required this.peerId,
    required this.businessId,
    this.displayName,
    this.english = false,
  });

  final AppNotificationKind kind;
  final String peerId;
  final String businessId;
  final String? displayName;
  final bool english;

  AppNotificationPayload get payload => AppNotificationPayload(
    kind: kind,
    peerId: peerId,
    businessId: businessId,
  );
}

/// Maps Flutter lifecycle to the notification visibility rule.
NotificationVisibility visibilityForLifecycle(AppLifecycleState state) {
  return switch (state) {
    AppLifecycleState.hidden ||
    AppLifecycleState.paused ||
    AppLifecycleState.detached => NotificationVisibility.background,
    AppLifecycleState.resumed ||
    AppLifecycleState.inactive => NotificationVisibility.foreground,
  };
}

/// System notifications are only for a hidden or paused process.
bool shouldPresentSystemNotification({
  required NotificationVisibility visibility,
}) {
  return visibility == NotificationVisibility.background;
}

/// Stable notification id derived from the business id.
///
/// The same id replaces an existing alert. The range stays away from the SSH
/// foreground notification id and the client-tool alarm ids.
int stableNotificationId(AppNotificationKind kind, String businessId) {
  var hash = 0x811c9dc5;
  for (final unit in '${kind.name}:$businessId'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return 20000 + (hash % 1000000);
}

/// Drops aliases that could leak a path, secret, or raw peer id.
String? safeDisplayName(String? value, {required String peerId}) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (trimmed == peerId) return null;
  if (trimmed.length > 40) return null;
  if (trimmed.contains(RegExp(r'[/\\]|[\u0000-\u001F]'))) return null;
  if (trimmed.contains('..')) return null;
  if (RegExp(
    r'token|password|secret|credential|private',
    caseSensitive: false,
  ).hasMatch(trimmed)) {
    return null;
  }
  return trimmed;
}

/// Title and body shown to the operating system.
({String title, String body}) notificationCopy(
  AppNotificationKind kind, {
  required bool english,
  String? displayName,
  required String peerId,
}) {
  final name = safeDisplayName(displayName, peerId: peerId);
  final label = switch (kind) {
    AppNotificationKind.message => english ? 'New message' : '新消息',
    AppNotificationKind.transferRequest =>
      english ? 'File transfer request' : '文件传输申请',
    AppNotificationKind.transferSucceeded =>
      english ? 'File transfer complete' : '文件传输已完成',
    AppNotificationKind.transferFailed =>
      english ? 'File transfer failed' : '文件传输失败',
  };
  return (title: 'SSH Mobile', body: name == null ? label : '$label · $name');
}

/// Click behavior. A transfer request never accepts the transfer.
NotificationActivation activationFor(
  AppNotificationPayload payload, {
  required bool recalled,
  required bool peerMismatch,
}) {
  if (payload.peerId.isEmpty ||
      payload.businessId.isEmpty ||
      recalled ||
      peerMismatch) {
    return NotificationActivation.ignore;
  }
  if (payload.kind == AppNotificationKind.transferRequest) {
    return NotificationActivation.showApp;
  }
  return NotificationActivation.openChat;
}

/// Encodes a payload without message text or file paths.
String encodeNotificationPayload(AppNotificationPayload payload) {
  return jsonEncode(<String, String>{
    'v': '1',
    't': payload.kind.name,
    'p': payload.peerId,
    'b': payload.businessId,
  });
}

/// Returns null when the payload is missing, unknown, or the wrong version.
AppNotificationPayload? decodeNotificationPayload(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['v'] != '1') return null;
  final kindName = decoded['t'];
  final peerId = decoded['p'];
  final businessId = decoded['b'];
  if (kindName is! String || peerId is! String || businessId is! String) {
    return null;
  }
  for (final kind in AppNotificationKind.values) {
    if (kind.name == kindName) {
      return AppNotificationPayload(
        kind: kind,
        peerId: peerId,
        businessId: businessId,
      );
    }
  }
  return null;
}
