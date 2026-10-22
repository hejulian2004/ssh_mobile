import 'dart:async';

import '../../domain/lan_discovery_bridge.dart';
import 'lan_share_models.dart';

/// Owns the optional bridge subscription within one Discovery lifecycle.
final class LanDiscoveryBridgeBinding {
  LanDiscoveryBridgeBinding({required this.bridge, required this.onPeers});

  final LanShareDiscoveryBridgePort? bridge;
  final void Function(List<LanDiscoveredPeer> peers) onPeers;
  StreamSubscription<List<LanDiscoveredPeer>>? _subscription;

  Future<void> start(Map<String, Object> advertisement) async {
    final adapter = bridge;
    if (adapter == null) return;
    _subscription = adapter.peers.listen(onPeers);
    try {
      await adapter.start(advertisement);
    } on Object {
      // Optional local host tooling must not disable ordinary LAN discovery.
      await stop();
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await bridge?.stop();
    onPeers([]);
  }

  Future<void> close() async {
    await stop();
    await bridge?.close();
  }
}
