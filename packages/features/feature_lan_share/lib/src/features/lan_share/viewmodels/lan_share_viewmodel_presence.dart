part of 'lan_share_viewmodel.dart';

/// Non-secret peer presentation; dynamic endpoints never enter persisted metadata.
extension LanShareViewModelPresence on LanShareViewModel {
  bool _isRouteOnline(String id, LanPeerRouteState route) =>
      transferService.isWebSocketConnected(id) ||
      route.relayAvailable ||
      (route.directAvailable &&
          (route.activeRoute == NetworkRouteType.quicDirect ||
              route.activeRoute == NetworkRouteType.lan));

  DateTime? _savedOnlineTime(String id) {
    final value = _peerMetadata[id]?.lastSeen;
    return value == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  LanDeviceType? _savedDeviceType(String id) {
    final value = _peerMetadata[id]?.deviceType;
    return value == null ? null : LanDeviceType.fromJson(value);
  }

  DateTime _latestOnlineTime(LanDiscoveredPeer peer) {
    return _onlineSince[peer.deviceId] ??
        _savedOnlineTime(peer.deviceId) ??
        peer.lastSeen;
  }

  Future<void> _loadPeerMetadata() async {
    final dao = pairingMetadataDao;
    if (dao == null) return;
    final entries = await dao.getAll();
    _peerMetadata
      ..clear()
      ..addEntries(
        entries
            .where((entry) => _trustRecords.containsKey(entry.deviceId))
            .map((entry) => MapEntry(entry.deviceId, entry)),
      );
  }

  void _applyDiscoveredPeers(List<LanDiscoveredPeer> peers) {
    _devices = List.of(peers);
    _refreshOnlinePresence();
  }

  void _refreshOnlinePresence() {
    final sources = <String, LanDiscoveredPeer?>{
      for (final peer in _devices) peer.deviceId: peer,
    };
    final routes =
        nativeTransferCoordinator?.currentRouteStates ??
        const <String, LanPeerRouteState>{};
    for (final id in _trustRecords.keys) {
      if (_isRouteOnline(id, routes[id] ?? const LanPeerRouteState())) {
        sources.putIfAbsent(id, () => null);
      }
    }
    _onlinePeerIds.retainAll(sources.keys);
    _onlineSince.removeWhere(
      (id, _) => !sources.containsKey(id) && !_trustRecords.containsKey(id),
    );
    for (final entry in sources.entries) {
      _notePeerOnline(
        entry.key,
        entry.value?.lastSeen ?? DateTime.now(),
        discovery: entry.value,
      );
    }
  }

  void _notePeerOnline(
    String id,
    DateTime observed, {
    LanDiscoveredPeer? discovery,
  }) {
    if (_disposed) return;
    final newPeriod = _onlinePeerIds.add(id);
    var since = newPeriod ? observed : _onlineSince[id] ?? observed;
    final saved = _savedOnlineTime(id);
    if (saved != null && since.isBefore(saved)) since = saved;
    _onlineSince[id] = since;
    if (!_trustRecords.containsKey(id)) return;
    final previous = _peerMetadata[id];
    final lastSeen = since.millisecondsSinceEpoch;
    final alias = discovery?.alias ?? previous?.alias ?? id;
    final type =
        discovery?.deviceType.name ??
        previous?.deviceType ??
        LanDeviceType.desktop.name;
    if (previous?.lastSeen == lastSeen &&
        previous?.alias == alias &&
        previous?.deviceType == type) {
      return;
    }
    _peerMetadata[id] = LanPairingMetadataData(
      deviceId: id,
      alias: alias,
      deviceType: type,
      lastSeen: lastSeen,
    );
    final dao = pairingMetadataDao;
    if (dao == null) return;
    final snapshot = _peerMetadata[id]!;
    final operation = _peerMetadataWrites.then((_) async {
      if (!_trustRecords.containsKey(id)) return;
      await dao.upsert(snapshot.toCompanion(true));
    });
    _peerMetadataWrites = operation.catchError((Object error) {
      logger.warning(
        'LAN peer metadata persistence failed',
        details: 'errorType=${error.runtimeType}',
      );
    });
    _trackBackgroundOperation(
      _peerMetadataWrites,
      'LAN peer metadata persistence failed',
    );
  }
}
