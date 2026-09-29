// In-memory progress for one reciprocal LAN Control V2 pairing.
//
// Each direction still proves one displayed PIN through the existing SRP
// handshake. Trust is not decided here: callers persist a record only after
// this gate returns [LanReciprocalPairingDecision.committed].

import 'dart:typed_data';

/// Result of one local handshake attempt after the reciprocal check.
enum LanPairingHandshakeProgress { waitingForPeer, paired }

/// What the in-memory gate decided for the peer slot.
enum LanReciprocalPairingDecision { waiting, committed, rejected }

/// One verified direction of a V2 handshake, from this device's point of view.
///
/// Tokens are the pair this device would store if this handshake is the one
/// whose initiator device id is lexicographically smaller. The opposite
/// handshake is proof only and its tokens are discarded at commit.
class LanPairingDirectionProof {
  LanPairingDirectionProof({
    required this.peerDeviceId,
    required this.initiatorDeviceId,
    required this.certificateFingerprint,
    required List<int> x25519PublicKey,
    required List<int> networkIdentityPublicKey,
    required this.inboundAccessToken,
    required this.outboundAccessToken,
    required this.alias,
    required this.ip,
    required this.controlPort,
    required this.os,
    required this.notedAt,
  }) : x25519PublicKey = Uint8List.fromList(x25519PublicKey),
       networkIdentityPublicKey = Uint8List.fromList(networkIdentityPublicKey);

  final String peerDeviceId;
  final String initiatorDeviceId;
  final String certificateFingerprint;
  final Uint8List x25519PublicKey;
  final Uint8List networkIdentityPublicKey;
  final String inboundAccessToken;
  final String outboundAccessToken;
  final String alias;
  final String ip;
  final int controlPort;
  final String os;
  final DateTime notedAt;

  /// Returns a copy with a caller-controlled observation time.
  LanPairingDirectionProof copyWith({DateTime? notedAt}) {
    return LanPairingDirectionProof(
      peerDeviceId: peerDeviceId,
      initiatorDeviceId: initiatorDeviceId,
      certificateFingerprint: certificateFingerprint,
      x25519PublicKey: x25519PublicKey,
      networkIdentityPublicKey: networkIdentityPublicKey,
      inboundAccessToken: inboundAccessToken,
      outboundAccessToken: outboundAccessToken,
      alias: alias,
      ip: ip,
      controlPort: controlPort,
      os: os,
      notedAt: notedAt ?? this.notedAt,
    );
  }
}

/// UI-facing flags for which PIN directions are currently verified.
class LanPairingDirectionNotice {
  const LanPairingDirectionNotice({
    required this.peerId,
    required this.outboundVerified,
    required this.inboundVerified,
  });

  final String peerId;
  final bool outboundVerified;
  final bool inboundVerified;
}

/// Gate outcome, including the proof to persist when both directions match.
class LanReciprocalPairingUpdate {
  const LanReciprocalPairingUpdate({
    required this.decision,
    required this.notice,
    this.commitProof,
  });

  final LanReciprocalPairingDecision decision;
  final LanPairingDirectionNotice notice;
  final LanPairingDirectionProof? commitProof;
}

class _PairingDirectionSlot {
  LanPairingDirectionProof? outbound;
  LanPairingDirectionProof? inbound;
}

/// Holds at most one outbound and one inbound proof per peer.
///
/// A single direction does not commit. Identity mismatch, an explicit discard,
/// or material older than [pendingTtl] drops the whole slot. A later note after
/// expiry starts a new slot instead of combining with the stale proof.
class LanReciprocalPairingGate {
  static const Duration pendingTtl = Duration(minutes: 2);

  final Map<String, _PairingDirectionSlot> _slots = {};

  /// Records that this device proved it knows the peer's displayed PIN.
  LanReciprocalPairingUpdate noteOutbound(
    LanPairingDirectionProof proof, {
    DateTime? now,
  }) {
    return _note(proof, outbound: true, now: now ?? DateTime.now());
  }

  /// Records that the peer proved it knows this device's displayed PIN.
  LanReciprocalPairingUpdate noteInbound(
    LanPairingDirectionProof proof, {
    DateTime? now,
  }) {
    return _note(proof, outbound: false, now: now ?? DateTime.now());
  }

  /// Drops every pending proof for [peerId].
  void discard(String peerId) {
    _slots.remove(peerId);
  }

  /// Drops every pending pairing.
  void clear() {
    _slots.clear();
  }

  /// Returns the unexpired direction flags, or null when nothing is pending.
  LanPairingDirectionNotice? noticeFor(String peerId, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final slot = _slots[peerId];
    if (slot == null) return null;
    final outboundOk = _isFresh(slot.outbound, clock);
    final inboundOk = _isFresh(slot.inbound, clock);
    if (!outboundOk) slot.outbound = null;
    if (!inboundOk) slot.inbound = null;
    if (!outboundOk && !inboundOk) {
      _slots.remove(peerId);
      return null;
    }
    return LanPairingDirectionNotice(
      peerId: peerId,
      outboundVerified: outboundOk,
      inboundVerified: inboundOk,
    );
  }

  /// Whether a PIN direction for [peerId] is still inside [pendingTtl].
  bool hasPending(String peerId, {DateTime? now}) {
    final notice = noticeFor(peerId, now: now);
    if (notice == null) return false;
    return notice.outboundVerified || notice.inboundVerified;
  }

  LanReciprocalPairingUpdate _note(
    LanPairingDirectionProof proof, {
    required bool outbound,
    required DateTime now,
  }) {
    final peerId = proof.peerDeviceId.trim();
    if (peerId.isEmpty) {
      return LanReciprocalPairingUpdate(
        decision: LanReciprocalPairingDecision.rejected,
        notice: LanPairingDirectionNotice(
          peerId: peerId,
          outboundVerified: false,
          inboundVerified: false,
        ),
      );
    }
    final existing = _slots[peerId];
    if (existing != null && !_hasFreshProof(existing, now)) {
      _slots.remove(peerId);
    }
    final slot = _slots.putIfAbsent(peerId, _PairingDirectionSlot.new);
    final stamped = proof.copyWith(notedAt: now);
    if (outbound) {
      if (!_isFresh(slot.inbound, now)) slot.inbound = null;
      slot.outbound = stamped;
    } else {
      if (!_isFresh(slot.outbound, now)) slot.outbound = null;
      slot.inbound = stamped;
    }
    return _evaluate(peerId, slot);
  }

  LanReciprocalPairingUpdate _evaluate(
    String peerId,
    _PairingDirectionSlot slot,
  ) {
    final outbound = slot.outbound;
    final inbound = slot.inbound;
    if (outbound != null && inbound != null) {
      if (!_samePeerIdentity(outbound, inbound)) {
        _slots.remove(peerId);
        return LanReciprocalPairingUpdate(
          decision: LanReciprocalPairingDecision.rejected,
          notice: LanPairingDirectionNotice(
            peerId: peerId,
            outboundVerified: false,
            inboundVerified: false,
          ),
        );
      }
      final commit =
          outbound.initiatorDeviceId.compareTo(inbound.initiatorDeviceId) <= 0
          ? outbound
          : inbound;
      _slots.remove(peerId);
      return LanReciprocalPairingUpdate(
        decision: LanReciprocalPairingDecision.committed,
        commitProof: commit,
        notice: LanPairingDirectionNotice(
          peerId: peerId,
          outboundVerified: true,
          inboundVerified: true,
        ),
      );
    }
    return LanReciprocalPairingUpdate(
      decision: LanReciprocalPairingDecision.waiting,
      notice: LanPairingDirectionNotice(
        peerId: peerId,
        outboundVerified: outbound != null,
        inboundVerified: inbound != null,
      ),
    );
  }

  bool _hasFreshProof(_PairingDirectionSlot slot, DateTime now) {
    return _isFresh(slot.outbound, now) || _isFresh(slot.inbound, now);
  }

  bool _isFresh(LanPairingDirectionProof? proof, DateTime now) {
    if (proof == null) return false;
    final age = now.difference(proof.notedAt);
    if (age.isNegative) return true;
    return age <= pendingTtl;
  }

  bool _samePeerIdentity(
    LanPairingDirectionProof left,
    LanPairingDirectionProof right,
  ) {
    return left.certificateFingerprint.toLowerCase() ==
            right.certificateFingerprint.toLowerCase() &&
        left.certificateFingerprint.length == 64 &&
        _sameKey(left.x25519PublicKey, right.x25519PublicKey) &&
        _sameKey(left.networkIdentityPublicKey, right.networkIdentityPublicKey);
  }

  bool _sameKey(Uint8List left, Uint8List right) {
    if (left.length != 32 || right.length != 32) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}

/// Hint shown while exactly one PIN direction is verified.
String? pairingDirectionHint(
  LanPairingDirectionNotice? notice, {
  required bool english,
}) {
  if (notice == null) return null;
  if (notice.outboundVerified && !notice.inboundVerified) {
    return english
        ? 'Your entry is confirmed. Waiting for the other device to enter this PIN.'
        : '已确认对方 PIN，请等待对方输入本机 PIN。';
  }
  if (notice.inboundVerified && !notice.outboundVerified) {
    return english
        ? 'The other device entered this PIN. Enter the PIN shown on that device.'
        : '对方已输入本机 PIN，请输入对方设备上显示的 PIN。';
  }
  return null;
}
