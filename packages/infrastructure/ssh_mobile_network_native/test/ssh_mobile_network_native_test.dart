// 原生网络 package 的 Network Protocol V2 与独立 C ABI 生命周期测试。

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// 执行 Network Protocol V2 与 C ABI 生命周期测试。
void main() {
  const native = SshMobileNetworkNative();

  test('SshMobileNetworkNative ABI version check', () {
    expect(native.getAbiVersion(), equals(1));
  });

  test('NativeNetworkRuntime lifecycle uses typed status', () async {
    final runtime = await native.createRuntime();
    expect(
      runtime.sendCommand(Uint8List(0)),
      NativeOperationStatus.invalidArgument,
    );
    expect(await runtime.stop(), NativeOperationStatus.success);
    expect(
      runtime.sendCommand(Uint8List.fromList(<int>[0x00])),
      NativeOperationStatus.stopped,
    );
    await runtime.dispose();
  });

  test(
    'media endpoint controls are opaque and stop with their runtime',
    () async {
      final runtime = await native.createRuntime();
      const realtimeId = '00112233445566778899aabbccddeeff';

      expect(
        runtime
            .createRealtimeMediaEndpoint(
              realtimeId: 'invalid',
              peerId: 'peer-a',
              direction: NativeRealtimeMediaDirection.send,
              generation: 1,
            )
            .status,
        NativeOperationStatus.invalidArgument,
      );
      expect(
        runtime
            .createRealtimeMediaEndpoint(
              realtimeId: realtimeId,
              peerId: 'peer-a',
              direction: NativeRealtimeMediaDirection.send,
              generation: 1,
            )
            .status,
        NativeOperationStatus.unknownSession,
      );
      expect(
        runtime
            .createRealtimeMediaEndpoint(
              realtimeId: realtimeId,
              peerId: 'peer-a',
              direction: NativeRealtimeMediaDirection.send,
              generation: 0,
            )
            .status,
        NativeOperationStatus.invalidArgument,
      );
      expect(await runtime.stop(), NativeOperationStatus.success);
      expect(
        runtime
            .createRealtimeMediaEndpoint(
              realtimeId: realtimeId,
              peerId: 'peer-a',
              direction: NativeRealtimeMediaDirection.receive,
              generation: 1,
            )
            .status,
        NativeOperationStatus.stopped,
      );
      expect(
        runtime.releaseRealtimeMediaEndpoint(NativeRealtimeMediaEndpointId(1)),
        NativeOperationStatus.success,
      );
      await runtime.dispose();
    },
  );

  test('native runtime polls events on a helper isolate', () async {
    final runtime = await native.createRuntime();
    addTearDown(runtime.dispose);

    final eventFuture = runtime.rawEvents.first.timeout(
      const Duration(seconds: 2),
    );
    final command = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'cmd'.codeUnits,
      0x10,
      0x02,
    ]);
    expect(runtime.sendCommand(command), NativeOperationStatus.success);
    expect(await eventFuture, isNotEmpty);
  });

  test(
    'Realtime command result crosses the real native FFI boundary',
    () async {
      const commandId = 'realtime-start-ffi-result';
      const peerId = 'missing-peer';
      final runtime = await native.createRuntime();
      addTearDown(runtime.dispose);

      final rawResultFuture = runtime.rawEvents.first.timeout(
        const Duration(seconds: 5),
      );
      final command = NativeNetworkProtocol.startRealtimeSessionCommand(
        commandId: commandId,
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: peerId,
      );

      expect(runtime.sendCommand(command), NativeOperationStatus.success);
      final result = NativeNetworkProtocol.decodeEvent(await rawResultFuture);
      expect(result, isA<NativeCommandResultV2Event>());
      final commandResult = result! as NativeCommandResultV2Event;
      expect(commandResult.commandId, commandId);
      expect(commandResult.peerId, peerId);
      expect(commandResult.state, 1); // COMMAND_RESULT_STATE_FAILED
      expect(commandResult.error?.code, 3); // NETWORK_ERROR_CODE_NO_ROUTE
    },
  );

  test('native runtime stops before it is destroyed', () async {
    final runtime = await native.createRuntime();
    final status = await runtime.stop();
    expect(status, NativeOperationStatus.success);
    expect(
      runtime.sendCommand(Uint8List.fromList(<int>[0x00])),
      NativeOperationStatus.stopped,
    );
    await runtime.dispose();
  });

  test('concurrent stop and dispose preserve one ordered lifecycle', () async {
    final runtime = await native.createRuntime();
    final disposeFuture = runtime.dispose();
    final stopFuture = runtime.stop();
    final secondDisposeFuture = runtime.dispose();

    expect(await stopFuture, NativeOperationStatus.success);
    await disposeFuture;
    await secondDisposeFuture;
    expect(
      runtime.sendCommand(Uint8List.fromList(<int>[0x00])),
      NativeOperationStatus.stopped,
    );
    await runtime.dispose();
  });

  test('CommandResult guard admits one terminal result per command', () {
    final guard = NativeCommandResultGuard(maxPendingCommands: 1);
    const result = NativeCommandResultEvent(
      eventId: 'result-1',
      timestampMs: 1,
      protocolVersion: NativeNetworkProtocol.protocolVersion,
      commandId: 'command-1',
      accepted: true,
    );

    expect(guard.register('command-1'), isTrue);
    expect(guard.register('command-1'), isFalse);
    expect(guard.register('command-2'), isFalse);
    expect(guard.filterEvent(result), same(result));
    expect(guard.pendingCount, 0);
    expect(guard.filterEvent(result), isNull);

    const stateEvent = NativePeerStateChangedEvent(
      eventId: 'state-1',
      timestampMs: 2,
      protocolVersion: NativeNetworkProtocol.protocolVersion,
      peerId: 'peer-a',
      state: NativePeerConnectionState.connected,
      routeType: NativeRouteType.quicDirect,
    );
    expect(guard.filterEvent(stateEvent), same(stateEvent));

    guard.cancel('command-2');
    expect(guard.register('command-2'), isTrue);
    guard.clear();
    expect(guard.pendingCount, 0);
  });

  test(
    'Realtime commands and typed events stay behind the native facade',
    () async {
      const realtimeId = '00112233445566778899aabbccddeeff';
      final runtime = await native.createRuntime();
      addTearDown(runtime.dispose);

      expect(
        runtime.startRealtimeSession(realtimeId: realtimeId, peerId: 'peer-a'),
        NativeOperationStatus.success,
      );

      // The native command is asynchronous and may remain pending while the
      // WebRTC driver is negotiating. Decode the deterministic V2 result
      // envelope here instead of coupling this contract test to ICE timing.
      final result =
          NativeNetworkProtocol.decodeEvent(
                Uint8List.fromList(<int>[
                  0x0a,
                  0x03,
                  ...'evt'.codeUnits,
                  0x10,
                  0x01,
                  0x18,
                  0x02,
                  0xea,
                  0x01,
                  0x13,
                  0x0a,
                  0x07,
                  ...'command'.codeUnits,
                  0x12,
                  0x06,
                  ...'peer-a'.codeUnits,
                  0x18,
                  0x01,
                ]),
              )!
              as NativeCommandResultV2Event;
      expect(result.state, 1);
      expect(result.commandId, 'command');
      expect(result.peerId, 'peer-a');
      expect(
        runtime.sendRealtimeSignal(
          realtimeId: 'INVALID',
          peerId: 'peer-a',
          kind: NativeRealtimeSignalKind.webRtcOffer,
          revision: 1,
          payload: Uint8List.fromList(<int>[118, 61, 48]),
        ),
        NativeOperationStatus.invalidArgument,
      );
    },
  );

  test('Realtime event decoder preserves bounded signaling payloads', () {
    final nested = <int>[
      0x0a,
      0x20,
      ...'00112233445566778899aabbccddeeff'.codeUnits,
      0x12,
      0x06,
      ...'peer-a'.codeUnits,
      0x18,
      NativeRealtimeSignalKind.webRtcOffer.wireValue,
      0x20,
      0x01,
      0x2a,
      0x05,
      0x76,
      0x3d,
      0x30,
      0x0d,
      0x0a,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x02,
      0xb2,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeRealtimeSignalEvent>());
    final signal = event! as NativeRealtimeSignalEvent;
    expect(signal.realtimeId, equals('00112233445566778899aabbccddeeff'));
    expect(signal.kind, NativeRealtimeSignalKind.webRtcOffer);
    expect(signal.payload, orderedEquals(<int>[118, 61, 48, 13, 10]));
  });

  test('Realtime V2 protocol keeps ICE end-of-candidates semantics', () {
    expect(
      NativeNetworkProtocol.sendRealtimeSignalCommand(
        commandId: 'ice-end',
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        kind: NativeRealtimeSignalKind.iceCandidate,
        revision: 2,
        payload: Uint8List(0),
      ),
      isNotEmpty,
    );

    expect(
      () => NativeNetworkProtocol.decodeEvent(
        Uint8List.fromList(<int>[
          0x0a,
          0x03,
          ...'evt'.codeUnits,
          0x10,
          0x01,
          0x18,
          0x01,
        ]),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('Realtime snapshot event round-trips state and revision (tag 23)', () {
    final nested = <int>[
      0x0a,
      0x20,
      ...'00112233445566778899aabbccddeeff'.codeUnits,
      0x12,
      0x06,
      ...'peer-a'.codeUnits,
      0x18,
      NativeRealtimeSessionState.connected.wireValue,
      0x20,
      0x07,
      0x30,
      0x01,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x02,
      0xba,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeRealtimeSnapshotEvent>());
    final snapshot = event! as NativeRealtimeSnapshotEvent;
    expect(snapshot.realtimeId, equals('00112233445566778899aabbccddeeff'));
    expect(snapshot.peerId, equals('peer-a'));
    expect(snapshot.state, NativeRealtimeSessionState.connected);
    expect(snapshot.revision, 7);
    expect(snapshot.generation, 1);
    expect(snapshot.error, isNull);
  });

  test('Realtime snapshot decodes nested NetworkError with retry fields', () {
    final errorNested = <int>[
      0x08,
      12,
      0x12,
      0x03,
      ...'exp'.codeUnits,
      0x28,
      4,
      0x30,
      30,
    ];
    final nested = <int>[
      0x0a,
      0x20,
      ...'00112233445566778899aabbccddeeff'.codeUnits,
      0x12,
      0x06,
      ...'peer-a'.codeUnits,
      0x18,
      NativeRealtimeSessionState.failed.wireValue,
      0x20,
      0x03,
      0x30,
      0x01,
      0x2a,
      errorNested.length,
      ...errorNested,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x02,
      0xba,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    final snapshot = event! as NativeRealtimeSnapshotEvent;
    expect(snapshot.state, NativeRealtimeSessionState.failed);
    expect(snapshot.revision, 3);
    expect(snapshot.generation, 1);
    expect(snapshot.error, isNotNull);
    expect(snapshot.error!.code, 12);
    expect(
      snapshot.error!.retryDisposition,
      NativeRetryDisposition.refreshCredentialThenRetry,
    );
    expect(snapshot.error!.retryAfterSeconds, 30);
  });

  test('NetworkError decode preserves retry disposition and retry-after', () {
    final errorNested = <int>[
      0x08,
      12,
      0x12,
      0x03,
      ...'exp'.codeUnits,
      0x28,
      4,
      0x30,
      30,
    ];
    final nested = <int>[
      0x0a,
      0x03,
      ...'cmd'.codeUnits,
      0x10,
      0x00,
      0x1a,
      errorNested.length,
      ...errorNested,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x02,
      0x6a,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeCommandResultEvent>());
    final result = event! as NativeCommandResultEvent;
    expect(result.accepted, isFalse);
    expect(result.error, isNotNull);
    expect(result.error!.code, 12);
    expect(
      result.error!.retryDisposition,
      NativeRetryDisposition.refreshCredentialThenRetry,
    );
    expect(result.error!.retryAfterSeconds, 30);
  });

  test('SSH stream commands encode into tags 25/26/27', () {
    final open = NativeNetworkProtocol.sshStreamOpenCommand(
      commandId: 'open-1',
      peerId: 'peer-a',
      handle: const NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7),
      service: 'ssh',
    );
    expect(open, isNotEmpty);
    expect(open, contains(0xca)); // field 25 key prefix
    expect(open, contains(0x07)); // stream_id = 7

    final data = NativeNetworkProtocol.sshStreamDataCommand(
      commandId: 'data-1',
      peerId: 'peer-a',
      handle: const NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7),
      data: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
    );
    expect(data, isNotEmpty);
    expect(data, contains(0xd2)); // field 26 key prefix
    expect(data, contains(0xde));
    expect(data, contains(0xef));

    final close = NativeNetworkProtocol.sshStreamCloseCommand(
      commandId: 'close-1',
      peerId: 'peer-a',
      handle: const NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7),
    );
    expect(close, isNotEmpty);
    expect(close, contains(0xda)); // field 27 key prefix
  });

  test('SSH stream data received event decodes from tag 26', () {
    final nested = <int>[
      0x0a, 0x06, ...'peer-a'.codeUnits, // peer_id = peer-a
      0x12, 0x0c, // handle
      0x0a, 0x08, ...'device-a'.codeUnits,
      0x10, 0x07,
      0x1a, 0x04, 0x01, 0x02, 0x03, 0x04, // data
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x02,
      0xd2,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeSshStreamDataReceivedEvent>());
    final stream = event! as NativeSshStreamDataReceivedEvent;
    expect(stream.peerId, 'peer-a');
    expect(
      stream.handle,
      const NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7),
    );
    expect(stream.data, orderedEquals([1, 2, 3, 4]));
  });

  test('SSH stream closed event decodes from tag 27', () {
    final nested = <int>[
      0x0a, 0x06, ...'peer-a'.codeUnits,
      0x12, 0x0c, // handle
      0x0a, 0x08, ...'device-a'.codeUnits,
      0x10, 0x07,
    ];
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x02,
      0xda,
      0x01,
      nested.length,
      ...nested,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isA<NativeSshStreamClosedEvent>());
    final closed = event! as NativeSshStreamClosedEvent;
    expect(closed.peerId, 'peer-a');
    expect(
      closed.handle,
      const NativeStreamHandle(openerDeviceId: 'device-a', streamId: 7),
    );
  });

  test('SSH stream commands reject invalid stream ids and services', () {
    expect(
      () => NativeNetworkProtocol.sshStreamOpenCommand(
        commandId: 'c',
        peerId: 'peer-a',
        handle: const NativeStreamHandle(
          openerDeviceId: 'device-a',
          streamId: 0,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => NativeNetworkProtocol.sshStreamOpenCommand(
        commandId: 'c',
        peerId: 'peer-a',
        handle: const NativeStreamHandle(
          openerDeviceId: 'device-a',
          streamId: 7,
        ),
        service: '',
      ),
      throwsArgumentError,
    );
  });

  test('unknown future realtime event tag is ignored', () {
    final frame = Uint8List.fromList(<int>[
      0x0a,
      0x03,
      ...'evt'.codeUnits,
      0x10,
      0x7b,
      0x18,
      0x02,
      // Field 50 is intentionally outside the current event union.
      0x92,
      0x03,
      0x02,
      0x08,
      0x01,
    ]);

    final event = NativeNetworkProtocol.decodeEvent(frame);
    expect(event, isNull);
  });

  test(
    'typed runtime command facade covers peer, message, transfer, and lifecycle boundaries',
    () async {
      final runtime = await native.createRuntime();
      addTearDown(runtime.dispose);
      final peerConfig = NativePeerConfig(
        peerId: 'peer-a',
        endpointAddress: 'quic://127.0.0.1:443',
        identityPublicKey: Uint8List(32),
        e2ePublicKey: Uint8List(32),
        e2eePolicy: NativeE2eePolicy.disabled,
      );

      expect(runtime.boundLocalPort, isA<int?>());
      expect(runtime.upsertPeerV2(peerConfig), NativeOperationStatus.success);
      expect(
        runtime.removePeerV2(peerId: 'peer-a'),
        NativeOperationStatus.success,
      );
      expect(
        runtime.sendMessageV2(
          peerId: 'peer-a',
          messageId: 'message-a',
          channelId: 'channel-a',
          payload: Uint8List.fromList(<int>[1, 2]),
          e2eePolicy: NativeE2eePolicy.disabled,
        ),
        NativeOperationStatus.success,
      );
      expect(
        runtime.transferV2(
          peerId: 'peer-a',
          transferId: 'transfer-a',
          filePath: '/tmp/file.bin',
          confirmedOffset: 2,
          resume: true,
        ),
        NativeOperationStatus.success,
      );
      expect(
        runtime.sendMessageV2(
          peerId: '',
          messageId: 'message-a',
          channelId: 'channel-a',
          payload: Uint8List(0),
        ),
        NativeOperationStatus.invalidArgument,
      );
      expect(
        runtime.stopRealtimeSession(realtimeId: ''),
        NativeOperationStatus.invalidArgument,
      );
      await runtime.stop();
      expect(runtime.boundLocalPort, isNull);
      expect(runtime.upsertPeerV2(peerConfig), NativeOperationStatus.stopped);
    },
  );
}
