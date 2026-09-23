import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LanDiscoveredPeer', () {
    test('contains discovery data only and round-trips its endpoint', () {
      final peer = LanDiscoveredPeer(
        deviceId: 'peer-1',
        alias: 'Peer 1',
        ip: '192.168.1.5',
        controlPort: 53317,
        advertisedNativePort: 6543,
        deviceType: LanDeviceType.mobile,
        os: 'android',
        lastSeen: DateTime.utc(2026, 8, 25),
      );

      final encoded = peer.toJson();
      final decoded = LanDiscoveredPeer.fromJson(encoded);

      expect(decoded, peer);
      expect(encoded, isNot(contains('isTrusted')));
      expect(encoded, isNot(contains('certFingerprint')));
      expect(encoded, isNot(contains('inboundAccessToken')));
      expect(decoded.controlPort, 53317);
      expect(decoded.advertisedNativePort, 6543);
    });

    test('does not deserialize the removed V1 aggregate shape', () {
      expect(
        () => LanDiscoveredPeer.fromJson(<String, dynamic>{
          'id': 'legacy-peer',
          'alias': 'Legacy peer',
          'ip': '192.0.2.5',
          'port': 53317,
          'osName': 'linux',
          'lastSeen': DateTime.utc(2026, 8, 25).toIso8601String(),
        }),
        throwsFormatException,
      );
    });

    test(
      'can invalidate the dynamic native endpoint without changing trust',
      () {
        final peer = LanDiscoveredPeer(
          deviceId: 'peer-1',
          alias: 'Peer 1',
          ip: '192.168.1.5',
          controlPort: 53317,
          advertisedNativePort: 6543,
          os: 'android',
          lastSeen: DateTime.utc(2026, 8, 25),
        );

        final invalidated = peer.copyWith(advertisedNativePort: null);

        expect(invalidated.advertisedNativePort, isNull);
        expect(invalidated.deviceId, peer.deviceId);
        expect(invalidated.ip, peer.ip);
      },
    );
  });

  group('LanPeerViewState', () {
    test('represents a trusted offline peer without discovery data', () {
      final trust = LanPeerTrustRecord(
        deviceId: 'peer-1',
        certificateFingerprint: 'a' * 64,
        inboundAccessToken: 'inbound-token',
        outboundAccessToken: 'outbound-token',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026, 8, 25),
      );
      final state = LanPeerViewState(trust: trust);

      expect(state.peerId, 'peer-1');
      expect(state.isTrusted, isTrue);
      expect(state.isDiscovered, isFalse);
      expect(state.isTrustedOffline, isTrue);
      expect(state.isOffline, isTrue);
      expect(state.ip, isNull);
      expect(state.advertisedNativePort, isNull);
    });

    test(
      'keeps route availability independent from authorization and discovery',
      () {
        final trust = LanPeerTrustRecord(
          deviceId: 'peer-1',
          certificateFingerprint: 'b' * 64,
          inboundAccessToken: 'inbound-token',
          outboundAccessToken: 'outbound-token',
          x25519PublicKey: Uint8List(32),
          networkIdentityPublicKey: Uint8List(32),
          origin: PeerTrustOrigin.localPin,
          authorization: const PeerRouteAuthorization(
            localDirect: true,
            relay: false,
          ),
          createdAt: DateTime.utc(2026, 8, 25),
        );
        final state = LanPeerViewState(
          trust: trust,
          route: const LanPeerRouteState(directAvailable: true),
        );

        expect(state.trust, same(trust));
        expect(state.route.directAvailable, isTrue);
        expect(state.route.relayAvailable, isFalse);
        expect(state.route.activeRoute, isNull);
        expect(state.canUseRoute, isTrue);
      },
    );
  });

  test('discovery service publishes discovery-only snapshots', () async {
    final service = LanDiscoveryService(
      currentDeviceId: 'local',
      currentDeviceAlias: 'Local',
      localAddressSelectionPort:
          const LanShareSingleCandidateLocalAddressSelection(),
      multicastLock: _FakeMulticastLock(),
    );
    addTearDown(service.close);

    final snapshotFuture = service.discoveredPeersStream.first;
    service.registerDiscoveredPeer(
      LanDiscoveredPeer(
        deviceId: 'peer-1',
        alias: 'Peer 1',
        ip: '192.168.1.5',
        controlPort: 53317,
        advertisedNativePort: 6543,
        os: 'android',
        lastSeen: DateTime.utc(2026, 8, 25),
      ),
    );

    final snapshot = await snapshotFuture;
    expect(snapshot, hasLength(1));
    expect(snapshot.single.deviceId, 'peer-1');
    expect(snapshot.single.advertisedNativePort, 6543);
  });
}

final class _FakeMulticastLock implements LanMulticastLock {
  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}
