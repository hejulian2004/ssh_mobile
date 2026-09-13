part of 'native_realtime_protocol.dart';

/// Owns bounded command validation, payload encoding, and V2 envelopes.
final class _NativeProtocolCommandEncoder {
  static const _values = _NativeProtocolValueMapper();

  /// Encodes a Peer connect request using the existing V2 command envelope.
  /// The v2 adapter supplies the business requirement, not a concrete socket.
  static Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
    int intent = 0,
    int communicationClass = 2,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    if (intent < 0 || communicationClass < 0 || communicationClass > 5) {
      throw ArgumentError.value(
        communicationClass,
        'communicationClass',
        'Communication class is outside the frozen wire range.',
      );
    }
    return _command(
      commandId,
      10,
      (_ProtoWriter()
            ..string(1, peerId)
            ..varint(2, intent)
            ..varint(3, communicationClass))
          .takeBytes(),
    );
  }

  /// Encodes a Peer disconnect request using the existing V2 command.
  static Uint8List disconnectPeerCommand({
    required String commandId,
    required String peerId,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    return _command(
      commandId,
      17,
      (_ProtoWriter()..string(1, peerId)).takeBytes(),
    );
  }

  /// Encodes a reliable message through the existing V2 tag 19.
  ///
  /// The frozen command does not carry `message_id`; the Delivery owner must
  /// provide that business identity at the next schema seam.
  static Uint8List sendMessageCommand({
    required String commandId,
    required String peerId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    if (channelId.isEmpty ||
        _values.utf8ByteLength(channelId) > _maxChannelIdBytes) {
      throw ArgumentError.value(
        channelId,
        'channelId',
        'Channel ID is invalid.',
      );
    }
    if (payload.length > _maxEventBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'Payload is too large.',
      );
    }
    return _command(
      commandId,
      19,
      (_ProtoWriter()
            ..string(1, peerId)
            ..string(2, channelId)
            ..bytesField(3, payload)
            ..varint(4, deliveryPolicy))
          .takeBytes(),
    );
  }

  /// Encodes the frozen peer-scoped message command (tag 30). The identity is
  /// `(peerId, messageId)` and never depends on a Session or route.
  static Uint8List sendMessageV2Command({
    required String commandId,
    required String peerId,
    required String messageId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
    NativeE2eePolicy e2eePolicy = NativeE2eePolicy.required,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateIdentifier(messageId, 'messageId', _maxMessageIdBytes);
    _values.validateIdentifier(channelId, 'channelId', _maxChannelIdBytes);
    if (payload.length > _maxEventBytes) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'Payload is too large.',
      );
    }
    return _command(
      commandId,
      30,
      (_ProtoWriter()
            ..string(1, peerId)
            ..string(2, messageId)
            ..string(3, channelId)
            ..bytesField(4, payload)
            ..varint(5, deliveryPolicy)
            ..varint(6, e2eePolicy.wireValue))
          .takeBytes(),
    );
  }

  static Uint8List upsertPeerV2Command({
    required String commandId,
    required NativePeerConfig config,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(config.peerId);
    if (config.endpointAddress.isNotEmpty) {
      _values.validateIdentifier(
        config.endpointAddress,
        'endpointAddress',
        _maxEventIdBytes,
      );
    }
    return _command(
      commandId,
      28,
      (_ProtoWriter()..message(
            1,
            (_ProtoWriter()
                  ..string(1, config.peerId)
                  ..string(2, config.endpointAddress)
                  ..bytesField(3, config.identityPublicKey)
                  ..bytesField(4, config.e2ePublicKey)
                  ..varint(5, config.e2eePolicy.wireValue)
                  ..varint(6, config.allowDirect ? 1 : 0)
                  ..varint(7, config.allowRelay ? 1 : 0))
                .takeBytes(),
          ))
          .takeBytes(),
    );
  }

  static Uint8List removePeerCommand({
    required String commandId,
    required String peerId,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    return _command(
      commandId,
      29,
      (_ProtoWriter()..string(1, peerId)).takeBytes(),
    );
  }

  static Uint8List transferCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
    int confirmedOffset = 0,
    bool resume = false,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateIdentifier(transferId, 'transferId', _maxTransferIdBytes);
    _values.validateIdentifier(filePath, 'filePath', _maxEventBytes);
    if (confirmedOffset < 0) {
      throw ArgumentError.value(confirmedOffset, 'confirmedOffset');
    }
    return _command(
      commandId,
      31,
      (_ProtoWriter()
            ..string(1, peerId)
            ..string(2, transferId)
            ..string(3, filePath)
            ..varint(4, confirmedOffset)
            ..varint(5, resume ? 1 : 0))
          .takeBytes(),
    );
  }

  static Uint8List peerDiagnosticsCommand({
    required String commandId,
    required String peerId,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    return _command(
      commandId,
      32,
      (_ProtoWriter()..string(1, peerId)).takeBytes(),
    );
  }

  static Uint8List networkEnvironmentChangedCommand({
    required String commandId,
    required int generation,
    required bool hasConnectivity,
    required bool isForeground,
    required bool isMetered,
  }) {
    _values.validateCommandId(commandId);
    if (generation < 0) throw ArgumentError.value(generation, 'generation');
    return _command(
      commandId,
      33,
      (_ProtoWriter()
            ..varint(1, generation)
            ..varint(2, hasConnectivity ? 1 : 0)
            ..varint(3, isForeground ? 1 : 0)
            ..varint(4, isMetered ? 1 : 0))
          .takeBytes(),
    );
  }

  /// Encodes a transfer request through the existing V2 tag 11.
  static Uint8List sendFileCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateIdentifier(transferId, 'transferId', _maxTransferIdBytes);
    _values.validateIdentifier(filePath, 'filePath', _maxEventBytes);
    return _command(
      commandId,
      11,
      (_ProtoWriter()
            ..string(1, transferId)
            ..string(2, peerId)
            ..string(3, filePath))
          .takeBytes(),
    );
  }

  /// Encodes a transfer cancellation through the existing V2 tag 12.
  static Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) {
    _values.validateCommandId(commandId);
    _values.validateIdentifier(transferId, 'transferId', _maxTransferIdBytes);
    return _command(
      commandId,
      12,
      (_ProtoWriter()..string(1, transferId)).takeBytes(),
    );
  }

  /// Encodes `StartRealtimeSession` into the V2 command envelope.
  static Uint8List startRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
  }) {
    _values.validateCommandId(commandId);
    _values.validateRealtimeId(realtimeId);
    _values.validatePeerId(peerId);
    return _command(
      commandId,
      21,
      (_ProtoWriter()
            ..string(1, realtimeId)
            ..string(2, peerId))
          .takeBytes(),
    );
  }

  /// Encodes `StopRealtimeSession` into the V2 command envelope.
  static Uint8List stopRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
  }) {
    _values.validateCommandId(commandId);
    _values.validateRealtimeId(realtimeId);
    return _command(
      commandId,
      22,
      (_ProtoWriter()..string(1, realtimeId)).takeBytes(),
    );
  }

  /// Encodes `SendRealtimeSignal` into the V2 command envelope.
  static Uint8List sendRealtimeSignalCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required NativeRealtimeSignalKind kind,
    required int revision,
    required Uint8List payload,
  }) {
    _values.validateCommandId(commandId);
    _values.validateRealtimeId(realtimeId);
    _values.validatePeerId(peerId);
    if (kind == NativeRealtimeSignalKind.unspecified) {
      throw ArgumentError.value(
        kind,
        'kind',
        'A concrete signal kind is required.',
      );
    }
    if (revision <= 0) {
      throw ArgumentError.value(revision, 'revision', 'Must be positive.');
    }
    _values.validateSignalPayload(kind, payload);
    return _command(
      commandId,
      23,
      (_ProtoWriter()
            ..string(1, realtimeId)
            ..string(2, peerId)
            ..varint(3, kind.wireValue)
            ..varint(4, revision)
            ..bytesField(5, payload))
          .takeBytes(),
    );
  }

  static Uint8List claimIncomingRealtimeOfferCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required String claimToken,
  }) => _incomingOfferCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    claimToken: claimToken,
    field: 34,
  );

  static Uint8List rejectIncomingRealtimeOfferCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required String claimToken,
  }) => _incomingOfferCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    claimToken: claimToken,
    field: 35,
  );

  static Uint8List discardIncomingRealtimeOfferCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required String claimToken,
  }) => _incomingOfferCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    claimToken: claimToken,
    field: 36,
  );

  static Uint8List _incomingOfferCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required String claimToken,
    required int field,
  }) {
    _values.validateCommandId(commandId);
    _values.validateRealtimeId(realtimeId);
    _values.validatePeerId(peerId);
    _values.validateIdentifier(claimToken, 'claimToken', _maxEventIdBytes);
    return _command(
      commandId,
      field,
      (_ProtoWriter()
            ..string(1, realtimeId)
            ..string(2, peerId)
            ..string(3, claimToken))
          .takeBytes(),
    );
  }

  /// Encodes `SshStreamOpen` into the V2 command envelope (tag 25).
  static Uint8List sshStreamOpenCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    String service = 'ssh',
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateStreamHandle(handle);
    _values.validateStreamService(service);
    return _command(
      commandId,
      25,
      (_ProtoWriter()
            ..string(1, peerId)
            ..message(2, _values.encodeStreamHandle(handle))
            ..string(3, service))
          .takeBytes(),
    );
  }

  /// Encodes `SshStreamData` into the V2 command envelope (tag 26).
  static Uint8List sshStreamDataCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required Uint8List data,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateStreamHandle(handle);
    if (data.length > _maxStreamDataBytes) {
      throw ArgumentError.value(
        data.length,
        'data',
        'SSH stream data is too large.',
      );
    }
    return _command(
      commandId,
      26,
      (_ProtoWriter()
            ..string(1, peerId)
            ..message(2, _values.encodeStreamHandle(handle))
            ..bytesField(3, data))
          .takeBytes(),
    );
  }

  /// Encodes `SshStreamClose` into the V2 command envelope (tag 27).
  static Uint8List sshStreamCloseCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) {
    _values.validateCommandId(commandId);
    _values.validatePeerId(peerId);
    _values.validateStreamHandle(handle);
    return _command(
      commandId,
      27,
      (_ProtoWriter()
            ..string(1, peerId)
            ..message(2, _values.encodeStreamHandle(handle)))
          .takeBytes(),
    );
  }

  static Uint8List _command(String commandId, int field, Uint8List payload) =>
      (_ProtoWriter()
            ..string(1, commandId)
            ..varint(2, _protocolVersion)
            ..message(field, payload))
          .takeBytes();
}
