import 'dart:typed_data';

import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:test/test.dart';

void main() {
  test('EventMux drains normal control and data fallback queues', () {
    final mux = EventMux<String>(
      maxConsecutiveControlEvents: 1,
      maxSinglePayloadBytes: 10,
    );
    expect(
      mux.add('normal', priority: EventMuxPriority.normalControl, bytes: 1),
      isTrue,
    );
    expect(mux.add('data', priority: EventMuxPriority.data, bytes: 1), isTrue);
    expect(mux.takeEntry()!.value, 'normal');
    expect(mux.takeEntry()!.value, 'data');

    expect(
      mux.add('critical', priority: EventMuxPriority.criticalControl, bytes: 1),
      isTrue,
    );
    expect(mux.takeEntry()!.value, 'critical');
    expect(mux.takeEntry(), isNull);

    expect(
      mux.add('oversized', priority: EventMuxPriority.data, bytes: 100),
      isFalse,
    );
    expect(mux.rejectedOversizeItems, 1);
    mux.close();
    mux.close();
    expect(mux.takeEntry(), isNull);
  });

  test(
    'Realtime gateway maps malformed command inputs to invalidArgument',
    () async {
      final handle = _BoundaryNativeHandle();
      final runtime = NetworkRuntimeImpl(
        nativeAdapter: _BoundaryNativeAdapter(handle),
      );
      final gateway = await runtime.openRealtimeGateway();

      final start = gateway.start(realtimeId: '', peerId: 'peer-a');
      final stop = gateway.stop(realtimeId: '');
      expect(start.queueStatus, NativeOperationStatus.invalidArgument);
      expect(stop.queueStatus, NativeOperationStatus.invalidArgument);
      await runtime.dispose();
    },
  );

  test(
    'Realtime gateway maps queue failures and drops malformed events',
    () async {
      final failureRuntime = NetworkRuntimeImpl(
        nativeAdapter: _BoundaryNativeAdapter(
          _BoundaryNativeHandle(status: TransportOperationStatus.failure),
        ),
      );
      final failureGateway = await failureRuntime.openRealtimeGateway();
      expect(
        failureGateway
            .start(
              realtimeId: '00112233445566778899aabbccddeeff',
              peerId: 'peer-a',
            )
            .queueStatus,
        NativeOperationStatus.failure,
      );
      await failureRuntime.dispose();

      final malformedRuntime = NetworkRuntimeImpl(
        nativeAdapter: _BoundaryNativeAdapter(
          _BoundaryNativeHandle(
            events: Stream<Uint8List>.value(Uint8List.fromList(<int>[0xff])),
          ),
        ),
      );
      final malformedGateway = await malformedRuntime.openRealtimeGateway();
      expect(await malformedGateway.events.toList(), isEmpty);
      await malformedRuntime.dispose();
    },
  );

  test('default native adapter exposes a bounded handle lifecycle', () async {
    final handle = await const SshMobileNativeNetworkAdapter().create();

    expect(handle.rawEvents, isA<Stream<Uint8List>>());
    expect(handle.boundLocalPort, isNull);
    expect(
      handle.sendCommand(Uint8List(0)),
      TransportOperationStatus.invalidArgument,
    );

    await handle.close();
    expect(handle.boundLocalPort, isNull);
    expect(
      handle.sendCommand(Uint8List.fromList(<int>[0])),
      TransportOperationStatus.stopped,
    );

    await handle.close();
    await handle.dispose();
  });
}

final class _BoundaryNativeAdapter implements NativeNetworkAdapter {
  const _BoundaryNativeAdapter(this.handle);

  final NativeNetworkHandle handle;

  @override
  Future<NativeNetworkHandle> create() async => handle;
}

final class _BoundaryNativeHandle implements NativeNetworkHandle {
  _BoundaryNativeHandle({
    this.status = TransportOperationStatus.success,
    Stream<Uint8List>? events,
  }) : _events = events ?? const Stream<Uint8List>.empty();

  final TransportOperationStatus status;
  final Stream<Uint8List> _events;
  bool closed = false;

  @override
  Stream<Uint8List> get rawEvents => _events;

  @override
  int? get boundLocalPort => closed ? null : 43123;

  @override
  TransportOperationStatus sendCommand(Uint8List command) =>
      closed ? TransportOperationStatus.stopped : status;

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
  ) => closed
      ? NativeOperationStatus.success
      : NativeOperationStatus.staleEndpoint;

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> dispose() => close();
}
