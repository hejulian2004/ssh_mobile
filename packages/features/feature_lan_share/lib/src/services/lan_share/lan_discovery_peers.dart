// Discovery peer presentation and observation updates.

part of 'lan_discovery_service.dart';

extension LanDiscoveryPeerOperations on LanDiscoveryService {
  /// 移除 mDNS 设备标识中的显示后缀。
  String _extractCleanId(String rawId) {
    if (rawId.contains('(') && rawId.endsWith(')')) {
      final start = rawId.lastIndexOf('(') + 1;
      final end = rawId.length - 1;
      if (start < end) {
        return rawId.substring(start, end).trim();
      }
    }
    return rawId;
  }

  /// 移除 mDNS 显示别名中的标识后缀。
  String _extractCleanAlias(String rawAlias) {
    if (rawAlias.contains('(') && rawAlias.endsWith(')')) {
      final start = rawAlias.lastIndexOf('(');
      if (start > 0) {
        return rawAlias.substring(0, start).trim();
      }
    }
    return rawAlias;
  }

  /// 发布去重后的 discovery-only 对端列表。
  Stream<List<LanDiscoveredPeer>> get discoveredPeersStream =>
      _discoveredPeersController.stream;

  /// 返回按最近观察时间排序的已发现对端。
  List<LanDiscoveredPeer> get currentDiscoveredPeers {
    final uniquePeers = <String, LanDiscoveredPeer>{};
    final sorted = _peerMap.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    for (final peer in sorted) {
      final cleanId = _extractCleanId(peer.deviceId);
      if (uniquePeers.containsKey(cleanId)) {
        // 已存在时保留 lastSeen 更新的记录。
        final existing = uniquePeers[cleanId]!;
        if (peer.lastSeen.isAfter(existing.lastSeen)) {
          uniquePeers[cleanId] = peer.copyWith(deviceId: cleanId);
        }
        continue;
      }
      uniquePeers[cleanId] = peer.copyWith(deviceId: cleanId);
    }
    return uniquePeers.values.toList(growable: false);
  }

  /// 发布当前 discovery-only 对端快照。
  void _notifyPeersUpdated() {
    if (!_closing && !_closed && !_discoveredPeersController.isClosed) {
      _discoveredPeersController.add(currentDiscoveredPeers);
    }
  }

  /// 启动过期发现记录的定期清理。
  void _startDeviceCleanup() {
    _deviceCleanupTimer?.cancel();
    _deviceCleanupTimer = Timer.periodic(
      LanDiscoveryService._deviceCleanupInterval,
      (_) => removeStaleDevices(),
    );
  }

  /// 清理过期设备，同时保留当前可见的 mDNS 对端。
  @visibleForTesting
  int removeStaleDevices({
    DateTime? now,
    Duration ttl = LanDiscoveryService.devicePresenceTtl,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(ttl);
    final activeNsdDeviceIds = <String>{};
    final discovery = _discovery;
    if (discovery != null) {
      for (final service in discovery.services) {
        try {
          final txtId = service.txt?['id'];
          final rawId = txtId != null ? utf8.decode(txtId) : service.name ?? '';
          final id = _extractCleanId(rawId);
          if (id.isNotEmpty) activeNsdDeviceIds.add(id);
        } catch (_) {}
      }
    }
    final before = _peerMap.length;
    _peerMap.removeWhere(
      (_, peer) =>
          peer.lastSeen.isBefore(cutoff) &&
          !activeNsdDeviceIds.contains(_extractCleanId(peer.deviceId)),
    );
    final removed = before - _peerMap.length;
    if (removed > 0) _notifyPeersUpdated();
    return removed;
  }

  /// 新增或替换一个 discovery-only 对端观察。
  void registerDiscoveredPeer(LanDiscoveredPeer peer) {
    _peerMap[peer.deviceId] = peer;
    _notifyPeersUpdated();
  }

  /// 根据标识移除一个动态 discovery observation。
  void removeDiscoveredPeer(String deviceId) {
    _peerMap.remove(deviceId);
    _peerMap.removeWhere(
      (key, peer) => _extractCleanId(peer.deviceId) == deviceId,
    );
    _notifyPeersUpdated();
  }
}
