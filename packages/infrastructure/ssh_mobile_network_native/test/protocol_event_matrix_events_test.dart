import 'dart:typed_data';

import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:test/test.dart';

void main() {
  const realtimeId = '00112233445566778899aabbccddeeff';

  test('all V2 event families decode their bounded fields and errors', () {
    final error = _message(<List<int>>[
      _varintField(1, 7),
      _stringField(2, 'failed'),
      _stringField(3, 'connect'),
      _stringField(4, 'peer-a'),
      _varintField(5, NativeRetryDisposition.retryAfter.wireValue),
      _varintField(6, 5),
    ]);
    final streamHandle = _message(<List<int>>[
      _stringField(1, 'device-a'),
      _varintField(2, 7),
    ]);
    final presence = _message(<List<int>>[
      _stringField(1, 'peer-a'),
      _varintField(2, 4),
      _varintField(3, NativePeerPresenceState.updated.wireValue),
    ]);
    final eventPayloads = <int, List<int>>{
      10: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _varintField(2, NativePeerConnectionState.connected.wireValue),
        _varintField(3, NativeRouteType.quicDirect.wireValue),
        _bytesField(4, error),
        _varintField(5, NativeRouteTopology.direct.wireValue),
        _varintField(6, NativeRouteTransport.quic.wireValue),
      ]),
      11: _message(<List<int>>[
        _stringField(1, 'transfer-a'),
        _varintField(2, 42),
        _varintField(3, 100),
      ]),
      13: _message(<List<int>>[
        _stringField(1, 'legacy-command'),
        _varintField(2, 1),
        _bytesField(3, error),
      ]),
      14: _message(<List<int>>[
        _stringField(1, 'transfer-a'),
        _stringField(2, 'peer-a'),
        _stringField(3, 'file.bin'),
        _varintField(4, 1024),
        _varintField(5, NativeRouteType.relay.wireValue),
      ]),
      15: _message(<List<int>>[
        _stringField(1, 'transfer-a'),
        _stringField(2, '/tmp/file.bin'),
      ]),
      16: _message(<List<int>>[
        _stringField(1, 'transfer-a'),
        _bytesField(2, error),
      ]),
      18: _message(<List<int>>[
        _varintField(1, NativeRelayConnectionState.connected.wireValue),
        _bytesField(2, error),
      ]),
      19: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _stringField(2, 'session-a'),
        _stringField(3, 'channel-a'),
        _bytesField(4, <int>[1, 2, 3]),
        _varintField(5, 8),
        _bytesField(7, <int>[4, 5]),
      ]),
      20: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _stringField(2, 'session-a'),
        _bytesField(3, <int>[1, 2, 3]),
        _varintField(4, 9),
      ]),
      21: _message(<List<int>>[
        _stringField(1, realtimeId),
        _stringField(2, 'peer-a'),
        _varintField(3, NativeRealtimeSessionState.connected.wireValue),
        _varintField(4, 3),
        _bytesField(5, error),
        _varintField(6, 1),
        _stringField(7, realtimeId),
      ]),
      22: _message(<List<int>>[
        _stringField(1, realtimeId),
        _stringField(2, 'peer-a'),
        _varintField(3, NativeRealtimeSignalKind.webRtcAnswer.wireValue),
        _varintField(4, 4),
        _bytesField(5, <int>[6, 7]),
      ]),
      23: _message(<List<int>>[
        _stringField(1, realtimeId),
        _stringField(2, 'peer-a'),
        _varintField(3, NativeRealtimeSessionState.negotiating.wireValue),
        _varintField(4, 5),
        _bytesField(5, error),
        _varintField(6, 1),
        _stringField(7, realtimeId),
      ]),
      24: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _varintField(2, 10),
        _varintField(3, NativePeerPresenceState.online.wireValue),
      ]),
      25: _message(<List<int>>[_bytesField(1, presence)]),
      28: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _varintField(2, NativePeerState.online.wireValue),
        _varintField(3, NativeE2eePolicy.disabled.wireValue),
        _bytesField(4, error),
      ]),
      29: _message(<List<int>>[
        _stringField(1, 'command-v2'),
        _stringField(2, 'peer-a'),
        _varintField(3, 1),
        _bytesField(4, error),
      ]),
      30: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _varintField(2, NativePeerState.online.wireValue),
        _varintField(3, NativeE2eePolicy.disabled.wireValue),
        _varintField(4, 1),
        _varintField(5, 2),
        _varintField(6, 3),
        _varintField(7, 4),
        _bytesField(8, error),
      ]),
      31: _message(<List<int>>[
        _varintField(1, 12),
        _varintField(2, 1),
        _varintField(3, 1),
        _varintField(4, 0),
      ]),
      32: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _stringField(2, 'transfer-a'),
        _varintField(3, 10),
        _varintField(4, 100),
        _varintField(5, 1),
      ]),
      33: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _stringField(2, 'attempt-a'),
        _varintField(3, NativeRouteAttemptPhase.relayFallbackStarted.wireValue),
        _varintField(4, NativeRouteType.relay.wireValue),
        _bytesField(5, error),
        _stringField(6, 'command-a'),
      ]),
      26: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _bytesField(2, streamHandle),
        _bytesField(3, <int>[8, 9]),
      ]),
      27: _message(<List<int>>[
        _stringField(1, 'peer-a'),
        _bytesField(2, streamHandle),
      ]),
    };

    final decoded = <int, NativeNetworkEvent?>{
      for (final entry in eventPayloads.entries)
        entry.key: NativeNetworkProtocol.decodeEvent(
          _event(entry.key, entry.value),
        ),
    };

    expect(decoded[10], isA<NativePeerStateChangedEvent>());
    expect(decoded[11], isA<NativeTransferProgressEvent>());
    expect(decoded[13], isA<NativeCommandResultEvent>());
    expect(decoded[14], isA<NativeIncomingTransferOfferEvent>());
    expect(decoded[15], isA<NativeTransferCompletedEvent>());
    expect(decoded[16], isA<NativeTransferFailedEvent>());
    expect(decoded[18], isA<NativeRelayStateChangedEvent>());
    expect(decoded[19], isA<NativeChannelMessageEvent>());
    expect(decoded[20], isA<NativeDeliveryAckedEvent>());
    expect(decoded[21], isA<NativeRealtimeStateChangedEvent>());
    expect(decoded[22], isA<NativeRealtimeSignalEvent>());
    expect(decoded[23], isA<NativeRealtimeSnapshotEvent>());
    expect(decoded[24], isA<NativePeerPresenceChangedEvent>());
    expect(decoded[25], isA<NativePeerPresenceSnapshotEvent>());
    expect(decoded[26], isA<NativeSshStreamDataReceivedEvent>());
    expect(decoded[27], isA<NativeSshStreamClosedEvent>());
    expect(decoded[28], isA<NativePeerLifecycleEvent>());
    expect(decoded[29], isA<NativeCommandResultV2Event>());
    expect(decoded[30], isA<NativePeerDiagnosticsEvent>());
    expect(decoded[31], isA<NativeNetworkEnvironmentChangedEvent>());
    expect(decoded[32], isA<NativePeerTransferProgressEvent>());
    expect(decoded[33], isA<NativeRouteAttemptChangedEvent>());

    final routeAttempt = decoded[33]! as NativeRouteAttemptChangedEvent;
    expect(routeAttempt.peerId, 'peer-a');
    expect(routeAttempt.attemptId, 'attempt-a');
    expect(routeAttempt.phase, NativeRouteAttemptPhase.relayFallbackStarted);
    expect(routeAttempt.routeType, NativeRouteType.relay);
    expect(routeAttempt.error?.code, 7);
    expect(routeAttempt.commandId, 'command-a');

    final diagnostics = decoded[30]! as NativePeerDiagnosticsEvent;
    expect(diagnostics.activeTransferCount, 4);
    expect(diagnostics.lastError?.retryAfterSeconds, 5);
    final signal = decoded[22]! as NativeRealtimeSignalEvent;
    expect(signal.payload, orderedEquals(<int>[6, 7]));
    final realtimeState = decoded[21]! as NativeRealtimeStateChangedEvent;
    expect(realtimeState.generation, 1);
    expect(realtimeState.sharedSessionInstanceId, realtimeId);
    final realtimeSnapshot = decoded[23]! as NativeRealtimeSnapshotEvent;
    expect(realtimeSnapshot.generation, 1);
    expect(realtimeSnapshot.sharedSessionInstanceId, realtimeId);
    final presenceSnapshot = decoded[25]! as NativePeerPresenceSnapshotEvent;
    expect(presenceSnapshot.peers.single.generation, 4);
  });

  test('screen-share consent encodes and decodes through realtime signal', () {
    final consent = NativeScreenShareConsent(
      schemaVersion: 2,
      operationId: 'operation-a',
      realtimeId: realtimeId,
      sharedSessionInstanceId: realtimeId,
      issuedAtMs: 1_735_732_800_000,
      expiresAtMs: 1_735_732_860_000,
      decision: NativeScreenShareConsentDecision.request,
      senderPeerId: 'peer-a',
      purpose: NativeScreenShareConsentPurpose.screenShare,
      media: NativeScreenShareMediaKind.screenVideo,
      requiresAcceptance: true,
      actionRevision: 1,
    );
    final payload = NativeNetworkProtocol.encodeScreenShareConsent(consent);
    final signal = _message(<List<int>>[
      _stringField(1, realtimeId),
      _stringField(2, 'peer-a'),
      _varintField(3, NativeRealtimeSignalKind.screenShareConsent.wireValue),
      _varintField(4, 1),
      _bytesField(5, payload),
    ]);
    final decoded = NativeNetworkProtocol.decodeEvent(_event(22, signal));
    expect(decoded, isA<NativeRealtimeSignalEvent>());
    final event = decoded! as NativeRealtimeSignalEvent;
    expect(event.kind, NativeRealtimeSignalKind.screenShareConsent);
    expect(event.consent?.operationId, 'operation-a');
    expect(event.consent?.sharedSessionInstanceId, realtimeId);
    expect(event.consent?.decision, NativeScreenShareConsentDecision.request);
  });

  test('screen-share consent rejects a realtime-id mismatch', () {
    final payload = NativeNetworkProtocol.encodeScreenShareConsent(
      const NativeScreenShareConsent(
        schemaVersion: 2,
        operationId: 'operation-a',
        realtimeId: realtimeId,
        sharedSessionInstanceId: realtimeId,
        issuedAtMs: 1_735_732_800_000,
        expiresAtMs: 1_735_732_860_000,
        decision: NativeScreenShareConsentDecision.request,
        senderPeerId: 'peer-a',
        purpose: NativeScreenShareConsentPurpose.screenShare,
        media: NativeScreenShareMediaKind.screenVideo,
        requiresAcceptance: true,
        actionRevision: 1,
      ),
    );
    final signal = _message(<List<int>>[
      _stringField(1, 'ffeeddccbbaa99887766554433221100'),
      _stringField(2, 'peer-a'),
      _varintField(3, NativeRealtimeSignalKind.screenShareConsent.wireValue),
      _varintField(4, 1),
      _bytesField(5, payload),
    ]);
    expect(
      () => NativeNetworkProtocol.decodeEvent(_event(22, signal)),
      throwsFormatException,
    );
  });
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
