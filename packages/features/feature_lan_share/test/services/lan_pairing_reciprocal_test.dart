import 'dart:typed_data';

import 'package:feature_lan_share/src/services/lan_share/lan_pairing_reciprocal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one verified direction does not commit trust material', () {
    final gate = LanReciprocalPairingGate();
    final update = gate.noteOutbound(
      _proof(
        peerId: 'peer-b',
        initiatorId: 'peer-a',
        tokenIn: 'a-in',
        tokenOut: 'b-out',
      ),
      now: _t0,
    );

    expect(update.decision, LanReciprocalPairingDecision.waiting);
    expect(update.commitProof, isNull);
    expect(update.notice.outboundVerified, isTrue);
    expect(update.notice.inboundVerified, isFalse);
    expect(gate.hasPending('peer-b', now: _t0), isTrue);
  });

  test(
    'confirm rejection drops pending material so one later direction waits',
    () {
      final gate = LanReciprocalPairingGate();
      gate.noteOutbound(
        _proof(
          peerId: 'peer-b',
          initiatorId: 'peer-a',
          tokenIn: 'a-in',
          tokenOut: 'b-out',
        ),
        now: _t0,
      );
      gate.noteInbound(
        _proof(
          peerId: 'peer-b',
          initiatorId: 'peer-b',
          tokenIn: 'b-in',
          tokenOut: 'a-out',
        ),
        now: _t0,
      );

      gate.discard('peer-b');

      expect(gate.noticeFor('peer-b', now: _t0), isNull);
      expect(gate.hasPending('peer-b', now: _t0), isFalse);
      final again = gate.noteInbound(
        _proof(
          peerId: 'peer-b',
          initiatorId: 'peer-b',
          tokenIn: 'b-in',
          tokenOut: 'a-out',
        ),
        now: _t0.add(const Duration(seconds: 1)),
      );
      expect(again.decision, LanReciprocalPairingDecision.waiting);
      expect(again.commitProof, isNull);
    },
  );

  test('identity mismatch discards both directions', () {
    final gate = LanReciprocalPairingGate();
    gate.noteOutbound(
      _proof(
        peerId: 'peer-b',
        initiatorId: 'peer-a',
        tokenIn: 'a-in',
        tokenOut: 'b-out',
      ),
      now: _t0,
    );
    final rejected = gate.noteInbound(
      _proof(
        peerId: 'peer-b',
        initiatorId: 'peer-b',
        tokenIn: 'b-in',
        tokenOut: 'a-out',
        fingerprint: _otherFingerprint,
      ),
      now: _t0,
    );

    expect(rejected.decision, LanReciprocalPairingDecision.rejected);
    expect(rejected.commitProof, isNull);
    expect(gate.hasPending('peer-b', now: _t0), isFalse);
  });

  test('both directions commit the lexicographically smaller initiator', () {
    final local = LanReciprocalPairingGate();
    final remote = LanReciprocalPairingGate();
    final smaller = _proof(
      peerId: 'peer-z',
      initiatorId: 'peer-a',
      tokenIn: 'token-from-a',
      tokenOut: 'token-from-z',
      alias: 'Z',
    );
    final largerOnLocal = _proof(
      peerId: 'peer-z',
      initiatorId: 'peer-z',
      tokenIn: 'discard-in',
      tokenOut: 'discard-out',
    );
    final largerOnRemote = _proof(
      peerId: 'peer-a',
      initiatorId: 'peer-z',
      tokenIn: 'discard-out',
      tokenOut: 'discard-in',
    );
    final smallerOnRemote = _proof(
      peerId: 'peer-a',
      initiatorId: 'peer-a',
      tokenIn: 'token-from-z',
      tokenOut: 'token-from-a',
      alias: 'A',
    );

    local.noteOutbound(smaller, now: _t0);
    remote.noteInbound(smallerOnRemote, now: _t0);
    final localCommit = local.noteInbound(largerOnLocal, now: _t0);
    final remoteCommit = remote.noteOutbound(largerOnRemote, now: _t0);

    expect(localCommit.decision, LanReciprocalPairingDecision.committed);
    expect(remoteCommit.decision, LanReciprocalPairingDecision.committed);
    expect(localCommit.commitProof!.initiatorDeviceId, 'peer-a');
    expect(remoteCommit.commitProof!.initiatorDeviceId, 'peer-a');
    expect(localCommit.commitProof!.inboundAccessToken, 'token-from-a');
    expect(localCommit.commitProof!.outboundAccessToken, 'token-from-z');
    expect(remoteCommit.commitProof!.inboundAccessToken, 'token-from-z');
    expect(remoteCommit.commitProof!.outboundAccessToken, 'token-from-a');
    expect(local.hasPending('peer-z', now: _t0), isFalse);
    expect(remote.hasPending('peer-a', now: _t0), isFalse);
  });

  test('a replaced direction is the one eligible for commit', () {
    final gate = LanReciprocalPairingGate();
    gate.noteOutbound(
      _proof(
        peerId: 'peer-b',
        initiatorId: 'peer-a',
        tokenIn: 'old-in',
        tokenOut: 'old-out',
      ),
      now: _t0,
    );
    gate.noteOutbound(
      _proof(
        peerId: 'peer-b',
        initiatorId: 'peer-a',
        tokenIn: 'new-in',
        tokenOut: 'new-out',
      ),
      now: _t0.add(const Duration(seconds: 5)),
    );
    final committed = gate.noteInbound(
      _proof(
        peerId: 'peer-b',
        initiatorId: 'peer-z',
        tokenIn: 'peer-in',
        tokenOut: 'peer-out',
      ),
      now: _t0.add(const Duration(seconds: 6)),
    );

    expect(committed.commitProof!.inboundAccessToken, 'new-in');
    expect(committed.commitProof!.outboundAccessToken, 'new-out');
  });

  test(
    'material older than two minutes cannot combine with a new direction',
    () {
      final gate = LanReciprocalPairingGate();
      gate.noteOutbound(
        _proof(
          peerId: 'peer-b',
          initiatorId: 'peer-a',
          tokenIn: 'old-in',
          tokenOut: 'old-out',
        ),
        now: _t0,
      );

      final atBoundary = _t0.add(LanReciprocalPairingGate.pendingTtl);
      expect(gate.hasPending('peer-b', now: atBoundary), isTrue);

      final expiredAt = atBoundary.add(const Duration(microseconds: 1));
      expect(gate.noticeFor('peer-b', now: expiredAt), isNull);
      final fresh = gate.noteInbound(
        _proof(
          peerId: 'peer-b',
          initiatorId: 'peer-b',
          tokenIn: 'new-in',
          tokenOut: 'new-out',
        ),
        now: expiredAt,
      );
      expect(fresh.decision, LanReciprocalPairingDecision.waiting);
      expect(fresh.notice.outboundVerified, isFalse);
      expect(fresh.commitProof, isNull);
    },
  );

  test('certificate fingerprint comparison ignores case', () {
    final gate = LanReciprocalPairingGate();
    gate.noteOutbound(
      _proof(
        peerId: 'peer-b',
        initiatorId: 'peer-a',
        tokenIn: 'a-in',
        tokenOut: 'b-out',
        fingerprint: _fingerprint.toUpperCase(),
      ),
      now: _t0,
    );
    final committed = gate.noteInbound(
      _proof(
        peerId: 'peer-b',
        initiatorId: 'peer-b',
        tokenIn: 'b-in',
        tokenOut: 'a-out',
      ),
      now: _t0,
    );

    expect(committed.decision, LanReciprocalPairingDecision.committed);
  });

  test('direction hints describe the single verified side', () {
    const outbound = LanPairingDirectionNotice(
      peerId: 'peer-b',
      outboundVerified: true,
      inboundVerified: false,
    );
    const inbound = LanPairingDirectionNotice(
      peerId: 'peer-b',
      outboundVerified: false,
      inboundVerified: true,
    );

    expect(
      pairingDirectionHint(outbound, english: false),
      '已确认对方 PIN，请等待对方输入本机 PIN。',
    );
    expect(
      pairingDirectionHint(inbound, english: true),
      'The other device entered this PIN. Enter the PIN shown on that device.',
    );
    expect(
      pairingDirectionHint(
        const LanPairingDirectionNotice(
          peerId: 'peer-b',
          outboundVerified: true,
          inboundVerified: true,
        ),
        english: true,
      ),
      isNull,
    );
  });
}

const String _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const String _otherFingerprint =
    'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
final DateTime _t0 = DateTime.utc(2026, 9, 29, 12);

LanPairingDirectionProof _proof({
  required String peerId,
  required String initiatorId,
  required String tokenIn,
  required String tokenOut,
  String fingerprint = _fingerprint,
  String alias = 'Peer',
}) {
  return LanPairingDirectionProof(
    peerDeviceId: peerId,
    initiatorDeviceId: initiatorId,
    certificateFingerprint: fingerprint,
    x25519PublicKey: Uint8List(32),
    networkIdentityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
    inboundAccessToken: tokenIn,
    outboundAccessToken: tokenOut,
    alias: alias,
    ip: '192.168.1.20',
    controlPort: 53317,
    os: 'windows',
    notedAt: _t0,
  );
}
