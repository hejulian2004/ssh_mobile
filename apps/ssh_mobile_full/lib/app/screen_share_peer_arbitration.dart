import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:feature_screen_share/feature_screen_share.dart';

/// Per-peer pending arbitration and App-wide admission for committed shares.
///
/// It deliberately owns no session or media resource. Owners release their
/// own resources after a losing slot is reported.
final class AppScreenSharePeerArbitrationRegistry extends ChangeNotifier {
  final Map<String, _ScreenShareIntent> _intents =
      <String, _ScreenShareIntent>{};
  bool _disposed = false;

  bool get isBusy => _intents.values.any((intent) => intent.active);

  bool activate({
    required String remotePeerId,
    required String initiatorPeerId,
    required String operationId,
  }) {
    if (_disposed) return false;
    final current = _intents[remotePeerId];
    if (current == null ||
        current.initiatorPeerId != initiatorPeerId ||
        current.operationId != operationId) {
      return false;
    }
    if (current.active) return true;
    if (isBusy) return false;
    current.active = true;
    notifyListeners();
    return true;
  }

  bool acquire({
    required String remotePeerId,
    required String initiatorPeerId,
    required String operationId,
    FutureOr<void> Function()? onReplaced,
  }) {
    if (_disposed || isBusy) return false;
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
    if (_disposed) return;
    final current = _intents[remotePeerId];
    if (current == null ||
        current.initiatorPeerId != initiatorPeerId ||
        current.operationId != operationId) {
      return;
    }
    _intents.remove(remotePeerId);
    if (current.active) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _intents.clear();
    super.dispose();
  }
}

final class _ScreenShareIntent {
  _ScreenShareIntent({
    required this.initiatorPeerId,
    required this.operationId,
    this.onReplaced,
  });

  final String initiatorPeerId;
  final String operationId;
  final FutureOr<void> Function()? onReplaced;
  bool active = false;
}
