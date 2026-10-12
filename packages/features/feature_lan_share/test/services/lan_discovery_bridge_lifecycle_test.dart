import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:feature_lan_share/src/services/lan_share/lan_discovery_bridge_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bridge binding cancels old observations and releases its adapter',
    () async {
      final bridge = _Bridge();
      final snapshots = <List<LanDiscoveredPeer>>[];
      final binding = LanDiscoveryBridgeBinding(
        bridge: bridge,
        onPeers: snapshots.add,
      );
      await binding.start({'id': 'desktop'});
      bridge.controller.add([]);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.length, 1);
      await binding.stop();
      bridge.controller.add([]);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.length, 2);
      await binding.start({'id': 'desktop'});
      await binding.close();
      expect(bridge.stopped, 2);
      expect(bridge.closed, isTrue);
    },
  );

  test(
    'optional bridge failure and absence preserve normal discovery',
    () async {
      final bridge = _Bridge()..failStart = true;
      final binding = LanDiscoveryBridgeBinding(
        bridge: bridge,
        onPeers: (_) {},
      );
      await binding.start({});
      expect(bridge.stopped, 1);
      await binding.close();
      final absent = LanDiscoveryBridgeBinding(bridge: null, onPeers: (_) {});
      await absent.start({});
      await absent.close();
    },
  );
}

class _Bridge implements LanShareDiscoveryBridgePort {
  final controller = StreamController<List<LanDiscoveredPeer>>.broadcast();
  bool failStart = false;
  int stopped = 0;
  bool closed = false;
  @override
  Stream<List<LanDiscoveredPeer>> get peers => controller.stream;
  @override
  Future<void> start(Map<String, Object> advertisement) async {
    if (failStart) throw StateError('Unavailable');
  }

  @override
  Future<void> stop() async {
    stopped++;
  }

  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }

  @override
  LanDiscoveredPeer routePeer(LanDiscoveredPeer peer) => peer;
  @override
  int? nativePortFor(LanDiscoveredPeer peer, int advertisedPort) =>
      advertisedPort;
}
