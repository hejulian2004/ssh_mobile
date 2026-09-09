// Network Protocol V2 envelope and peer-event golden tests.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

/// 固定字节 envelope、命令结果和 peer 事件的 V2 编解码测试。
void main() {
  const codec = NetworkProtocolV2Codec();

  test('disconnect relay command matches the V2 golden bytes', () {
    final bytes = codec.disconnectRelayCommand(commandId: 'c');
    expect(bytes, <int>[0x0a, 0x01, 0x63, 0x10, 0x02, 0x92, 0x01, 0x00]);
    expect(codec.commandId(bytes), 'c');
  });

  test('connect peer command carries the communication class (field 3)', () {
    final reliableStream = codec.connectPeerCommand(
      commandId: 'c',
      peerId: 'p',
      communicationClass: CommunicationClass.reliableStream,
    );
    // 载荷：peer_id(1)=p、intent(2)=0、communication_class(3)=ReliableStream(1)。
    expect(reliableStream, <int>[
      0x0a, 0x01, 0x63, // command_id = c
      0x10, 0x02, // protocol_version = 2
      0x52, 0x07, // connect peer (field 10), length 7
      0x0a, 0x01, 0x70, // peer_id = p
      0x10, 0x00, // intent = 0
      0x18, 0x01, // communication_class = 1 (ReliableStream)
    ]);
    expect(codec.commandId(reliableStream), 'c');

    final bulk = codec.connectPeerCommand(
      commandId: 'c',
      peerId: 'p',
      communicationClass: CommunicationClass.bulkTransfer,
    );
    expect(bulk, contains(0x18)); // communication_class key
    expect(bulk, contains(0x03)); // BulkTransfer = 3
  });

  test('command result event decodes from fixed V2 bytes', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e，事件标识。
        0x10, 0x64, // timestamp_ms = 100，时间戳。
        0x18, 0x02, // protocol_version = 2，协议版本。
        0x6a, 0x05, // command_result message，命令结果消息。
        0x0a, 0x01, 0x63, // command_id = c，命令标识。
        0x10, 0x01, // accepted = true，命令已接受。
      ]),
    );

    expect(frame.eventId, 'e');
    expect(frame.protocolVersion, 2);
    expect(frame.commandId, 'c');
    expect(frame.commandAccepted, isTrue);
    expect(frame.event, isNull);
  });

  test('typed V2 command result event completes the pending command', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x02, // protocol_version = 2
        0xea, 0x01, 0x0a, // command_result_v2, length 10
        0x0a, 0x01, 0x63, // command_id = c
        0x12, 0x01, 0x70, // peer_id = p
        0x18, 0x01, // state = failed
        0x22, 0x00, // error is optional for the decoder contract
      ]),
    );

    expect(frame.commandId, 'c');
    expect(frame.commandAccepted, isFalse);
    expect(frame.commandError, isNotNull);
  });

  test('typed transfer failure preserves stable error context', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a,
        0x01,
        0x66,
        0x18,
        0x02,
        0x82,
        0x01,
        0x13,
        0x0a,
        0x01,
        0x74,
        0x12,
        0x0e,
        0x08,
        0x03,
        0x12,
        0x00,
        0x1a,
        0x04,
        0x73,
        0x65,
        0x6e,
        0x64,
        0x22,
        0x02,
        0x70,
        0x31,
      ]),
    );
    final event = frame.event;
    expect(event, isA<TransferFailed>());
    final failure = event! as TransferFailed;
    expect(failure.transferId, 't');
    expect(failure.error.code, NetworkErrorCode.noRoute);
    expect(failure.error.operation, NetworkOperation.send);
    expect(failure.error.peerId, 'p1');
  });

  test('incoming offer accepts optional Relay route metadata', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x02, // protocol_version = 2
        0x72, 0x0d, // incoming offer message
        0x0a, 0x01, 0x74, // transfer_id = t
        0x12, 0x01, 0x70, // peer_id = p
        0x1a, 0x01, 0x66, // file_name = f
        0x20, 0x03, // file_size = 3
        0x28, 0x02, // route_type = Relay
      ]),
    );

    expect(frame.event, isA<IncomingTransferOffer>());
    expect(
      (frame.event! as IncomingTransferOffer).routeType,
      NetworkRouteType.relay,
    );
  });

  test('error payload decodes retry disposition and retry-after seconds', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x66, // event_id = f
        0x10, 0x64, // timestamp_ms = 100
        0x18, 0x02, // protocol_version = 2
        0x82, 0x01, 0x14, // transfer failed message (len 20)
        0x0a, 0x01, 0x74, // transfer_id = t
        0x12, 0x0f, // error message (len 15)
        0x08, 0x0c, // code = 12 (credentialExpired)
        0x12, 0x07, 0x65, 0x78, 0x70, 0x69, 0x72, 0x65, 0x64, // 'expired'
        0x28, 0x04, // retry_disposition = 4 (refreshCredentialThenRetry)
        0x30, 0x1e, // retry_after_seconds = 30
      ]),
    );
    final event = frame.event! as TransferFailed;
    expect(event.error.code, NetworkErrorCode.credentialExpired);
    expect(event.error.message, 'expired');
    expect(
      event.error.retryDisposition,
      RetryDisposition.refreshCredentialThenRetry,
    );
    expect(event.error.retryAfterSeconds, 30);
  });

  test('peer and route events decode composed topology and transport', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x02, // protocol_version = 2
        0x52, 0x0b, // peer state message
        0x0a, 0x01, 0x70, // peer_id = p
        0x10, 0x02, // connected
        0x18, 0x00, // legacy flat route = unspecified
        0x28, 0x01, // topology = direct
        0x30, 0x02, // transport = tcp
      ]),
    );
    final event = frame.event! as PeerStateChanged;
    expect(event.routeType, NetworkRouteType.unspecified);
    expect(event.routeTopology, NetworkRouteTopology.direct);
    expect(event.routeTransport, NetworkRouteTransport.tcp);
  });

  test('peer presence change event decodes from V2 bytes', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x02, // protocol_version = 2
        0xc2, 0x01, 0x07, // field 24 (peer presence change), length 7
        0x0a, 0x01, 0x70, // peer_id = p
        0x10, 0x02, // generation = 2
        0x18, 0x01, // state = online
      ]),
    );
    final event = frame.event! as PeerPresenceChanged;
    expect(event.peerId, 'p');
    expect(event.generation, 2);
    expect(event.state, PeerPresenceState.online);
  });

  test('peer presence snapshot event decodes a peer list', () {
    final frame = codec.decodeEvent(
      Uint8List.fromList(<int>[
        0x0a, 0x01, 0x65, // event_id = e
        0x18, 0x02, // protocol_version = 2
        0xca, 0x01, 0x12, // field 25 (peer presence snapshot), length 18
        0x0a, 0x07, // peers[0] message, length 7
        0x0a, 0x01, 0x70, // peer_id = p
        0x10, 0x01, // generation = 1
        0x18, 0x01, // state = online
        0x0a, 0x07, // peers[1] message, length 7
        0x0a, 0x01, 0x71, // peer_id = q
        0x10, 0x03, // generation = 3
        0x18, 0x02, // state = updated
      ]),
    );
    final event = frame.event! as PeerPresenceSnapshot;
    expect(event.peers, hasLength(2));
    expect(event.peers.first.peerId, 'p');
    expect(event.peers.first.state, PeerPresenceState.online);
    expect(event.peers.last.peerId, 'q');
    expect(event.peers.last.generation, 3);
    expect(event.peers.last.state, PeerPresenceState.updated);
  });

  test(
    'screen-share consent uses the current schema on the App wire',
    () {
      final issued = DateTime.utc(2026, 1, 1, 12);
      final consent = RealtimeConsent(
        operationId: 'operation-a',
        realtimeId: '00112233445566778899aabbccddeeff',
        issuedAt: issued,
        expiresAt: issued.add(const Duration(minutes: 1)),
        decision: RealtimeConsentDecision.request,
        senderPeerId: 'peer-a',
        actionRevision: 1,
      );
      final payload = codec.encodeScreenShareConsent(consent);
      expect(codec.decodeScreenShareConsent(payload), consent);

      final signal = <int>[
        ..._stringField(1, consent.realtimeId),
        ..._stringField(2, 'peer-a'),
        ..._varintField(3, 6),
        ..._varintField(4, 1),
        ..._bytesField(5, payload),
      ];
      final frame = codec.decodeEvent(
        Uint8List.fromList(<int>[
          ..._stringField(1, 'event-a'),
          ..._varintField(3, 2),
          ..._bytesField(22, signal),
        ]),
      );
      expect(frame.screenShareConsent, consent);
    },
  );
}

List<int> _stringField(int number, String value) =>
    _bytesField(number, utf8.encode(value));

List<int> _bytesField(int number, List<int> value) => <int>[
  ..._varint(number << 3 | 2),
  ..._varint(value.length),
  ...value,
];

List<int> _varintField(int number, int value) => <int>[
  ..._varint(number << 3),
  ..._varint(value),
];

List<int> _varint(int value) {
  final output = <int>[];
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) byte |= 0x80;
    output.add(byte);
  } while (remaining != 0);
  return output;
}
