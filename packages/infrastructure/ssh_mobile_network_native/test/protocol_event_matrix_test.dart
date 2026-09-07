import 'dart:typed_data';

import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:test/test.dart';

void main() {
  const realtimeId = '00112233445566778899aabbccddeeff';
  final payload = Uint8List.fromList(<int>[0x76, 0x3d, 0x30]);
  final handle = NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7);

  test('native operation status maps every C ABI terminal code', () {
    expect(
      NativeOperationStatus.fromNativeCode(0),
      NativeOperationStatus.success,
    );
    expect(
      NativeOperationStatus.fromNativeCode(-1),
      NativeOperationStatus.invalidArgument,
    );
    expect(
      NativeOperationStatus.fromNativeCode(-2),
      NativeOperationStatus.invalidArgument,
    );
    expect(
      NativeOperationStatus.fromNativeCode(-4),
      NativeOperationStatus.stopped,
    );
    expect(
      NativeOperationStatus.fromNativeCode(99),
      NativeOperationStatus.failure,
    );
    const expected = <int, NativeOperationStatus>{
      0: NativeOperationStatus.success,
      -1: NativeOperationStatus.invalidArgument,
      -2: NativeOperationStatus.unknownSession,
      -3: NativeOperationStatus.failure,
      -4: NativeOperationStatus.stopped,
      -5: NativeOperationStatus.staleGeneration,
      -6: NativeOperationStatus.staleEndpoint,
      -7: NativeOperationStatus.directionMismatch,
      -8: NativeOperationStatus.duplicateEndpoint,
      -9: NativeOperationStatus.driverUnavailable,
      -10: NativeOperationStatus.peerMismatch,
      -11: NativeOperationStatus.frameRejected,
    };
    for (final entry in expected.entries) {
      expect(
        NativeOperationStatus.fromRealtimeMediaCode(entry.key),
        entry.value,
        reason: 'media status ${entry.key} must remain typed',
      );
    }
  });

  test('all public V2 command builders accept bounded edge values', () {
    final config = NativePeerConfig(
      peerId: 'peer-a',
      endpointAddress: 'quic://peer.example:443',
      identityPublicKey: Uint8List(32),
      e2ePublicKey: Uint8List(32),
      e2eePolicy: NativeE2eePolicy.disabled,
    );

    final commands = <Uint8List>[
      NativeNetworkProtocol.connectPeerCommand(
        commandId: 'connect',
        peerId: 'peer-a',
        intent: 1,
        communicationClass: 5,
      ),
      NativeNetworkProtocol.disconnectPeerCommand(
        commandId: 'disconnect',
        peerId: 'peer-a',
      ),
      NativeNetworkProtocol.sendMessageCommand(
        commandId: 'message',
        peerId: 'peer-a',
        channelId: 'channel-a',
        payload: payload,
        deliveryPolicy: 3,
      ),
      NativeNetworkProtocol.sendMessageV2Command(
        commandId: 'message-v2',
        peerId: 'peer-a',
        messageId: 'message-a',
        channelId: 'channel-a',
        payload: payload,
        deliveryPolicy: 3,
        e2eePolicy: NativeE2eePolicy.disabled,
      ),
      NativeNetworkProtocol.upsertPeerV2Command(
        commandId: 'upsert',
        config: config,
      ),
      NativeNetworkProtocol.removePeerCommand(
        commandId: 'remove',
        peerId: 'peer-a',
      ),
      NativeNetworkProtocol.transferCommand(
        commandId: 'transfer',
        peerId: 'peer-a',
        transferId: 'transfer-a',
        filePath: '/tmp/file.bin',
        confirmedOffset: 42,
        resume: true,
      ),
      NativeNetworkProtocol.peerDiagnosticsCommand(
        commandId: 'diagnostics',
        peerId: 'peer-a',
      ),
      NativeNetworkProtocol.networkEnvironmentChangedCommand(
        commandId: 'environment',
        generation: 9,
        hasConnectivity: true,
        isForeground: false,
        isMetered: true,
      ),
      NativeNetworkProtocol.sendFileCommand(
        commandId: 'file',
        peerId: 'peer-a',
        transferId: 'transfer-a',
        filePath: '/tmp/file.bin',
      ),
      NativeNetworkProtocol.cancelTransferCommand(
        commandId: 'cancel',
        transferId: 'transfer-a',
      ),
      NativeNetworkProtocol.startRealtimeSessionCommand(
        commandId: 'realtime-start',
        realtimeId: realtimeId,
        peerId: 'peer-a',
      ),
      NativeNetworkProtocol.stopRealtimeSessionCommand(
        commandId: 'realtime-stop',
        realtimeId: realtimeId,
      ),
      NativeNetworkProtocol.sendRealtimeSignalCommand(
        commandId: 'signal',
        realtimeId: realtimeId,
        peerId: 'peer-a',
        kind: NativeRealtimeSignalKind.webRtcOffer,
        revision: 1,
        payload: payload,
      ),
      NativeNetworkProtocol.sshStreamOpenCommand(
        commandId: 'stream-open',
        peerId: 'peer-a',
        handle: handle,
        service: 'ssh-session',
      ),
      NativeNetworkProtocol.sshStreamDataCommand(
        commandId: 'stream-data',
        peerId: 'peer-a',
        handle: handle,
        data: payload,
      ),
      NativeNetworkProtocol.sshStreamCloseCommand(
        commandId: 'stream-close',
        peerId: 'peer-a',
        handle: handle,
      ),
    ];

    expect(commands, hasLength(17));
    for (final command in commands) {
      expect(command, isNotEmpty);
      expect(command, isA<Uint8List>());
    }
  });

  test('peer registration carries explicit route authorization flags', () {
    final encoded = NativeNetworkProtocol.upsertPeerV2Command(
      commandId: 'upsert-routes',
      config: NativePeerConfig(
        peerId: 'peer-a',
        endpointAddress: '',
        identityPublicKey: Uint8List(32),
        e2ePublicKey: Uint8List(32),
        allowDirect: true,
        allowRelay: true,
      ),
    );

    expect(_containsSubsequence(encoded, <int>[0x30, 0x01]), isTrue);
    expect(_containsSubsequence(encoded, <int>[0x38, 0x01]), isTrue);
  });

  test(
    'protocol decoder fails closed for malformed envelopes and unknown tags',
    () {
      expect(
        () => NativeNetworkProtocol.decodeEvent(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => NativeNetworkProtocol.decodeEvent(
          _event(
            21,
            _message(<List<int>>[_stringField(1, 'not-a-realtime-id')]),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        NativeNetworkProtocol.decodeEvent(
          _event(99, _message(<List<int>>[_varintField(1, 1)])),
        ),
        isNull,
      );
      expect(
        () => NativeNetworkProtocol.startRealtimeSessionCommand(
          commandId: 'invalid',
          realtimeId: 'GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG',
          peerId: 'peer-a',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => NativeNetworkProtocol.sendRealtimeSignalCommand(
          commandId: 'invalid-signal',
          realtimeId: realtimeId,
          peerId: 'peer-a',
          kind: NativeRealtimeSignalKind.unspecified,
          revision: 1,
          payload: Uint8List(0),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => NativeNetworkProtocol.sshStreamOpenCommand(
          commandId: 'bad-stream',
          peerId: 'peer-a',
          handle: NativeStreamHandle(openerDeviceId: 'device-a', streamId: 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'native enum wire mappings round-trip and default unknown values safely',
    () {
      for (final value in NativePeerConnectionState.values) {
        expect(NativePeerConnectionState.fromWire(value.wireValue), value);
      }
      for (final value in NativePeerState.values) {
        expect(NativePeerState.fromWire(value.wireValue), value);
      }
      for (final value in NativeRouteType.values) {
        expect(NativeRouteType.fromWire(value.wireValue), value);
      }
      for (final value in NativeRouteTopology.values) {
        expect(NativeRouteTopology.fromWire(value.wireValue), value);
      }
      for (final value in NativeRouteTransport.values) {
        expect(NativeRouteTransport.fromWire(value.wireValue), value);
      }
      for (final value in NativeRelayConnectionState.values) {
        expect(NativeRelayConnectionState.fromWire(value.wireValue), value);
      }
      for (final value in NativeRealtimeSessionState.values) {
        expect(NativeRealtimeSessionState.fromWire(value.wireValue), value);
      }
      for (final value in NativeRealtimeSignalKind.values) {
        expect(NativeRealtimeSignalKind.fromWire(value.wireValue), value);
      }
      for (final value in NativeRetryDisposition.values) {
        expect(NativeRetryDisposition.fromWire(value.wireValue), value);
      }
      for (final value in NativePeerPresenceState.values) {
        expect(NativePeerPresenceState.fromWire(value.wireValue), value);
      }
      expect(
        NativePeerConnectionState.fromWire(-1),
        NativePeerConnectionState.unspecified,
      );
      expect(NativePeerState.fromWire(-1), NativePeerState.offline);
      expect(NativeRouteType.fromWire(-1), NativeRouteType.unspecified);
      expect(NativeRouteTopology.fromWire(-1), NativeRouteTopology.unspecified);
      expect(
        NativeRouteTransport.fromWire(-1),
        NativeRouteTransport.unspecified,
      );
      expect(
        NativeRelayConnectionState.fromWire(-1),
        NativeRelayConnectionState.unspecified,
      );
      expect(
        NativeRealtimeSessionState.fromWire(-1),
        NativeRealtimeSessionState.unspecified,
      );
      expect(
        NativeRealtimeSignalKind.fromWire(-1),
        NativeRealtimeSignalKind.unspecified,
      );
      expect(
        NativeRetryDisposition.fromWire(-1),
        NativeRetryDisposition.unspecified,
      );
      expect(
        NativePeerPresenceState.fromWire(-1),
        NativePeerPresenceState.unspecified,
      );
    },
  );

  test(
    'command guards and bounded builders reject invalid ownership inputs',
    () {
      expect(
        () => NativeCommandResultGuard(maxPendingCommands: 0),
        throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
      );
      final guard = NativeCommandResultGuard();
      expect(() => guard.register(''), throwsArgumentError);
      expect(() => guard.register('x' * 129), throwsArgumentError);

      expect(
        () => NativeNetworkProtocol.sendMessageCommand(
          commandId: 'message',
          peerId: 'peer-a',
          channelId: '',
          payload: Uint8List(0),
        ),
        throwsArgumentError,
      );
      expect(
        () => NativeNetworkProtocol.sendMessageCommand(
          commandId: 'message',
          peerId: 'peer-a',
          channelId: 'channel-a',
          payload: Uint8List(384 * 1024 + 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => NativeNetworkProtocol.sendMessageV2Command(
          commandId: 'message-v2',
          peerId: 'peer-a',
          messageId: 'message-a',
          channelId: 'channel-a',
          payload: Uint8List(384 * 1024 + 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => NativeNetworkProtocol.transferCommand(
          commandId: 'transfer',
          peerId: 'peer-a',
          transferId: 'transfer-a',
          filePath: '/tmp/file.bin',
          confirmedOffset: -1,
        ),
        throwsArgumentError,
      );

      const handle = NativeStreamHandle(
        openerDeviceId: 'device-a',
        streamId: 7,
      );
      expect(
        handle ==
            const NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7),
        isTrue,
      );
      expect(
        handle.hashCode,
        const NativeStreamHandle(
          openerDeviceId: 'device-a',
          streamId: 7,
        ).hashCode,
      );
      final dataEvent = NativeSshStreamDataReceivedEvent(
        eventId: 'event',
        timestampMs: 1,
        protocolVersion: NativeNetworkProtocol.protocolVersion,
        peerId: 'peer-a',
        handle: handle,
        data: Uint8List.fromList(<int>[1]),
      );
      expect(dataEvent.openerDeviceId, 'device-a');
      expect(dataEvent.streamId, 7);
      const closedEvent = NativeSshStreamClosedEvent(
        eventId: 'event',
        timestampMs: 1,
        protocolVersion: NativeNetworkProtocol.protocolVersion,
        peerId: 'peer-a',
        handle: handle,
      );
      expect(closedEvent.openerDeviceId, 'device-a');
      expect(closedEvent.streamId, 7);
    },
  );
}

Uint8List _event(int payloadField, List<int> payload) =>
    Uint8List.fromList(<int>[
      ..._stringField(1, 'event-a'),
      ..._varintField(2, 42),
      ..._varintField(3, NativeNetworkProtocol.protocolVersion),
      ..._bytesField(payloadField, payload),
    ]);

List<int> _message(Iterable<List<int>> fields) => <int>[
  ...fields.expand((field) => field),
];

List<int> _stringField(int number, String value) =>
    _bytesField(number, value.codeUnits);

List<int> _bytesField(int number, List<int> value) => <int>[
  ..._varint(_wireTag(number, 2)),
  ..._varint(value.length),
  ...value,
];

List<int> _varintField(int number, int value) => <int>[
  ..._varint(_wireTag(number, 0)),
  ..._varint(value),
];

int _wireTag(int number, int wireType) => (number << 3) | wireType;

bool _containsSubsequence(List<int> bytes, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= bytes.length - needle.length; start++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (bytes[start + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) byte |= 0x80;
    bytes.add(byte);
  } while (remaining != 0);
  return bytes;
}
