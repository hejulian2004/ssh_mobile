part of 'lan_transfer_service.dart';

extension LanPairingCommit on LanTransferService {
  Future<void> _disconnectPairedPeer(String peerId) async {
    final invitation = _pairingInviteAttempts[peerId];
    cancelPairingInvite(peerId);
    if (invitation != null) await invitation.done.future;
    cancelPairingAuthentication(peerId);
    _discardReciprocalPairing(peerId);
    void clearChallenges() => _pendingPairingHandshakes.removeWhere(
      (_, entry) => entry.senderDeviceId == peerId,
    );
    clearChallenges();
    final incoming = _incomingPairingOperations.toList();
    final outgoing = _outboundPairingOperations[peerId]?.toList() ?? [];
    await Future.wait<void>([
      ...incoming,
      ...outgoing.map((operation) => operation.then<void>((_) {})),
      if (_webSocketConnectAttempts[peerId] case final operation?)
        operation.then<void>((_) {}),
    ]);
    _discardReciprocalPairing(peerId);
    clearChallenges();
    final socket = _activeWebSockets.remove(peerId);
    if (socket != null) {
      await _closeTrackedWebSocket(socket);
      _emit(
        _connectionStateController,
        LanConnectionStateChanged(deviceId: peerId, connected: false),
      );
    }
  }

  NetworkFailure<LanPairingHandshakeProgress> _cancelledPairing(
    String peerId,
  ) => NetworkFailure(
    NetworkError(
      code: NetworkErrorCode.cancelled,
      message: 'LAN pairing was cancelled by unpairing.',
      operation: NetworkOperation.sendHandshake,
      peerId: peerId,
    ),
  );

  /// 丢弃 [peerId] 的双向证明，并通知界面清除等待提示。
  void _discardReciprocalPairing(String peerId) {
    _reciprocalPairing.discard(peerId);
    _emit(
      _pairingDirectionController,
      LanPairingDirectionNotice(
        peerId: peerId,
        outboundVerified: false,
        inboundVerified: false,
      ),
    );
  }

  LanDiscoveredPeer _peerFromPairingProof(LanPairingDirectionProof proof) {
    return resolvePeer(
      LanDiscoveredPeer(
        deviceId: proof.peerDeviceId,
        alias: proof.alias,
        ip: proof.ip,
        controlPort: proof.controlPort,
        deviceType: _guessDeviceType(proof.os),
        os: proof.os,
        lastSeen: DateTime.now(),
      ),
    );
  }

  void _emitObservedPeer(LanPairingDirectionProof proof) {
    _emit(_observedPeerController, _peerFromPairingProof(proof));
  }

  /// Persists trust only for a committed reciprocal update.
  ///
  /// Waiting leaves the trust store unchanged. The observed peer is emitted
  /// before handshake success so discovery is registered first.
  Future<LanPairingHandshakeProgress?> _applyReciprocalUpdate({
    required LanReciprocalPairingUpdate update,
    required LanPairingDirectionProof observed,
  }) async {
    _emit(_pairingDirectionController, update.notice);
    switch (update.decision) {
      case LanReciprocalPairingDecision.rejected:
        return null;
      case LanReciprocalPairingDecision.waiting:
        _emitObservedPeer(observed);
        return LanPairingHandshakeProgress.waitingForPeer;
      case LanReciprocalPairingDecision.committed:
        final proof = update.commitProof;
        if (proof == null) return null;
        await securityService.savePeerTrustRecord(
          deviceId: proof.peerDeviceId,
          certificateFingerprint: proof.certificateFingerprint,
          inboundAccessToken: proof.inboundAccessToken,
          outboundAccessToken: proof.outboundAccessToken,
          x25519PublicKey: proof.x25519PublicKey,
          networkIdentityPublicKey: proof.networkIdentityPublicKey,
        );
        _emitObservedPeer(proof);
        final pairedPeer = _peerFromPairingProof(proof);
        final pairingObserver = onPairingCommitted;
        if (pairingObserver != null) await pairingObserver(pairedPeer);
        _emit(_handshakeSuccessController, pairedPeer);
        return LanPairingHandshakeProgress.paired;
    }
  }
}
