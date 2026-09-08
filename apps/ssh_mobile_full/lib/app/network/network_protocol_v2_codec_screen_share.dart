part of '../../services/network/network_protocol_v2_codec.dart';

/// Handwritten App-shell binding for the typed screen-share consent payload.
///
/// The canonical protobuf remains `protocol/proto/network/v2/network.proto`;
/// this narrow codec exists so App contract tests can prove Dart wire parity
/// without generating a frame/bytes API for media.
Uint8List _encodeScreenShareConsent(RealtimeConsent consent) {
  // RealtimeConsent validates schema, identity, bounds and expiry in its
  // constructor. Re-validate the timestamp range here before writing a wire
  // varint so a future model extension cannot silently overflow the codec.
  if (consent.issuedAtMs <= 0 || consent.expiresAtMs <= consent.issuedAtMs) {
    throw ArgumentError.value(consent, 'consent');
  }
  return (_ProtoWriter()
        ..varint(1, consent.schemaVersion)
        ..string(2, consent.operationId)
        ..string(3, consent.realtimeId)
        ..varint(4, consent.generation)
        ..varint(5, consent.issuedAtMs)
        ..varint(6, consent.expiresAtMs)
        ..varint(7, consent.decision.wireValue)
        ..string(8, consent.senderPeerId)
        ..varint(9, consent.purpose.wireValue)
        ..varint(10, consent.media.wireValue)
        ..varint(11, consent.requiresAcceptance ? 1 : 0)
        ..varint(12, consent.actionRevision))
      .takeBytes();
}

RealtimeConsent _decodeScreenShareConsent(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 4 * 1024) {
    throw const FormatException(
      'Screen-share consent payload is out of bounds.',
    );
  }
  final reader = _ProtoReader(bytes);
  var schemaVersion = 0;
  var operationId = '';
  var realtimeId = '';
  var generation = 0;
  var issuedAtMs = 0;
  var expiresAtMs = 0;
  var decision = 0;
  var senderPeerId = '';
  var purpose = 0;
  var media = 0;
  var requiresAcceptance = false;
  var actionRevision = 0;
  while (!reader.isDone) {
    final field = reader.field();
    switch (field.number) {
      case 1:
        schemaVersion = reader.varint(field.wireType);
      case 2:
        operationId = utf8.decode(reader.bytes(field.wireType));
      case 3:
        realtimeId = utf8.decode(reader.bytes(field.wireType));
      case 4:
        generation = reader.varint(field.wireType);
      case 5:
        issuedAtMs = reader.varint(field.wireType);
      case 6:
        expiresAtMs = reader.varint(field.wireType);
      case 7:
        decision = reader.varint(field.wireType);
      case 8:
        senderPeerId = utf8.decode(reader.bytes(field.wireType));
      case 9:
        purpose = reader.varint(field.wireType);
      case 10:
        media = reader.varint(field.wireType);
      case 11:
        requiresAcceptance = reader.varint(field.wireType) != 0;
      case 12:
        actionRevision = reader.varint(field.wireType);
      default:
        reader.skip(field.wireType);
    }
  }
  final decodedDecision = RealtimeConsentDecision.fromWire(decision);
  if (decodedDecision == null || purpose != 1 || media != 1) {
    throw const FormatException(
      'Screen-share consent enum values are invalid.',
    );
  }
  try {
    return RealtimeConsent(
      schemaVersion: schemaVersion,
      operationId: operationId,
      realtimeId: realtimeId,
      generation: generation,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(issuedAtMs),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
      decision: decodedDecision,
      senderPeerId: senderPeerId,
      requiresAcceptance: requiresAcceptance,
      actionRevision: actionRevision,
    );
  } on ArgumentError catch (error) {
    throw FormatException(error.message);
  }
}

final class _RealtimeSignalDecoded {
  const _RealtimeSignalDecoded(this.consent);

  final RealtimeConsent? consent;
}

_RealtimeSignalDecoded _decodeRealtimeSignal(Uint8List bytes) {
  final reader = _ProtoReader(bytes);
  var realtimeId = '';
  var kind = 0;
  var payload = Uint8List(0);
  while (!reader.isDone) {
    final field = reader.field();
    switch (field.number) {
      case 1:
        realtimeId = utf8.decode(reader.bytes(field.wireType));
      case 2:
        reader.skip(field.wireType);
      case 3:
        kind = reader.varint(field.wireType);
      case 4:
        reader.skip(field.wireType);
      case 5:
        payload = reader.bytes(field.wireType);
      default:
        reader.skip(field.wireType);
    }
  }
  if (kind != 6) return const _RealtimeSignalDecoded(null);
  final consent = _decodeScreenShareConsent(payload);
  if (consent.realtimeId != realtimeId) {
    throw const FormatException(
      'Screen-share consent realtime ID does not match signal.',
    );
  }
  return _RealtimeSignalDecoded(consent);
}
