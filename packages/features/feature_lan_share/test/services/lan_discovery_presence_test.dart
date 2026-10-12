import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'dart:io';
import 'package:nsd/nsd.dart' as nsd;

void main() {
  test('mDNS uses resolved IPv4 instead of a canonical hostname', () async {
    final service = _NsdDiscovery();
    addTearDown(service.close);
    await service.startDiscovery();
    service.discovery.add(
      nsd.Service(
        name: 'Phone',
        type: LanDiscoveryService.serviceType,
        host: 'phone.local',
        addresses: [InternetAddress('192.168.137.20')],
        port: 53317,
        txt: {'id': utf8.encode('phone')},
      ),
    );
    expect(service.currentDiscoveredPeers.single.ip, '192.168.137.20');
  });
  test(
    'fresh observed hotspot endpoint survives another mDNS interface address',
    () async {
      final service = _NsdDiscovery();
      addTearDown(service.close);
      await service.startDiscovery();
      service.registerDiscoveredPeer(
        _peer('peer', DateTime.now()).copyWith(ip: '192.168.137.20'),
      );
      service.discovery.add(
        nsd.Service(
          name: 'Peer',
          type: LanDiscoveryService.serviceType,
          host: '198.18.0.2',
          port: 53317,
          txt: {'id': utf8.encode('peer'), 'os': utf8.encode('android')},
        ),
      );
      expect(service.currentDiscoveredPeers.single.ip, '192.168.137.20');
      service.removeDiscoveredPeer('peer');
      service.discovery.remove(service.discovery.services.single);
      service.discovery.add(
        nsd.Service(
          name: 'Peer',
          type: LanDiscoveryService.serviceType,
          host: '192.168.137.21',
          port: 53317,
          txt: {'id': utf8.encode('peer')},
        ),
      );
      expect(service.currentDiscoveredPeers.single.ip, '192.168.137.21');
    },
  );
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

class _NsdDiscovery extends LanDiscoveryService {
  _NsdDiscovery()
    : super(
        currentDeviceId: 'local',
        currentDeviceAlias: 'Local',
        localAddressSelectionPort:
            const LanShareSingleCandidateLocalAddressSelection(),
        multicastLock: _SilentMulticastLock(),
      );
  final discovery = nsd.Discovery('fixture');
  @override
  Future<nsd.Discovery> performStartDiscovery() async => discovery;
  @override
  Future<void> performStopDiscovery(nsd.Discovery discovery) async {}
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
