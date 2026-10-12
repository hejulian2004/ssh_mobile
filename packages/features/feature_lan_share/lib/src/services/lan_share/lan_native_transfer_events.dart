part of 'lan_native_transfer_coordinator.dart';

extension LanNativeTransferEvents on LanNativeTransferCoordinator {
  void _handleNetworkEvent(SdkEvent event) {
    if (_disposed) return;
    if (event case final IncomingTransferOffer offer) {
      unawaited(_processIncomingOffer(offer));
    }
    _updateRouteStateFromEvent(event);
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> _processIncomingOffer(IncomingTransferOffer offer) async {
    if (_disposed) return;
    final policyResult = await _policyPort.getPeerPolicy(offer.peerId);
    if (policyResult is NetworkFailure<LanPeerPolicySnapshot>) {
      await _respondNative(offer, accept: false);
      return;
    }
    final policy = (policyResult as NetworkSuccess<LanPeerPolicySnapshot>).data;
    if (!policy.isTrusted ||
        !isIncomingRouteAuthorized(
          policy.trust!.authorization,
          offer.routeType,
        )) {
      await _respondNative(offer, accept: false);
      return;
    }

    if (_committedDecisions.containsKey(offer.transferId)) {
      return;
    }
    final isNewOffer = !_pendingOffers.containsKey(offer.transferId);
    _pendingOffers[offer.transferId] = offer;
    _offerTimers[offer.transferId] ??= Timer(offerTimeout, () {
      unawaited(_expireOffer(offer));
    });
    if (isNewOffer && !_incomingOffers.isClosed) {
      _incomingOffers.add(offer);
    }
  }

  void _updateRouteStateFromEvent(SdkEvent event) {
    var changed = false;
    if (event case final PeerStateChanged stateEvent) {
      final current =
          _routeStates[stateEvent.peerId] ?? const LanPeerRouteState();
      final isOnline = stateEvent.state == PeerConnectionState.connected;
      final activeRoute = isOnline
          ? stateEvent.routeType
          : NetworkRouteType.unspecified;
      final updated = current.copyWith(
        activeRoute: activeRoute,
        directAvailable:
            stateEvent.routeType == NetworkRouteType.quicDirect ||
                stateEvent.routeType == NetworkRouteType.lan
            ? isOnline
            : current.directAvailable,
        relayAvailable: stateEvent.routeType == NetworkRouteType.relay
            ? isOnline
            : current.relayAvailable,
      );
      _routeStates[stateEvent.peerId] = updated;
      changed = true;
    } else if (event case final RouteChanged routeEvent) {
      final snap = routeEvent.snapshot;
      final current = _routeStates[snap.peerId] ?? const LanPeerRouteState();
      final isDirect =
          snap.routeType == NetworkRouteType.quicDirect ||
          snap.routeType == NetworkRouteType.lan;
      final isRelay = snap.routeType == NetworkRouteType.relay;
      final updated = current.copyWith(
        activeRoute: snap.routeType,
        endpoint: snap.endpoint,
        directAvailable: isDirect ? true : current.directAvailable,
        relayAvailable: isRelay ? true : current.relayAvailable,
      );
      _routeStates[snap.peerId] = updated;
      changed = true;
    } else if (event case final RelayStateChanged relayEvent) {
      if (relayEvent.state != RelayConnectionState.connected) {
        for (final entry in _routeStates.entries) {
          if (entry.value.relayAvailable) {
            _routeStates[entry.key] = entry.value.copyWith(
              relayAvailable: false,
            );
            changed = true;
          }
        }
      }
    } else if (event case final PeerPresenceChanged presenceEvent) {
      final current =
          _routeStates[presenceEvent.peerId] ?? const LanPeerRouteState();
      final isOnline =
          presenceEvent.state == PeerPresenceState.online ||
          presenceEvent.state == PeerPresenceState.updated;
      final updated = current.copyWith(relayAvailable: isOnline);
      _routeStates[presenceEvent.peerId] = updated;
      changed = true;
    } else if (event case final PeerPresenceSnapshot snapshotEvent) {
      final snapshotPeerIds = <String>{};
      for (final peer in snapshotEvent.peers) {
        snapshotPeerIds.add(peer.peerId);
        final current = _routeStates[peer.peerId] ?? const LanPeerRouteState();
        final isOnline =
            peer.state == PeerPresenceState.online ||
            peer.state == PeerPresenceState.updated;
        _routeStates[peer.peerId] = current.copyWith(relayAvailable: isOnline);
      }
      for (final entry in _routeStates.entries) {
        if (!snapshotPeerIds.contains(entry.key) &&
            entry.value.relayAvailable) {
          _routeStates[entry.key] = entry.value.copyWith(relayAvailable: false);
        }
      }
      changed = true;
    }

    if (changed && !_routeStateController.isClosed) {
      _routeStateController.add(
        Map<String, LanPeerRouteState>.unmodifiable(_routeStates),
      );
    }
  }
}
