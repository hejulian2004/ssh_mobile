import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'socket replacement and stale errors release only the old connection',
    () async {
      final service = _service();
      addTearDown(service.close);
      final changes = <LanConnectionStateChanged>[];
      final subscription = service.connectionStateStream.listen(changes.add);
      addTearDown(subscription.cancel);
      final old = _Socket();
      final current = _Socket();
      service.registerActiveWebSocketForTesting('peer', old);
      service.registerActiveWebSocketForTesting('peer', current);
      await Future<void>.delayed(Duration.zero);
      expect(old.closed, isTrue);
      expect(service.isWebSocketConnected('peer'), isTrue);
      current.events.addError(StateError('connection lost'));
      await Future<void>.delayed(Duration.zero);
      expect(service.isWebSocketConnected('peer'), isFalse);
      expect(changes.last.connected, isFalse);
      expect(current.closed, isTrue);
      await service.close();
      final late = _Socket();
      service.registerActiveWebSocketForTesting('peer', late);
      expect(service.isWebSocketConnected('peer'), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(late.closed, isTrue);
    },
  );
  test('unpaired socket connections fail before transport activity', () async {
    final service = _service();
    addTearDown(service.close);
    final result = await service.connectWebSocket(
      LanDiscoveredPeer(
        deviceId: 'unknown',
        alias: 'Unknown',
        ip: '127.0.0.1',
        controlPort: 1,
        os: 'android',
        lastSeen: DateTime.now(),
      ),
    );
    expect(result, isA<NetworkFailure<void>>());
    expect(
      (result as NetworkFailure<void>).error.code,
      NetworkErrorCode.authenticationFailed,
    );
  });

  test(
    'explicit unpair closes an established control socket without closing the service',
    () async {
      final service = _service();
      addTearDown(service.close);
      final socket = _Socket();
      service.registerActiveWebSocketForTesting('peer', socket);
      await service.disconnectPairedPeer('peer');
      expect(service.isWebSocketConnected('peer'), isFalse);
      expect(socket.closed, isTrue);
      expect(service.hasPendingPairing('peer'), isFalse);
      final fresh = _Socket();
      service.registerActiveWebSocketForTesting('peer', fresh);
      expect(service.isWebSocketConnected('peer'), isTrue);
    },
  );

  test(
    'trusted socket transport failure returns a typed error and retains trust',
    () async {
      final service = _service();
      addTearDown(service.close);
      final store = service.securityService.peerTrustStore;
      await store.save(
        LanPeerTrustRecord(
          deviceId: 'peer',
          certificateFingerprint: 'a' * 64,
          inboundAccessToken: 'inbound',
          outboundAccessToken: 'outbound',
          x25519PublicKey: Uint8List(32),
          networkIdentityPublicKey: Uint8List(32),
          origin: PeerTrustOrigin.localPin,
          authorization: const PeerRouteAuthorization(
            localDirect: true,
            relay: false,
          ),
          createdAt: DateTime.utc(2026),
        ),
      );
      final result = await service.connectWebSocket(
        LanDiscoveredPeer(
          deviceId: 'peer',
          alias: 'Peer',
          ip: '127.0.0.1',
          controlPort: 1,
          os: 'android',
          lastSeen: DateTime.now(),
        ),
      );
      expect(result, isA<NetworkFailure<void>>());
      expect(await store.read('peer'), isNotNull);
    },
  );
}

LanTransferService _service() => LanTransferService(
  currentDeviceId: 'local',
  securityService: LanSecurityService(appOwnedX25519PrivateSeed: Uint8List(32)),
  storageService: LanStorageService(),
);

final class _Socket extends Stream<dynamic> with Fake implements WebSocket {
  final events = StreamController<dynamic>();
  bool closed = false;
  @override
  Duration? pingInterval;
  @override
  Future<void> close([int? code, String? reason]) async {
    if (closed) return;
    closed = true;
    unawaited(events.close());
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
