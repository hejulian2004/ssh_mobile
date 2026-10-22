// Discovery peer presentation and observation updates.

part of 'lan_discovery_service.dart';

extension LanDiscoveryPeerOperations on LanDiscoveryService {
  /// Converts a discovered mDNS record into a typed LAN peer.
  void _handleDiscoveredNsdService(nsd.Service service) {
    final txt = service.txt ?? {};
    final rawId = txt['id'] != null
        ? utf8.decode(txt['id']!)
        : service.name ?? '';
    final id = _extractCleanId(rawId);
    if (id.isEmpty || id == currentDeviceId) return;
    // A packet/manual route observation identifies the interface actually used
    // to reach this peer. A multi-interface mDNS host/TXT address must not
    // replace that endpoint while the observation remains fresh.
    final observed = _peerMap[id];
    if (!_nsdPeerIds.contains(id) &&
        observed != null &&
        DateTime.now().difference(observed.lastSeen) <
            LanDiscoveryService.devicePresenceTtl) {
      return;
    }

    final rawAlias = txt['alias'] != null
        ? utf8.decode(txt['alias']!)
        : service.name ?? 'Device';
    final alias = _extractCleanAlias(rawAlias);
    final os = txt['os'] != null ? utf8.decode(txt['os']!) : 'Unknown';
    // NSD host is a canonical hostname on Android/Windows, while addresses
    // contains the resolved endpoint. LAN listeners bind IPv4; do not hand a
    // .local name or an unusable interface address to the HTTPS client.
    String? usableIpv4(String? raw) {
      if (raw == null) return null;
      final value = raw.startsWith('::ffff:') ? raw.substring(7) : raw;
      final address = InternetAddress.tryParse(value);
      if (address == null ||
          address.type != InternetAddressType.IPv4 ||
          address.isLoopback ||
          address.isMulticast ||
          address.address == '0.0.0.0') {
        return null;
      }
      return address.address;
    }

    String? hostIp;
    for (final address in service.addresses ?? <InternetAddress>[]) {
      hostIp = usableIpv4(address.address);
      if (hostIp != null) break;
    }
    hostIp ??= usableIpv4(service.host);
    hostIp ??= usableIpv4(txt['ip'] != null ? utf8.decode(txt['ip']!) : null);
    final port = service.port ?? LanDiscoveryService.defaultPort;
    final nativePort = int.tryParse(
      txt['nativePort'] == null ? '' : utf8.decode(txt['nativePort']!),
    );

    if (hostIp == null) return;

    final peer = LanDiscoveredPeer(
      deviceId: id,
      alias: alias,
      ip: hostIp,
      controlPort: port,
      advertisedNativePort: nativePort,
      deviceType: _guessDeviceType(os),
      os: os,
      lastSeen: DateTime.now(),
    );

    _peerMap[id] = peer;
    _nsdPeerIds.add(id);
    _notifyPeersUpdated();
  }

  /// Maps the observed operating system to the Feature device category.
  LanDeviceType _guessDeviceType(String os) {
    final lower = os.toLowerCase();
    if (lower.contains('android') || lower.contains('ios')) {
      return LanDeviceType.mobile;
    }
    if (lower.contains('web')) {
      return LanDeviceType.webBrowser;
    }
    return LanDeviceType.desktop;
  }

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
  int _removeStaleDevices({
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
    _nsdPeerIds.removeWhere((id) => !_peerMap.containsKey(id));
    if (removed > 0) _notifyPeersUpdated();
    return removed;
  }

  /// 刷新已有发现记录的 lastSeen。未知设备不会被创建。
  bool _touchDiscoveredPeer(String deviceId, {DateTime? now}) {
    if (_closing || _closed) return false;
    final cleanId = _extractCleanId(deviceId.trim());
    if (cleanId.isEmpty) return false;
    String? matchKey;
    LanDiscoveredPeer? match;
    for (final entry in _peerMap.entries) {
      if (_extractCleanId(entry.key) == cleanId ||
          _extractCleanId(entry.value.deviceId) == cleanId) {
        matchKey = entry.key;
        match = entry.value;
        break;
      }
    }
    if (matchKey == null || match == null) return false;
    final updated = match.copyWith(
      deviceId: cleanId,
      lastSeen: now ?? DateTime.now(),
    );
    if (matchKey != cleanId) _peerMap.remove(matchKey);
    _peerMap[cleanId] = updated;
    _notifyPeersUpdated();
    return true;
  }

  /// 新增或替换一个 discovery-only 对端观察。
  void _registerDiscoveredPeer(LanDiscoveredPeer peer) {
    _nsdPeerIds.remove(peer.deviceId);
    _peerMap[peer.deviceId] = peer;
    _notifyPeersUpdated();
  }

  /// 根据标识移除一个动态 discovery observation。
  void _removeDiscoveredPeer(String deviceId) {
    _nsdPeerIds.remove(deviceId);
    _peerMap.remove(deviceId);
    _peerMap.removeWhere(
      (key, peer) => _extractCleanId(peer.deviceId) == deviceId,
    );
    _notifyPeersUpdated();
  }
}
