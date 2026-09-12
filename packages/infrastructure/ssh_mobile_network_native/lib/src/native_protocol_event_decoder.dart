part of 'native_realtime_protocol.dart';

/// Owns event envelope dispatch and typed FFI value construction.
final class _NativeProtocolEventDecoder {
  /// Decodes a native event. Unknown event payloads return null so a newer
  /// Rust event cannot terminate the public typed stream.
  static NativeNetworkEvent? decodeEvent(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > _maxEventBytes) {
      throw const FormatException('Native event is outside size bounds.');
    }
    final reader = _ProtoReader(bytes);
    var eventId = '';
    var timestampMs = 0;
    var protocolVersion = 0;
    int? payloadField;
    Uint8List? payload;
    while (!reader.isDone) {
      final field = reader.field();
      switch (field.number) {
        case 1:
          eventId = reader.string(field.wireType, _maxEventIdBytes);
        case 2:
          timestampMs = reader.varint(field.wireType);
        case 3:
          protocolVersion = reader.varint(field.wireType);
        case 13:
        case 10:
        case 11:
        case 14:
        case 15:
        case 16:
        case 18:
        case 19:
        case 20:
        case 24:
        case 25:
        case 21:
        case 22:
        case 23:
        case 26:
        case 27:
        case 28:
        case 29:
        case 30:
        case 31:
        case 32:
        case 33:
          payloadField = field.number;
          payload = reader.bytes(field.wireType);
        default:
          reader.skip(field.wireType);
      }
    }
    if (eventId.isEmpty) {
      throw const FormatException('Native event has no event ID.');
    }
    if (protocolVersion != _protocolVersion) {
      throw FormatException(
        'Unsupported native protocol version: $protocolVersion.',
      );
    }
    final eventPayload = payload;
    final fieldNumber = payloadField;
    if (eventPayload == null || fieldNumber == null) return null;
    return switch (fieldNumber) {
      10 => _NativePeerEventDecoder._decodePeerState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      11 => _NativeDeliveryEventDecoder._decodeTransferProgress(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      13 => _NativeDeliveryEventDecoder._decodeCommandResult(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      14 => _NativeDeliveryEventDecoder._decodeIncomingTransferOffer(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      15 => _NativeDeliveryEventDecoder._decodeTransferCompleted(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      16 => _NativeDeliveryEventDecoder._decodeTransferFailed(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      18 => _NativePeerEventDecoder._decodeRelayState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      19 => _NativeDeliveryEventDecoder._decodeChannelMessage(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      20 => _NativeDeliveryEventDecoder._decodeDeliveryAcked(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      21 => _NativeRealtimeEventDecoder._decodeRealtimeState(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      24 => _NativePeerEventDecoder._decodePresenceChanged(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      25 => _NativePeerEventDecoder._decodePresenceSnapshot(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      22 => _NativeRealtimeEventDecoder._decodeRealtimeSignal(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      23 => _NativeRealtimeEventDecoder._decodeRealtimeSnapshot(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      34 => _NativeRealtimeEventDecoder._decodeIncomingSessionOffer(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      26 => _NativeRealtimeEventDecoder._decodeSshStreamData(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      27 => _NativeRealtimeEventDecoder._decodeSshStreamClosed(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      28 => _NativePeerEventDecoder._decodePeerLifecycle(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      29 => _NativeDeliveryEventDecoder._decodeCommandResultV2(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      30 => _NativePeerEventDecoder._decodePeerDiagnostics(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      31 => _NativePeerEventDecoder._decodeEnvironmentChanged(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      32 => _NativePeerEventDecoder._decodePeerTransferProgress(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      33 => _NativePeerEventDecoder._decodeRouteAttemptChanged(
        eventId,
        timestampMs,
        protocolVersion,
        eventPayload,
      ),
      _ => null,
    };
  }
}
