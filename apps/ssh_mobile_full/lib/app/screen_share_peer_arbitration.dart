import 'dart:async';

import 'package:feature_screen_share/feature_screen_share.dart';

/// App-scope deterministic arbitration for one peer's screen-share intents.
///
/// It deliberately owns no session or media resource. Owners release their
/// own resources after a losing slot is reported.
final class AppScreenSharePeerArbitrationRegistry {
  final Map<String, _ScreenShareIntent> _intents =
      <String, _ScreenShareIntent>{};

  bool acquire({
    required String remotePeerId,
    required String initiatorPeerId,
    required String operationId,
    FutureOr<void> Function()? onReplaced,
  }) {
    final candidate = _ScreenShareIntent(
      initiatorPeerId: initiatorPeerId,
      operationId: operationId,
      onReplaced: onReplaced,
    );
    final existing = _intents[remotePeerId];
    if (existing == null ||
        compareScreenShareIntents(
              leftInitiatorPeerId: initiatorPeerId,
              leftOperationId: operationId,
              rightInitiatorPeerId: existing.initiatorPeerId,
              rightOperationId: existing.operationId,
            ) <
            0) {
      _intents[remotePeerId] = candidate;
      final replaced = existing?.onReplaced;
      if (replaced != null) {
        unawaited(Future<void>.sync(replaced).catchError((_) {}));
      }
      return true;
    }
    return false;
  }

  void release({
    required String remotePeerId,
    required String initiatorPeerId,
    required String operationId,
  }) {
    final current = _intents[remotePeerId];
    if (current == null ||
        current.initiatorPeerId != initiatorPeerId ||
        current.operationId != operationId) {
      return;
    }
    _intents.remove(remotePeerId);
  }
}

final class _ScreenShareIntent {
  const _ScreenShareIntent({
    required this.initiatorPeerId,
    required this.operationId,
    this.onReplaced,
  });

  final String initiatorPeerId;
  final String operationId;
  final FutureOr<void> Function()? onReplaced;
}
