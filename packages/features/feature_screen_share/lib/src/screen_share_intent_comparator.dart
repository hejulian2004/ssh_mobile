import 'dart:convert';

/// Compares two screen-share intents using the deterministic collision rule.
///
/// UTF-8 byte ordering is part of the business contract. Keeping this pure
/// and public lets the App-scope arbitration registry converge operations that
/// have different realtime ids without duplicating Feature logic.
int compareScreenShareIntents({
  required String leftInitiatorPeerId,
  required String leftOperationId,
  required String rightInitiatorPeerId,
  required String rightOperationId,
}) {
  final peerComparison = _compareUtf8(
    leftInitiatorPeerId,
    rightInitiatorPeerId,
  );
  if (peerComparison != 0) return peerComparison;
  return _compareUtf8(leftOperationId, rightOperationId);
}

int _compareUtf8(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  final length = leftBytes.length < rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < length; index++) {
    final comparison = leftBytes[index].compareTo(rightBytes[index]);
    if (comparison != 0) return comparison;
  }
  return leftBytes.length.compareTo(rightBytes.length);
}
