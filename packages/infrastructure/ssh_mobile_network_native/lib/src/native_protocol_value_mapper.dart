part of 'native_realtime_protocol.dart';

final class _NativeProtocolValueMapper {
  const _NativeProtocolValueMapper();

  void validateCommandId(String value) {
    if (value.isEmpty || utf8ByteLength(value) > _maxCommandIdBytes) {
      throw ArgumentError.value(
        value,
        'commandId',
        'Must contain 1-128 bytes.',
      );
    }
  }

  void validateIdentifier(String value, String name, int maxBytes) {
    if (value.isEmpty || utf8ByteLength(value) > maxBytes) {
      throw ArgumentError.value(
        value,
        name,
        '$name must contain 1-$maxBytes bytes.',
      );
    }
  }

  void validatePeerId(String value) {
    if (value.isEmpty || utf8ByteLength(value) > _maxPeerIdBytes) {
      throw ArgumentError.value(value, 'peerId', 'Must contain 1-128 bytes.');
    }
  }

  void validateStreamId(int value) {
    if (value < 1 || value > _maxStreamId) {
      throw ArgumentError.value(
        value,
        'streamId',
        'Must be within 1-$_maxStreamId.',
      );
    }
  }

  void validateStreamHandle(NativeStreamHandle handle) {
    validatePeerId(handle.openerDeviceId);
    validateStreamId(handle.streamId);
  }

  Uint8List encodeStreamHandle(NativeStreamHandle handle) =>
      (_ProtoWriter()
            ..string(1, handle.openerDeviceId)
            ..varint(2, handle.streamId))
          .takeBytes();

  void validateStreamService(String value) {
    if (value.isEmpty || utf8ByteLength(value) > _maxStreamServiceBytes) {
      throw ArgumentError.value(
        value,
        'service',
        'Must contain 1-$_maxStreamServiceBytes bytes.',
      );
    }
  }

  void validateRealtimeId(String value) {
    if (value.length != _realtimeIdBytes ||
        value != value.toLowerCase() ||
        !isLowerHex(value)) {
      throw ArgumentError.value(
        value,
        'realtimeId',
        'Must be 32 lowercase hexadecimal characters.',
      );
    }
  }

  void validateDecodedRealtimeId(String value) {
    try {
      validateRealtimeId(value);
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
  }

  void validateDecodedPeerId(String value) {
    if (value.isEmpty || utf8ByteLength(value) > _maxPeerIdBytes) {
      throw const FormatException('Realtime peer ID is outside bounds.');
    }
  }

  void validateDecodedIdentifier(String value, String label) {
    if (value.isEmpty) {
      throw FormatException('$label is required.');
    }
  }

  int utf8ByteLength(String value) => utf8.encode(value).length;

  bool isLowerHex(String value) => value.codeUnits.every((code) {
    return (code >= 0x30 && code <= 0x39) || (code >= 0x61 && code <= 0x66);
  });

  void validateSignalPayload(NativeRealtimeSignalKind kind, Uint8List payload) {
    if (kind == NativeRealtimeSignalKind.unspecified) {
      throw ArgumentError.value(kind, 'kind', 'Unknown signal kind.');
    }
    if (payload.length > _maxRealtimePayloadBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'Payload is too large.',
      );
    }
    if (kind == NativeRealtimeSignalKind.iceCandidate &&
        payload.length > _maxIceCandidateBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'ICE candidate payload is too large.',
      );
    }
    if (kind == NativeRealtimeSignalKind.screenShareConsent &&
        payload.length > _maxScreenShareConsentPayloadBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'Screen-share consent payload is too large.',
      );
    }
    if (kind != NativeRealtimeSignalKind.webRtcClose &&
        kind != NativeRealtimeSignalKind.iceRestart &&
        kind != NativeRealtimeSignalKind.iceCandidate &&
        payload.isEmpty) {
      throw ArgumentError.value(
        payload,
        'payload',
        'Payload must not be empty.',
      );
    }
  }

  NativeNetworkError decodeError(Uint8List bytes) {
    final reader = _ProtoReader(bytes);
    var code = 0;
    var message = '';
    String? operation;
    String? peerId;
    var retryDisposition = NativeRetryDisposition.unspecified;
    var retryAfterSeconds = 0;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          code = reader.varint(field.wireType);
        case 2:
          message = reader.string(field.wireType, _maxErrorMessageBytes);
        case 3:
          operation = reader.string(field.wireType, _maxCommandIdBytes);
        case 4:
          peerId = reader.string(field.wireType, _maxPeerIdBytes);
        case 5:
          retryDisposition = NativeRetryDisposition.fromWire(
            reader.varint(field.wireType),
          );
        case 6:
          retryAfterSeconds = reader.varint(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    return NativeNetworkError(
      code: code,
      message: message,
      operation: operation?.isEmpty == true ? null : operation,
      peerId: peerId?.isEmpty == true ? null : peerId,
      retryDisposition: retryDisposition,
      retryAfterSeconds: retryAfterSeconds,
    );
  }
}
