import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  test(
    'peer presentation copies preserve metadata and clear only explicitly removed fields',
    () {
      final time = DateTime.utc(2026, 10, 12);
      final discovered = LanDiscoveredPeer(
        deviceId: 'peer',
        alias: 'Phone',
        ip: '192.0.2.1',
        controlPort: 53317,
        advertisedNativePort: 43123,
        os: 'android',
        deviceType: LanDeviceType.mobile,
        lastSeen: time,
      );
      expect(
        discovered.hashCode,
        LanDiscoveredPeer.fromJson(discovered.toJson()).hashCode,
      );
      expect(discovered.copyWith(), discovered);
      expect(LanDeviceType.fromJson('unknown'), LanDeviceType.mobile);
      final route = const LanPeerRouteState().copyWith(
        directAvailable: true,
        relayAvailable: true,
        activeRoute: NetworkRouteType.relay,
        endpoint: '192.0.2.1:43123',
        updatedAt: time,
      );
      expect(route.localDirectAvailable, isTrue);
      expect(route.relayRouteAvailable, isTrue);
      expect(route.updatedAt, time);
      final state = LanPeerViewState(
        discovery: discovered,
        route: route,
        savedAlias: 'Saved',
        savedDeviceType: LanDeviceType.mobile,
        lastOnlineAt: time,
      );
      expect(state.controlPort, 53317);
      expect(state.deviceType, LanDeviceType.mobile);
      final copy = state.copyWith();
      expect(copy.lastOnlineAt, time);
      expect(copy.route, same(route));
      final offline = state.copyWith(
        peerId: 'peer',
        trust: null,
        discovery: null,
        reachability: LanPeerReachability.offline,
        savedAlias: 'Saved Phone',
        savedDeviceType: LanDeviceType.webBrowser,
        lastOnlineAt: time,
        route: route.copyWith(
          activeRoute: null,
          endpoint: null,
          updatedAt: null,
        ),
      );
      expect(offline.displayAlias, 'Saved Phone');
      expect(offline.deviceType, LanDeviceType.webBrowser);
      expect(offline.isOffline, isTrue);
      expect(offline.route.endpoint, isNull);
      expect(
        offline
            .copyWith(
              savedAlias: null,
              savedDeviceType: null,
              lastOnlineAt: null,
            )
            .lastOnlineAt,
        isNull,
      );
    },
  );
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
