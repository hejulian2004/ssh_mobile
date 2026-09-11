part of 'native_realtime_protocol.dart';

/// Owns Realtime and SSH ReliableStream event mapping.
final class _NativeRealtimeEventDecoder {
  static const _values = _NativeProtocolValueMapper();

  static NativeRealtimeStateChangedEvent _decodeRealtimeState(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var realtimeId = '';
    var peerId = '';
    var state = 0;
    var revision = 0;
    var generation = 0;
    var sharedSessionInstanceId = '';
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          state = reader.varint(field.wireType);
        case 4:
          revision = reader.varint(field.wireType);
        case 5:
          error = _values.decodeError(reader.bytes(field.wireType));
        case 6:
          generation = reader.varint(field.wireType);
        case 7:
          sharedSessionInstanceId = reader.string(
            field.wireType,
            _sharedSessionInstanceIdBytes,
          );
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedRealtimeId(realtimeId);
    _values.validateDecodedPeerId(peerId);
    if (generation <= 0) {
      throw const FormatException(
        'Realtime session generation must be positive.',
      );
    }
    _values.validateDecodedSharedSessionInstanceId(sharedSessionInstanceId);
    return NativeRealtimeStateChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      state: NativeRealtimeSessionState.fromWire(state),
      revision: revision,
      generation: generation,
      sharedSessionInstanceId: sharedSessionInstanceId,
      error: error,
    );
  }

  static NativeRealtimeSignalEvent _decodeRealtimeSignal(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var realtimeId = '';
    var peerId = '';
    var kind = 0;
    var revision = 0;
    var payload = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          kind = reader.varint(field.wireType);
        case 4:
          revision = reader.varint(field.wireType);
        case 5:
          payload = reader.bytes(field.wireType, _maxRealtimePayloadBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedRealtimeId(realtimeId);
    _values.validateDecodedPeerId(peerId);
    try {
      _values.validateSignalPayload(
        NativeRealtimeSignalKind.fromWire(kind),
        payload,
      );
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
    if (revision <= 0) {
      throw const FormatException('Realtime signal revision must be positive.');
    }
    final signalKind = NativeRealtimeSignalKind.fromWire(kind);
    final consent = signalKind == NativeRealtimeSignalKind.screenShareConsent
        ? _decodeScreenShareConsent(payload, realtimeId)
        : null;
    return NativeRealtimeSignalEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      kind: signalKind,
      revision: revision,
      payload: payload,
      consent: consent,
    );
  }

  static NativeScreenShareConsent _decodeScreenShareConsent(
    Uint8List bytes,
    String expectedRealtimeId,
  ) {
    if (bytes.isEmpty || bytes.length > _maxScreenShareConsentPayloadBytes) {
      throw const FormatException(
        'Screen-share consent payload is outside bounds.',
      );
    }
    final reader = _ProtoReader(bytes);
    var schemaVersion = 0;
    var operationId = '';
    var realtimeId = '';
    var issuedAtMs = 0;
    var expiresAtMs = 0;
    var decision = 0;
    var senderPeerId = '';
    var purpose = 0;
    var media = 0;
    var requiresAcceptance = false;
    var actionRevision = 0;
    var sharedSessionInstanceId = '';
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          schemaVersion = reader.varint(field.wireType);
        case 2:
          operationId = reader.string(
            field.wireType,
            _maxScreenShareOperationIdBytes,
          );
        case 3:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 4:
          issuedAtMs = reader.varint(field.wireType);
        case 5:
          expiresAtMs = reader.varint(field.wireType);
        case 6:
          decision = reader.varint(field.wireType);
        case 7:
          senderPeerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 8:
          purpose = reader.varint(field.wireType);
        case 9:
          media = reader.varint(field.wireType);
        case 10:
          requiresAcceptance = reader.varint(field.wireType) != 0;
        case 11:
          actionRevision = reader.varint(field.wireType);
        case 12:
          sharedSessionInstanceId = reader.string(
            field.wireType,
            _sharedSessionInstanceIdBytes,
          );
        default:
          reader.skip(field.wireType);
      }
    }
    if (schemaVersion != 2) {
      throw const FormatException(
        'Unsupported screen-share consent schema version.',
      );
    }
    if (operationId.isEmpty) {
      throw const FormatException(
        'Screen-share consent operation is required.',
      );
    }
    if (realtimeId != expectedRealtimeId) {
      throw const FormatException(
        'Screen-share consent realtime ID does not match signal.',
      );
    }
    if (issuedAtMs <= 0 ||
        expiresAtMs <= issuedAtMs ||
        expiresAtMs - issuedAtMs > const Duration(minutes: 2).inMilliseconds) {
      throw const FormatException(
        'Screen-share consent expiration is invalid.',
      );
    }
    if (senderPeerId.isEmpty ||
        sharedSessionInstanceId.isEmpty ||
        NativeScreenShareConsentDecision.fromWire(decision) ==
            NativeScreenShareConsentDecision.unspecified ||
        NativeScreenShareConsentPurpose.fromWire(purpose) !=
            NativeScreenShareConsentPurpose.screenShare ||
        NativeScreenShareMediaKind.fromWire(media) !=
            NativeScreenShareMediaKind.screenVideo ||
        !requiresAcceptance ||
        actionRevision <= 0) {
      throw const FormatException('Screen-share consent fields are invalid.');
    }
    _values.validateDecodedSharedSessionInstanceId(sharedSessionInstanceId);
    return NativeScreenShareConsent(
      schemaVersion: schemaVersion,
      operationId: operationId,
      realtimeId: realtimeId,
      sharedSessionInstanceId: sharedSessionInstanceId,
      issuedAtMs: issuedAtMs,
      expiresAtMs: expiresAtMs,
      decision: NativeScreenShareConsentDecision.fromWire(decision),
      senderPeerId: senderPeerId,
      purpose: NativeScreenShareConsentPurpose.fromWire(purpose),
      media: NativeScreenShareMediaKind.fromWire(media),
      requiresAcceptance: requiresAcceptance,
      actionRevision: actionRevision,
    );
  }

  static NativeRealtimeSnapshotEvent _decodeRealtimeSnapshot(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var realtimeId = '';
    var peerId = '';
    var state = 0;
    var revision = 0;
    var generation = 0;
    var sharedSessionInstanceId = '';
    NativeNetworkError? error;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          realtimeId = reader.string(field.wireType, _realtimeIdBytes);
        case 2:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 3:
          state = reader.varint(field.wireType);
        case 4:
          revision = reader.varint(field.wireType);
        case 5:
          error = _values.decodeError(reader.bytes(field.wireType));
        case 6:
          generation = reader.varint(field.wireType);
        case 7:
          sharedSessionInstanceId = reader.string(
            field.wireType,
            _sharedSessionInstanceIdBytes,
          );
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedRealtimeId(realtimeId);
    _values.validateDecodedPeerId(peerId);
    if (generation <= 0) {
      throw const FormatException(
        'Realtime session generation must be positive.',
      );
    }
    _values.validateDecodedSharedSessionInstanceId(sharedSessionInstanceId);
    return NativeRealtimeSnapshotEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      state: NativeRealtimeSessionState.fromWire(state),
      revision: revision,
      generation: generation,
      sharedSessionInstanceId: sharedSessionInstanceId,
      error: error,
    );
  }

  static NativeStreamHandle _decodeStreamHandle(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var openerDeviceId = '';
    var streamId = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          openerDeviceId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          streamId = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(openerDeviceId);
    if (streamId < 1 || streamId > _maxStreamId) {
      throw const FormatException('SSH stream ID is outside bounds.');
    }
    return NativeStreamHandle(
      openerDeviceId: openerDeviceId,
      streamId: streamId,
    );
  }

  static NativeSshStreamDataReceivedEvent _decodeSshStreamData(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    NativeStreamHandle? handle;
    var data = Uint8List(0);
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          handle = _decodeStreamHandle(
            reader.bytes(field.wireType, _maxStreamHandleBytes),
          );
        case 3:
          data = reader.bytes(field.wireType, _maxStreamDataBytes);
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    final streamHandle = handle;
    if (streamHandle == null) {
      throw const FormatException('SSH stream event has no stream handle.');
    }
    return NativeSshStreamDataReceivedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      handle: streamHandle,
      data: data,
    );
  }

  static NativeSshStreamClosedEvent _decodeSshStreamClosed(
    String eventId,
    int timestampMs,
    int protocolVersion,
    Uint8List bytes,
  ) {
    final reader = _ProtoReader(bytes);
    var peerId = '';
    NativeStreamHandle? handle;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 2:
          handle = _decodeStreamHandle(
            reader.bytes(field.wireType, _maxStreamHandleBytes),
          );
        default:
          reader.skip(field.wireType);
      }
    }
    _values.validateDecodedPeerId(peerId);
    final streamHandle = handle;
    if (streamHandle == null) {
      throw const FormatException('SSH stream event has no stream handle.');
    }
    return NativeSshStreamClosedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      peerId: peerId,
      handle: streamHandle,
    );
  }
}
