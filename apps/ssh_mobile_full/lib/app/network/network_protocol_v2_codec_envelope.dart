part of '../../services/network/network_protocol_v2_codec.dart';

/// 解码 envelope，按 wire tag 把控制结果和事件交给对应的 typed decoder。
NetworkProtocolFrame _decodeEvent(Uint8List bytes) {
  final reader = _ProtoReader(bytes);
  var eventId = '';
  var timestampMs = 0;
  var protocolVersion = 0;
  String? commandId;
  var commandAccepted = false;
  NetworkError? commandError;
  NetworkEvent? event;
  RealtimeConsent? screenShareConsent;
  SshStreamDataReceivedEvent? sshStreamData;
  SshStreamClosedEvent? sshStreamClosed;

  while (!reader.isDone) {
    final field = reader.field();
    switch (field.number) {
      case 1:
        eventId = utf8.decode(reader.bytes(field.wireType));
      case 2:
        timestampMs = reader.varint(field.wireType);
      case 3:
        protocolVersion = reader.varint(field.wireType);
      case 10:
        event = NetworkProtocolV2Codec._peerEvents.decodeState(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 11:
        event = NetworkProtocolV2Codec._transferEvents.decodeProgress(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 13:
        final result = _decodeCommandResult(reader.bytes(field.wireType));
        commandId = result.commandId;
        commandAccepted = result.accepted;
        commandError = result.error;
      case 29:
        final result = _decodeCommandResultV2(reader.bytes(field.wireType));
        commandId = result.commandId;
        commandAccepted = result.accepted;
        commandError = result.error;
      case 14:
        event = NetworkProtocolV2Codec._transferEvents.decodeOffer(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 15:
        event = NetworkProtocolV2Codec._transferEvents.decodeCompleted(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 16:
        event = NetworkProtocolV2Codec._transferEvents.decodeFailed(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 17:
        event = NetworkProtocolV2Codec._peerEvents.decodeRouteChanged(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 18:
        event = NetworkProtocolV2Codec._peerEvents.decodeRelayStateChanged(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 33:
        event = NetworkProtocolV2Codec._peerEvents.decodeRouteAttemptChanged(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 24:
        event = NetworkProtocolV2Codec._peerEvents.decodePresence(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 25:
        event = NetworkProtocolV2Codec._peerEvents.decodePresenceSnapshot(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 26:
        sshStreamData = NetworkProtocolV2Codec._streamEvents.decodeData(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 27:
        sshStreamClosed = NetworkProtocolV2Codec._streamEvents.decodeClosed(
          eventId,
          timestampMs,
          reader.bytes(field.wireType),
        );
      case 32:
        event = NetworkProtocolV2Codec._transferEvents
            .decodePeerTransferProgress(
              eventId,
              timestampMs,
              reader.bytes(field.wireType),
            );
      case 22:
        final signal = _decodeRealtimeSignal(reader.bytes(field.wireType));
        screenShareConsent = signal.consent;
      default:
        reader.skip(field.wireType);
    }
  }
  return NetworkProtocolFrame(
    eventId: eventId,
    protocolVersion: protocolVersion,
    commandId: commandId,
    commandAccepted: commandAccepted,
    commandError: commandError,
    event: event,
    screenShareConsent: screenShareConsent,
    sshStreamData: sshStreamData,
    sshStreamClosed: sshStreamClosed,
  );
}

/// 解码旧格式命令结果载荷。
_CommandResult _decodeCommandResult(Uint8List bytes) {
  final reader = _ProtoReader(bytes);
  var commandId = '';
  var accepted = false;
  NetworkError? error;
  while (!reader.isDone) {
    final field = reader.field();
    switch (field.number) {
      case 1:
        commandId = utf8.decode(reader.bytes(field.wireType));
      case 2:
        accepted = reader.varint(field.wireType) != 0;
      case 3:
        error = _decodeNetworkError(reader.bytes(field.wireType));
      default:
        reader.skip(field.wireType);
    }
  }
  return _CommandResult(commandId, accepted, error);
}

/// 解码 Network V2 的类型化命令结果载荷。
///
/// Native Protocol V2 使用 `CommandResult.state` 表达成功、失败或取消；
/// App 内部仍以 [NetworkProtocolFrame.commandAccepted] 和 [commandError]
/// 完成待处理命令，因此在此处统一转换两种结果格式。
_CommandResult _decodeCommandResultV2(Uint8List bytes) {
  final reader = _ProtoReader(bytes);
  var commandId = '';
  var state = 0;
  NetworkError? error;
  while (!reader.isDone) {
    final field = reader.field();
    switch (field.number) {
      case 1:
        commandId = utf8.decode(reader.bytes(field.wireType));
      case 2:
        // peer_id is carried for scoped diagnostics but is not needed by the
        // command completer here.
        reader.bytes(field.wireType);
      case 3:
        state = reader.varint(field.wireType);
      case 4:
        error = _decodeNetworkError(reader.bytes(field.wireType));
      default:
        reader.skip(field.wireType);
    }
  }
  if (commandId.isEmpty) {
    throw const FormatException('V2 command result has no command ID.');
  }
  return _CommandResult(commandId, state == 0, error);
}

/// 用于完成 Dart 命令 Future 的内部命令结果值。
final class _CommandResult {
  /// 创建命令结果值。
  const _CommandResult(this.commandId, this.accepted, this.error);

  final String commandId;
  final bool accepted;
  final NetworkError? error;
}

DateTime _eventTimestamp(int timestampMs) =>
    DateTime.fromMillisecondsSinceEpoch(timestampMs);

NetworkError _decodeNetworkError(Uint8List bytes) {
  final reader = _ProtoReader(bytes);
  var code = 0;
  var message = '';
  NetworkOperation? operation;
  String? peerId;
  var retryDisposition = RetryDisposition.unspecified;
  var retryAfterSeconds = 0;
  while (!reader.isDone) {
    final field = reader.field();
    switch (field.number) {
      case 1:
        code = reader.varint(field.wireType);
      case 2:
        message = utf8.decode(reader.bytes(field.wireType));
      case 3:
        operation = NetworkOperation.fromWire(
          utf8.decode(reader.bytes(field.wireType)),
        );
      case 4:
        peerId = utf8.decode(reader.bytes(field.wireType));
      case 5:
        retryDisposition = RetryDisposition.fromWire(
          reader.varint(field.wireType),
        );
      case 6:
        retryAfterSeconds = reader.varint(field.wireType);
      default:
        reader.skip(field.wireType);
    }
  }
  return NetworkError(
    code: NetworkErrorCode.fromWire(code),
    message: message,
    operation: operation,
    peerId: peerId?.isEmpty == true ? null : peerId,
    retryDisposition: retryDisposition,
    retryAfterSeconds: retryAfterSeconds,
  );
}
