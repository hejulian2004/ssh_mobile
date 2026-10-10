import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/services/network/network_service.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';
import 'package:ssh_mobile/services/telemetry/telemetry_span.dart';

import 'transfer_transport_test_support.dart';

void main() {
  group('NetworkService peer adapter behavior', () {
    test(
      'upsertPeer sends a typed peer configuration and awaits acceptance',
      () async {
        final gateway = TransferFakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        final result = await service.upsertPeer(
          PeerConfig(
            peerId: 'peer-upsert',
            endpointAddress: '127.0.0.1:53317',
            identityPublicKey: Uint8List.fromList(List.filled(32, 1)),
            e2ePublicKey: Uint8List.fromList(List.filled(32, 2)),
            allowDirect: true,
            allowRelay: true,
          ),
        );

        expect(result, isA<NetworkSuccess<void>>());
        expect(gateway.commands, hasLength(1));
      },
    );

    test(
      'connect completes and releases a trace when a route already exists',
      () async {
        final gateway = TransferFakeCommandGateway();
        final traces = TelemetryTraceRegistry();
        final service = NativeNetworkService.fromGateway(
          gateway,
          traceRegistry: traces,
        );
        addTearDown(() async {
          await service.dispose();
          traces.dispose();
          await gateway.close();
        });

        gateway.emit(
          transferEventFrame(17, <int>[
            ...transferBytesField(1, utf8.encode('peer-routed')),
            ...transferVarintField(2, NetworkRouteType.quicDirect.wireValue),
            ...transferBytesField(3, utf8.encode('127.0.0.1:53317')),
          ]),
        );
        await Future<void>.delayed(Duration.zero);
        traces.bindPeer(peerId: 'peer-routed', traceId: 'trace-routed');

        final result = await service.connect('peer-routed');

        expect(result, isA<NetworkSuccess<void>>());
        expect(traces.traceForPeer('peer-routed'), isNull);
        expect(gateway.commands, isEmpty);
      },
    );

    test(
      'connect maps a disconnected terminal event to a no-route failure',
      () async {
        final gateway = TransferFakeCommandGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        final connectFuture = service.connect('peer-disconnected');
        await Future<void>.delayed(Duration.zero);
        gateway.emit(
          transferEventFrame(10, <int>[
            ...transferBytesField(1, utf8.encode('peer-disconnected')),
            ...transferVarintField(
              2,
              PeerConnectionState.disconnected.wireValue,
            ),
          ]),
        );

        final result = await connectFuture;

        expect(result, isA<NetworkFailure<void>>());
        expect(
          (result as NetworkFailure<void>).error.code,
          NetworkErrorCode.noRoute,
        );
        expect(result.errorCode, NetworkErrorCode.noRoute);
      },
    );

    test(
      'connect preserves a terminal authentication error when command is rejected',
      () async {
        final gateway = _AuthenticationFailureGateway();
        final service = NativeNetworkService.fromGateway(gateway);
        addTearDown(() async {
          await service.dispose();
          await gateway.close();
        });

        final result = await service.connect('peer-auth');

        expect(result, isA<NetworkFailure<void>>());
        final failure = result as NetworkFailure<void>;
        expect(failure.error.code, NetworkErrorCode.authenticationFailed);
        expect(failure.error.message, 'QUIC identity authentication failed');
      },
    );

    test('connect timeout releases the exact peer trace', () async {
      final gateway = TransferFakeCommandGateway();
      final traces = TelemetryTraceRegistry();
      final service = NativeNetworkService.fromGateway(
        gateway,
        traceRegistry: traces,
      );
      addTearDown(() async {
        await service.dispose();
        traces.dispose();
        await gateway.close();
      });
      traces.bindPeer(peerId: 'peer-timeout', traceId: 'trace-timeout');

      final result = await runZoned<Future<NetworkResult<void>>>(
        () => service.connect('peer-timeout'),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              parent.createTimer(zone, Duration.zero, callback),
        ),
      );

      expect(result, isA<NetworkFailure<void>>());
      expect(result.errorCode, NetworkErrorCode.timeout);
      expect(traces.traceForPeer('peer-timeout'), isNull);
    });
  });
}

final class _AuthenticationFailureGateway implements NetworkCommandGateway {
  _AuthenticationFailureGateway()
    : _codec = const NetworkProtocolV2Codec(),
      _events = StreamController<Uint8List>.broadcast();

  final NetworkProtocolV2Codec _codec;
  final StreamController<Uint8List> _events;

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    final commandId = _codec.commandId(command);
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      final authenticationError = <int>[
        ...transferVarintField(
          1,
          NetworkErrorCode.authenticationFailed.wireValue,
        ),
        ...transferBytesField(
          2,
          utf8.encode('QUIC identity authentication failed'),
        ),
        ...transferBytesField(
          3,
          utf8.encode(NetworkOperation.connect.wireName),
        ),
        ...transferBytesField(4, utf8.encode('peer-auth')),
      ];
      _events.add(
        transferEventFrame(10, <int>[
          ...transferBytesField(1, utf8.encode('peer-auth')),
          ...transferVarintField(2, PeerConnectionState.failed.wireValue),
          ...transferVarintField(3, NetworkRouteType.quicDirect.wireValue),
          ...transferBytesField(4, authenticationError),
        ]),
      );
      _events.add(
        transferEventFrame(13, <int>[
          ...transferBytesField(1, utf8.encode(commandId)),
          ...transferVarintField(2, 0),
          ...transferBytesField(3, authenticationError),
        ]),
      );
    });
    return TransportOperationStatus.success;
  }

  Future<void> close() => _events.close();
}
