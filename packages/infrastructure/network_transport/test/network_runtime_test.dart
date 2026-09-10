// NetworkRuntime 的并发初始化、失败重试和资源释放测试。
//
// 测试使用 Fake NativeNetworkAdapter，避免单元测试必须加载真实平台的 FFI
// 动态库，同时验证 Runtime 对 native handle 的 Owner 责任。

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

void main() {
  test(
    'Capability initialization is lazy and concurrent calls share native init',
    () async {
      final creation = Completer<NativeNetworkHandle>();
      final adapter = _FakeNativeNetworkAdapter(() => creation.future);
      final runtime = NetworkRuntimeImpl(nativeAdapter: adapter);

      expect(adapter.createCalls, 0);
      final runtimeInitialization = runtime.ensureCapability(
        NetworkCapability.runtime,
      );
      final duplicateRuntimeInitialization = runtime.ensureCapability(
        NetworkCapability.runtime,
      );
      expect(
        identical(runtimeInitialization, duplicateRuntimeInitialization),
        isTrue,
      );
      final quicInitialization = runtime.ensureCapability(
        NetworkCapability.quic,
      );
      final relayInitialization = runtime.ensureCapability(
        NetworkCapability.webSocketRelay,
      );

      expect(adapter.createCalls, 1);
      expect(runtime.state, NetworkRuntimeState.starting);

      final handle = _FakeNativeNetworkHandle();
      creation.complete(handle);
      await Future.wait<void>(<Future<void>>[
        runtimeInitialization,
        quicInitialization,
        relayInitialization,
      ]);

      expect(runtime.state, NetworkRuntimeState.ready);
      expect(runtime.diagnostics.nativeHandles, 1);
      expect(runtime.diagnostics.boundLocalPort, 43123);
      expect(runtime.diagnostics.activeConnections, 0);
      expect(
        runtime.diagnostics.readyCapabilities,
        containsAll(<NetworkCapability>[
          NetworkCapability.runtime,
          NetworkCapability.quic,
          NetworkCapability.webSocketRelay,
        ]),
      );
      expect(runtime.isCapabilityReady(NetworkCapability.runtime), isTrue);
      expect(runtime.isCapabilityReady(NetworkCapability.quic), isTrue);
      expect(
        runtime.isCapabilityReady(NetworkCapability.webSocketRelay),
        isTrue,
      );
      await runtime.dispose();
      expect(handle.closeCalls, 1);
      expect(runtime.diagnostics.nativeHandles, 0);
      expect(runtime.diagnostics.boundLocalPort, isNull);
      expect(runtime.diagnostics.state, NetworkRuntimeState.disposed);
    },
  );

  test(
    'Capability failure is retryable and successful initialization is idempotent',
    () async {
      final handle = _FakeNativeNetworkHandle();
      final adapter = _FakeNativeNetworkAdapter(
        () async => throw StateError('first native initialization failed'),
      );
      final runtime = NetworkRuntimeImpl(nativeAdapter: adapter);

      try {
        await runtime.ensureCapability(NetworkCapability.quic);
        fail('Expected the first Capability initialization to fail.');
      } on StateError {
        // 失败后的 in-flight 状态必须被清除，下一次调用才能重试。
      }
      expect(runtime.state, NetworkRuntimeState.idle);

      adapter.nextCreation = () async => handle;
      await runtime.ensureCapability(NetworkCapability.quic);
      await runtime.ensureCapability(NetworkCapability.quic);
      expect(adapter.createCalls, 2);
      expect(runtime.isCapabilityReady(NetworkCapability.quic), isTrue);
      expect(runtime.diagnostics.readyCapabilities, [NetworkCapability.quic]);

      await runtime.dispose();
      expect(handle.closeCalls, 1);
    },
  );

  test('Unsupported capabilities fail without creating native resources', () {
    final adapter = _FakeNativeNetworkAdapter(
      () async => _FakeNativeNetworkHandle(),
    );
    final runtime = NetworkRuntimeImpl(nativeAdapter: adapter);

    expect(
      () => runtime.ensureCapability(NetworkCapability.tcp),
      throwsUnsupportedError,
    );
    expect(adapter.createCalls, 0);
  });

  test(
    'Disabled transport capabilities fail without creating native resources',
    () {
      final adapter = _FakeNativeNetworkAdapter(
        () async => _FakeNativeNetworkHandle(),
      );
      final runtime = NetworkRuntimeImpl(
        config: const NetworkConfig(enableQuic: false),
        nativeAdapter: adapter,
      );

      expect(
        () => runtime.ensureCapability(NetworkCapability.quic),
        throwsUnsupportedError,
      );
      expect(adapter.createCalls, 0);
    },
  );

  test(
    'Disabled runtime rejects command gateway without creating native resources',
    () async {
      final adapter = _FakeNativeNetworkAdapter(
        () async => _FakeNativeNetworkHandle(),
      );
      final runtime = NetworkRuntimeImpl(
        config: const NetworkConfig(enableRuntime: false),
        nativeAdapter: adapter,
      );

      expect(
        () => runtime.ensureCapability(NetworkCapability.runtime),
        throwsUnsupportedError,
      );
      await expectLater(
        runtime.openCommandGateway(),
        throwsA(isA<UnsupportedError>()),
      );
      expect(adapter.createCalls, 0);
      await runtime.dispose();
    },
  );

  test('Command gateway shares the Runtime-owned native handle', () async {
    final handle = _FakeNativeNetworkHandle();
    final runtime = NetworkRuntimeImpl(
      nativeAdapter: _FakeNativeNetworkAdapter(() async => handle),
    );

    final gateway = await runtime.openCommandGateway();

    expect(
      gateway.sendCommand(Uint8List.fromList(<int>[1])),
      TransportOperationStatus.success,
    );
    await runtime.dispose();
    expect(
      gateway.sendCommand(Uint8List.fromList(<int>[1])),
      TransportOperationStatus.stopped,
    );
    await expectLater(runtime.openCommandGateway(), throwsA(isA<StateError>()));
  });

  test(
    'Command gateway initializes the runtime without requiring QUIC',
    () async {
      final handle = _FakeNativeNetworkHandle();
      final runtime = NetworkRuntimeImpl(
        config: const NetworkConfig(
          enableQuic: false,
          enableWebSocketRelay: true,
        ),
        nativeAdapter: _FakeNativeNetworkAdapter(() async => handle),
      );

      final gateway = await runtime.openCommandGateway();
      await runtime.ensureCapability(NetworkCapability.webSocketRelay);

      expect(runtime.isCapabilityReady(NetworkCapability.runtime), isTrue);
      expect(runtime.isCapabilityReady(NetworkCapability.quic), isFalse);
      expect(
        gateway.sendCommand(Uint8List.fromList(<int>[1])),
        TransportOperationStatus.success,
      );
      expect(
        runtime.diagnostics.readyCapabilities,
        containsAll(<NetworkCapability>[
          NetworkCapability.runtime,
          NetworkCapability.webSocketRelay,
        ]),
      );
      await runtime.dispose();
      expect(handle.closeCalls, 1);
    },
  );

  test('Realtime gateway remains gated by the realtime capability', () async {
    final adapter = _FakeNativeNetworkAdapter(
      () async => _FakeNativeNetworkHandle(),
    );
    final runtime = NetworkRuntimeImpl(
      config: const NetworkConfig(enableRealtime: false),
      nativeAdapter: adapter,
    );

    await expectLater(
      runtime.openRealtimeGateway(),
      throwsA(isA<UnsupportedError>()),
    );
    expect(adapter.createCalls, 0);
    await runtime.dispose();
  });

  test('Realtime gateway shares the Runtime-owned native handle', () async {
    final handle = _FakeNativeNetworkHandle();
    final runtime = NetworkRuntimeImpl(
      nativeAdapter: _FakeNativeNetworkAdapter(() async => handle),
    );

    final gateway = await runtime.openRealtimeGateway();

    expect(runtime.isCapabilityReady(NetworkCapability.realtime), isTrue);
    final ticket = gateway.start(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    expect(ticket.queueStatus, NativeOperationStatus.success);
    expect(ticket.commandId, startsWith('realtime-start-'));
    await runtime.dispose();
    expect(
      gateway.stop(realtimeId: '00112233445566778899aabbccddeeff').queueStatus,
      NativeOperationStatus.stopped,
    );
  });

  test(
    'Realtime gateway maps native state events without exposing signaling',
    () async {
      final handle = _FakeNativeNetworkHandle();
      final runtime = NetworkRuntimeImpl(
        nativeAdapter: _FakeNativeNetworkAdapter(() async => handle),
      );
      final gateway = await runtime.openRealtimeGateway();
      final eventFuture = gateway.events.first;

      handle.emit(_connectedRealtimeStateFrame());
      final event = await eventFuture;

      expect(event, isA<NativeRealtimeStateChangedEvent>());
      final state = event as NativeRealtimeStateChangedEvent;
      expect(state.realtimeId, '00112233445566778899aabbccddeeff');
      expect(state.peerId, 'peer-a');
      expect(state.state, NativeRealtimeSessionState.connected);
      expect(state.sharedSessionInstanceId, '00112233445566778899aabbccddeeff');
      await runtime.dispose();
    },
  );

  test(
    'Realtime gateway drops duplicate and unknown command results',
    () async {
      final commandGateway = _FakeCommandGateway();
      final gateway = RuntimeNetworkRealtimeGateway(commandGateway);
      final events = <NativeNetworkEvent>[];
      final subscription = gateway.events.listen(events.add);

      final ticket = gateway.start(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      expect(ticket.queueStatus, NativeOperationStatus.success);

      final resultFrame = _commandResultFrame(ticket.commandId);
      commandGateway.emit(resultFrame);
      commandGateway.emit(resultFrame);
      commandGateway.emit(_commandResultFrame('not-registered'));
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<NativeCommandResultEvent>(), hasLength(1));
      expect(
        events.whereType<NativeCommandResultEvent>().single.commandId,
        ticket.commandId,
      );

      await subscription.cancel();
      await commandGateway.close();
    },
  );

  test(
    'Dispose waits for a pending native handle and rejects later use',
    () async {
      final creation = Completer<NativeNetworkHandle>();
      final adapter = _FakeNativeNetworkAdapter(() => creation.future);
      final runtime = NetworkRuntimeImpl(nativeAdapter: adapter);
      final initialization = runtime.ensureCapability(NetworkCapability.quic);
      final handle = _FakeNativeNetworkHandle();

      final disposeFuture = runtime.dispose();
      expect(runtime.state, NetworkRuntimeState.stopping);
      expect(identical(disposeFuture, runtime.dispose()), isTrue);

      creation.complete(handle);
      await initialization;
      await disposeFuture;

      expect(runtime.state, NetworkRuntimeState.disposed);
      expect(runtime.diagnostics.nativeHandles, 0);
      expect(runtime.isCapabilityReady(NetworkCapability.quic), isFalse);
      expect(handle.closeCalls, 1);
      expect(
        () => runtime.ensureCapability(NetworkCapability.quic),
        throwsStateError,
      );
    },
  );
}

/// 可控制 native 创建结果的测试 adapter。
final class _FakeNativeNetworkAdapter implements NativeNetworkAdapter {
  /// 创建一个返回 [initialCreation] 的 Fake。
  _FakeNativeNetworkAdapter(this._initialCreation);

  final Future<NativeNetworkHandle> Function() _initialCreation;
  Future<NativeNetworkHandle> Function()? nextCreation;
  int createCalls = 0;

  @override
  Future<NativeNetworkHandle> create() {
    createCalls += 1;
    final creation = nextCreation;
    if (creation != null) return creation();
    return _initialCreation();
  }
}

/// 记录 close 次数并提供空事件流的测试 handle。
final class _FakeNativeNetworkHandle implements NativeNetworkHandle {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  bool _closed = false;
  int closeCalls = 0;

  void emit(Uint8List frame) => _events.add(frame);

  @override
  Stream<Uint8List> get rawEvents => _events.stream;

  @override
  int? get boundLocalPort => _closed ? null : 43123;

  @override
  TransportOperationStatus sendCommand(Uint8List command) => _closed
      ? TransportOperationStatus.stopped
      : command.isEmpty
      ? TransportOperationStatus.invalidArgument
      : TransportOperationStatus.success;

  @override
  NativeRealtimeMediaEndpointCreateResult createMediaEndpoint({
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  }) => const NativeRealtimeMediaEndpointCreateResult(
    status: NativeOperationStatus.driverUnavailable,
  );

  @override
  NativeOperationStatus releaseMediaEndpoint(
    NativeRealtimeMediaEndpointId endpointId,
  ) => _closed
      ? NativeOperationStatus.success
      : NativeOperationStatus.staleEndpoint;

  @override
  NativeRealtimeMediaOwnerOpenResult openMediaOwner({
    required NativeRealtimeMediaEndpointId endpointId,
    required String realtimeId,
    required String peerId,
    required int generation,
    required NativeRealtimeMediaDirection direction,
  }) => const NativeRealtimeMediaOwnerOpenResult(
    status: NativeOperationStatus.driverUnavailable,
  );

  @override
  NativeOperationStatus closeMediaOwner(NativeRealtimeMediaOwnerToken token) =>
      NativeOperationStatus.success;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCalls += 1;
    await _events.close();
  }

  @override
  Future<void> dispose() => close();
}

final class _FakeCommandGateway implements NetworkCommandGateway {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast(sync: true);

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) => command.isEmpty
      ? TransportOperationStatus.invalidArgument
      : TransportOperationStatus.success;

  void emit(Uint8List frame) => _events.add(frame);

  Future<void> close() => _events.close();
}

Uint8List _connectedRealtimeStateFrame() {
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
    0x03,
    0x30,
    0x01,
    0x3a,
    0x20,
    ...'00112233445566778899aabbccddeeff'.codeUnits,
  ];
  return Uint8List.fromList(<int>[
    0x0a,
    0x03,
    ...'evt'.codeUnits,
    0x10,
    0x01,
    0x18,
    0x02,
    0xaa,
    0x01,
    nested.length,
    ...nested,
  ]);
}

Uint8List _commandResultFrame(String commandId) {
  final nested = <int>[
    0x0a,
    commandId.length,
    ...commandId.codeUnits,
    0x10,
    0x01,
  ];
  return Uint8List.fromList(<int>[
    0x0a,
    0x03,
    ...'evt'.codeUnits,
    0x10,
    0x01,
    0x18,
    0x02,
    0x6a,
    nested.length,
    ...nested,
  ]);
}
