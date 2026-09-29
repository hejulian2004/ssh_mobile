import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a refreshed discovery record survives the presence sweep', () async {
    final service = _service();
    addTearDown(service.close);
    final now = DateTime.utc(2026, 9, 29, 12);
    service.registerDiscoveredPeer(_peer('peer-1', now));
    service.registerDiscoveredPeer(
      _peer('peer-2', now.subtract(const Duration(seconds: 91))),
    );

    final sweptAt = now.add(const Duration(seconds: 100));
    expect(service.touchDiscoveredPeer('peer-1', now: sweptAt), isTrue);
    expect(service.touchDiscoveredPeer('missing', now: sweptAt), isFalse);

    expect(service.removeStaleDevices(now: sweptAt), 1);
    expect(service.currentDiscoveredPeers.map((peer) => peer.deviceId), [
      'peer-1',
    ]);
    expect(service.currentDiscoveredPeers.single.lastSeen, sweptAt);
  });

  test('an untouched record older than 90 seconds is removed', () async {
    final service = _service();
    addTearDown(service.close);
    final now = DateTime.utc(2026, 9, 29, 12);
    service.registerDiscoveredPeer(
      _peer('Alias (peer-1)', now.subtract(const Duration(seconds: 91))),
    );

    expect(service.touchDiscoveredPeer('peer-1', now: now), isTrue);
    expect(service.currentDiscoveredPeers.single.deviceId, 'peer-1');
    expect(
      service.removeStaleDevices(now: now.add(const Duration(seconds: 91))),
      1,
    );
    expect(service.currentDiscoveredPeers, isEmpty);
  });
}

LanDiscoveryService _service() {
  return LanDiscoveryService(
    currentDeviceId: 'local',
    currentDeviceAlias: 'Local',
    localAddressSelectionPort:
        const LanShareSingleCandidateLocalAddressSelection(),
    multicastLock: _SilentMulticastLock(),
  );
}

LanDiscoveredPeer _peer(String id, DateTime lastSeen) {
  return LanDiscoveredPeer(
    deviceId: id,
    alias: 'Peer',
    ip: '192.168.1.20',
    controlPort: 53317,
    os: 'windows',
    lastSeen: lastSeen,
  );
}

final class _SilentMulticastLock implements LanMulticastLock {
  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}
