part of 'native_realtime_protocol.dart';

/// Bounded Protobuf command/event codec for the native Realtime API.
/// Bounded Protobuf command/event facade for the native SDK API.
final class NativeNetworkProtocol {
  /// Current native protocol version.
  static const int protocolVersion = _protocolVersion;
  static const _values = _NativeProtocolValueMapper();

  const NativeNetworkProtocol._();

  static Uint8List connectPeerCommand({
    required String commandId,
    required String peerId,
    int intent = 0,
    int communicationClass = 2,
  }) => _NativeProtocolCommandEncoder.connectPeerCommand(
    commandId: commandId,
    peerId: peerId,
    intent: intent,
    communicationClass: communicationClass,
  );

  static Uint8List disconnectPeerCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.disconnectPeerCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List sendMessageCommand({
    required String commandId,
    required String peerId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
  }) => _NativeProtocolCommandEncoder.sendMessageCommand(
    commandId: commandId,
    peerId: peerId,
    channelId: channelId,
    payload: payload,
    deliveryPolicy: deliveryPolicy,
  );

  static Uint8List sendMessageV2Command({
    required String commandId,
    required String peerId,
    required String messageId,
    required String channelId,
    required Uint8List payload,
    int deliveryPolicy = 2,
    NativeE2eePolicy e2eePolicy = NativeE2eePolicy.required,
  }) => _NativeProtocolCommandEncoder.sendMessageV2Command(
    commandId: commandId,
    peerId: peerId,
    messageId: messageId,
    channelId: channelId,
    payload: payload,
    deliveryPolicy: deliveryPolicy,
    e2eePolicy: e2eePolicy,
  );

  static Uint8List upsertPeerV2Command({
    required String commandId,
    required NativePeerConfig config,
  }) => _NativeProtocolCommandEncoder.upsertPeerV2Command(
    commandId: commandId,
    config: config,
  );

  static Uint8List removePeerCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.removePeerCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List transferCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
    int confirmedOffset = 0,
    bool resume = false,
  }) => _NativeProtocolCommandEncoder.transferCommand(
    commandId: commandId,
    peerId: peerId,
    transferId: transferId,
    filePath: filePath,
    confirmedOffset: confirmedOffset,
    resume: resume,
  );

  static Uint8List peerDiagnosticsCommand({
    required String commandId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.peerDiagnosticsCommand(
    commandId: commandId,
    peerId: peerId,
  );

  static Uint8List networkEnvironmentChangedCommand({
    required String commandId,
    required int generation,
    required bool hasConnectivity,
    required bool isForeground,
    required bool isMetered,
  }) => _NativeProtocolCommandEncoder.networkEnvironmentChangedCommand(
    commandId: commandId,
    generation: generation,
    hasConnectivity: hasConnectivity,
    isForeground: isForeground,
    isMetered: isMetered,
  );

  static Uint8List sendFileCommand({
    required String commandId,
    required String peerId,
    required String transferId,
    required String filePath,
  }) => _NativeProtocolCommandEncoder.sendFileCommand(
    commandId: commandId,
    peerId: peerId,
    transferId: transferId,
    filePath: filePath,
  );

  static Uint8List cancelTransferCommand({
    required String commandId,
    required String transferId,
  }) => _NativeProtocolCommandEncoder.cancelTransferCommand(
    commandId: commandId,
    transferId: transferId,
  );

  static Uint8List startRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
  }) => _NativeProtocolCommandEncoder.startRealtimeSessionCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
  );

  static Uint8List stopRealtimeSessionCommand({
    required String commandId,
    required String realtimeId,
  }) => _NativeProtocolCommandEncoder.stopRealtimeSessionCommand(
    commandId: commandId,
    realtimeId: realtimeId,
  );

  static Uint8List sendRealtimeSignalCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required NativeRealtimeSignalKind kind,
    required int revision,
    required Uint8List payload,
  }) => _NativeProtocolCommandEncoder.sendRealtimeSignalCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    kind: kind,
    revision: revision,
    payload: payload,
  );

  static Uint8List claimIncomingRealtimeOfferCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required String claimToken,
  }) => _NativeProtocolCommandEncoder.claimIncomingRealtimeOfferCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    claimToken: claimToken,
  );

  static Uint8List rejectIncomingRealtimeOfferCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required String claimToken,
  }) => _NativeProtocolCommandEncoder.rejectIncomingRealtimeOfferCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    claimToken: claimToken,
  );

  static Uint8List discardIncomingRealtimeOfferCommand({
    required String commandId,
    required String realtimeId,
    required String peerId,
    required String claimToken,
  }) => _NativeProtocolCommandEncoder.discardIncomingRealtimeOfferCommand(
    commandId: commandId,
    realtimeId: realtimeId,
    peerId: peerId,
    claimToken: claimToken,
  );

  /// Encodes the versioned screen-share consent payload carried by the
  /// dedicated realtime signal kind. This helper emits metadata only; it has
  /// no API for frames, native pointers or credentials.
  static Uint8List encodeScreenShareConsent(NativeScreenShareConsent consent) {
    if (consent.schemaVersion != 2 ||
        consent.operationId.isEmpty ||
        _values.utf8ByteLength(consent.operationId) >
            _maxScreenShareOperationIdBytes ||
        consent.realtimeId.isEmpty ||
        consent.sharedSessionInstanceId.isEmpty ||
        _values.utf8ByteLength(consent.sharedSessionInstanceId) !=
            _sharedSessionInstanceIdBytes ||
        consent.issuedAtMs <= 0 ||
        consent.expiresAtMs <= consent.issuedAtMs ||
        consent.expiresAtMs - consent.issuedAtMs >
            const Duration(minutes: 2).inMilliseconds ||
        consent.senderPeerId.isEmpty ||
        _values.utf8ByteLength(consent.senderPeerId) > _maxPeerIdBytes ||
        consent.decision == NativeScreenShareConsentDecision.unspecified ||
        consent.purpose != NativeScreenShareConsentPurpose.screenShare ||
        consent.media != NativeScreenShareMediaKind.screenVideo ||
        !consent.requiresAcceptance ||
        consent.actionRevision <= 0) {
      throw ArgumentError.value(consent, 'consent', 'Invalid consent payload.');
    }
    _values.validateRealtimeId(consent.realtimeId);
    _values.validateSharedSessionInstanceId(consent.sharedSessionInstanceId);
    return (_ProtoWriter()
          ..varint(1, consent.schemaVersion)
          ..string(2, consent.operationId)
          ..string(3, consent.realtimeId)
          ..string(12, consent.sharedSessionInstanceId)
          ..varint(4, consent.issuedAtMs)
          ..varint(5, consent.expiresAtMs)
          ..varint(6, consent.decision.wireValue)
          ..string(7, consent.senderPeerId)
          ..varint(8, consent.purpose.wireValue)
          ..varint(9, consent.media.wireValue)
          ..varint(10, consent.requiresAcceptance ? 1 : 0)
          ..varint(11, consent.actionRevision))
        .takeBytes();
  }

  static Uint8List sshStreamOpenCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    String service = 'ssh',
  }) => _NativeProtocolCommandEncoder.sshStreamOpenCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    service: service,
  );

  static Uint8List sshStreamDataCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
    required Uint8List data,
  }) => _NativeProtocolCommandEncoder.sshStreamDataCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
    data: data,
  );

  static Uint8List sshStreamCloseCommand({
    required String commandId,
    required String peerId,
    required NativeStreamHandle handle,
  }) => _NativeProtocolCommandEncoder.sshStreamCloseCommand(
    commandId: commandId,
    peerId: peerId,
    handle: handle,
  );

  static NativeNetworkEvent? decodeEvent(Uint8List bytes) =>
      _NativeProtocolEventDecoder.decodeEvent(bytes);
}
