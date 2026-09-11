import 'dart:convert';

/// Typed, versioned screen-share consent metadata.
///
/// Consent is a low-frequency authenticated control message. It contains no
/// SDP, ICE, encoded frames, native handles or credentials. Cross-device
/// freshness is bound by [realtimeId], [sharedSessionInstanceId], sender,
/// operation and action revision; native generations remain process-local
/// media leases and never appear in this wire value.
enum RealtimeConsentDecision {
  request(1),
  accept(2),
  reject(3),
  cancel(4);

  const RealtimeConsentDecision(this.wireValue);

  final int wireValue;

  static RealtimeConsentDecision? fromWire(int value) {
    for (final decision in values) {
      if (decision.wireValue == value) return decision;
    }
    return null;
  }
}

enum RealtimeConsentPurpose {
  screenShare(1);

  const RealtimeConsentPurpose(this.wireValue);

  final int wireValue;
}

enum RealtimeConsentMedia {
  screenVideo(1);

  const RealtimeConsentMedia(this.wireValue);

  final int wireValue;
}

/// Immutable wire-level consent value used by the SDK and Feature boundary.
final class RealtimeConsent {
  RealtimeConsent({
    required this.operationId,
    required this.realtimeId,
    required this.sharedSessionInstanceId,
    required this.issuedAt,
    required this.expiresAt,
    required this.decision,
    required this.senderPeerId,
    this.schemaVersion = 2,
    this.purpose = RealtimeConsentPurpose.screenShare,
    this.media = RealtimeConsentMedia.screenVideo,
    this.requiresAcceptance = true,
    required this.actionRevision,
  }) {
    _validate();
  }

  final int schemaVersion;
  final String operationId;
  final String realtimeId;
  final String sharedSessionInstanceId;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final RealtimeConsentDecision decision;
  final String senderPeerId;
  final RealtimeConsentPurpose purpose;
  final RealtimeConsentMedia media;
  final bool requiresAcceptance;
  final int actionRevision;

  int get issuedAtMs => issuedAt.millisecondsSinceEpoch;

  int get expiresAtMs => expiresAt.millisecondsSinceEpoch;

  bool isExpired([DateTime? now]) =>
      !(expiresAt.isAfter(now ?? DateTime.now()));

  RealtimeConsent copyWith({
    RealtimeConsentDecision? decision,
    int? actionRevision,
    DateTime? issuedAt,
    DateTime? expiresAt,
  }) => RealtimeConsent(
    schemaVersion: schemaVersion,
    operationId: operationId,
    realtimeId: realtimeId,
    sharedSessionInstanceId: sharedSessionInstanceId,
    issuedAt: issuedAt ?? this.issuedAt,
    expiresAt: expiresAt ?? this.expiresAt,
    decision: decision ?? this.decision,
    senderPeerId: senderPeerId,
    purpose: purpose,
    media: media,
    requiresAcceptance: requiresAcceptance,
    actionRevision: actionRevision ?? this.actionRevision,
  );

  @override
  bool operator ==(Object other) =>
      other is RealtimeConsent &&
      other.schemaVersion == schemaVersion &&
      other.operationId == operationId &&
      other.realtimeId == realtimeId &&
      other.sharedSessionInstanceId == sharedSessionInstanceId &&
      other.issuedAtMs == issuedAtMs &&
      other.expiresAtMs == expiresAtMs &&
      other.decision == decision &&
      other.senderPeerId == senderPeerId &&
      other.purpose == purpose &&
      other.media == media &&
      other.requiresAcceptance == requiresAcceptance &&
      other.actionRevision == actionRevision;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    operationId,
    realtimeId,
    sharedSessionInstanceId,
    issuedAtMs,
    expiresAtMs,
    decision,
    senderPeerId,
    purpose,
    media,
    requiresAcceptance,
    actionRevision,
  );

  void _validate() {
    if (schemaVersion != 2) {
      throw ArgumentError.value(schemaVersion, 'schemaVersion');
    }
    _validateText(operationId, 'operationId');
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(realtimeId)) {
      throw ArgumentError.value(realtimeId, 'realtimeId');
    }
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(sharedSessionInstanceId)) {
      throw ArgumentError.value(
        sharedSessionInstanceId,
        'sharedSessionInstanceId',
      );
    }
    if (issuedAt.millisecondsSinceEpoch <= 0 ||
        !expiresAt.isAfter(issuedAt) ||
        expiresAt.difference(issuedAt) > const Duration(minutes: 2)) {
      throw ArgumentError.value(expiresAt, 'expiresAt');
    }
    _validateText(senderPeerId, 'senderPeerId');
    if (!requiresAcceptance || actionRevision <= 0) {
      throw ArgumentError.value(actionRevision, 'actionRevision');
    }
  }

  static void _validateText(String value, String name) {
    if (value.trim().isEmpty || utf8.encode(value).length > 128) {
      throw ArgumentError.value(
        value,
        name,
        'must contain 1 to 128 UTF-8 bytes',
      );
    }
  }
}
