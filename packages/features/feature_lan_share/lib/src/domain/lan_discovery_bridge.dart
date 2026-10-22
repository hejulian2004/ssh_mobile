import '../services/lan_share/lan_share_models.dart';

/// Optional platform discovery adapter owned by the Receiver's discovery scope.
/// Observations and port mappings confer no pairing trust or authorization.
abstract interface class LanShareDiscoveryBridgePort {
  Stream<List<LanDiscoveredPeer>> get peers;
  Future<void> start(Map<String, Object> advertisement);
  Future<void> stop();
  Future<void> close();

  /// Resolves a raw observation using only this adapter's live owned mappings.
  LanDiscoveredPeer routePeer(LanDiscoveredPeer peer);

  /// Maps an authenticated native capability; stale mappings return null.
  int? nativePortFor(LanDiscoveredPeer peer, int advertisedPort);
}
