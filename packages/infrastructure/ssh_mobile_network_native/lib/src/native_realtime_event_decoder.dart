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
    return NativeRealtimeStateChangedEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      state: NativeRealtimeSessionState.fromWire(state),
      revision: revision,
      generation: generation,
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
    return NativeRealtimeSignalEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      kind: NativeRealtimeSignalKind.fromWire(kind),
      revision: revision,
      payload: payload,
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
    return NativeRealtimeSnapshotEvent(
      eventId: eventId,
      timestampMs: timestampMs,
      protocolVersion: protocolVersion,
      realtimeId: realtimeId,
      peerId: peerId,
      state: NativeRealtimeSessionState.fromWire(state),
      revision: revision,
      generation: generation,
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
