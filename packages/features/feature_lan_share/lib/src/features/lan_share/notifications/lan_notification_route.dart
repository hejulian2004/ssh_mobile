import 'package:flutter/material.dart';

import '../lan_share_feature_scope.dart';
import '../views/lan_chat_screen.dart';
import 'lan_system_notification.dart';

/// Pushes the existing device chat when a click is allowed to open it.
void openLanNotificationChat({
  required NavigatorState? navigator,
  required LanNotificationClick decision,
  required String initialAlias,
}) {
  if (navigator == null || decision is! LanNotificationOpenChat) return;
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => LanShareFeatureScope(
        child: LanChatScreen(
          targetDeviceId: decision.peerId,
          initialAlias: initialAlias,
        ),
      ),
    ),
  );
}
