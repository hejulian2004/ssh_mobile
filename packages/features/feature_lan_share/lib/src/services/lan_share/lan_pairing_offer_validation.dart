part of 'lan_transfer_service.dart';

/// 保存服务端返回且已通过绑定校验的配对凭据。
class _ValidatedPairingCredential {
  final String accessToken;
  final String certFingerprint;
  final String status;
  final Uint8List x25519PublicKey;
  final Uint8List networkIdentityPublicKey;

  const _ValidatedPairingCredential({
    required this.accessToken,
    required this.certFingerprint,
    required this.status,
    required this.x25519PublicKey,
    required this.networkIdentityPublicKey,
  });
}

/// 保存通过 SRP/TLS 校验且绑定 V2 静态身份的配对 offer。
class _AcceptedPairingOffer {
  final String handshakeId;
  final LanPairingSessionSecrets sessionSecrets;
  final String certFingerprint;
  final Uint8List serverX25519PublicKey;
  final Uint8List serverNetworkIdentityPublicKey;

  const _AcceptedPairingOffer({
    required this.handshakeId,
    required this.sessionSecrets,
    required this.certFingerprint,
    required this.serverX25519PublicKey,
    required this.serverNetworkIdentityPublicKey,
  });
}

final class _HandshakeConfirmStarted implements Exception {
  const _HandshakeConfirmStarted(this.cause);

  final Object cause;
}

bool _constantTimeBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

extension LanPairingOfferValidation on LanTransferService {
  /// 校验配对凭据的会话、设备、请求摘要和有效期绑定。
  _ValidatedPairingCredential _validatePairingCredential(
    Map<String, dynamic> credential, {
    required String expectedNonce,
    required String expectedHandshakeId,
    required String expectedRequestHash,
    required String expectedIssuerDeviceId,
    required String expectedRecipientDeviceId,
    required Duration elapsed,
  }) {
    final protocolVersion = credential['protocolVersion'];
    final accessToken = credential['accessToken'];
    final fingerprint = credential['certFingerprint'];
    final status = credential['status'];
    final requestNonce = credential['requestNonce'];
    final handshakeId = credential['handshakeId'];
    final requestHash = credential['requestHash'];
    final issuerDeviceId = credential['issuerDeviceId'];
    final recipientDeviceId = credential['recipientDeviceId'];
    final encodedX25519PublicKey = credential['x25519PubKey'];
    final encodedNetworkIdentityPublicKey = credential['networkIdentityPubKey'];
    final validForMs = credential['validForMs'];

    if (protocolVersion != LanPairingCrypto.protocolVersion ||
        accessToken is! String ||
        accessToken.isEmpty ||
        accessToken.length > 256 ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fingerprint) ||
        status != 'paired' ||
        requestNonce != expectedNonce ||
        handshakeId != expectedHandshakeId ||
        requestHash != expectedRequestHash ||
        issuerDeviceId != expectedIssuerDeviceId ||
        recipientDeviceId != expectedRecipientDeviceId ||
        encodedX25519PublicKey is! String ||
        encodedNetworkIdentityPublicKey is! String ||
        validForMs is! int ||
        validForMs <= 0 ||
        validForMs > LanPairingCrypto.credentialTtlMillis ||
        elapsed.inMilliseconds > validForMs) {
      throw const FormatException(
        'Pairing response credential binding is invalid or expired',
      );
    }

    final x25519PublicKey = LanPairingCrypto.decodePublicKey(
      encodedX25519PublicKey,
      'peer X25519 public key',
    );
    final networkIdentityPublicKey = LanPairingCrypto.decodePublicKey(
      encodedNetworkIdentityPublicKey,
      'peer network identity public key',
    );
    return _ValidatedPairingCredential(
      accessToken: accessToken,
      certFingerprint: fingerprint,
      status: status as String,
      x25519PublicKey: x25519PublicKey,
      networkIdentityPublicKey: networkIdentityPublicKey,
    );
  }

  /// 为定向协议测试校验配对凭据绑定。
  @visibleForTesting
  bool isPairingCredentialBindingValidForTesting(
    Map<String, dynamic> credential, {
    required String expectedNonce,
    required String expectedHandshakeId,
    required String expectedRequestHash,
    required String expectedIssuerDeviceId,
    required String expectedRecipientDeviceId,
    Duration elapsed = Duration.zero,
  }) {
    try {
      _validatePairingCredential(
        credential,
        expectedNonce: expectedNonce,
        expectedHandshakeId: expectedHandshakeId,
        expectedRequestHash: expectedRequestHash,
        expectedIssuerDeviceId: expectedIssuerDeviceId,
        expectedRecipientDeviceId: expectedRecipientDeviceId,
        elapsed: elapsed,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 完成本地校验后接受远端配对邀请。
  /// 尝试解密并验证一个服务端配对 offer。
  Future<_AcceptedPairingOffer?> _acceptPairingOffer(
    Map<String, dynamic> offer, {
    required List<LanPairingEphemeralKeyPair> clientKeys,
    required String clientContext,
    required String serverFingerprint,
    required Uint8List serverX25519PublicKey,
    required Uint8List serverNetworkIdentityPublicKey,
  }) async {
    final handshakeId = offer['handshakeId'];
    final slot = offer['slot'];
    final saltB64 = offer['salt'];
    final serverPublicValueB64 = offer['serverPublicValue'];
    final serverProof = offer['serverProof'];
    if (handshakeId is! String ||
        handshakeId.length < 16 ||
        handshakeId.length > 128 ||
        slot is! int ||
        slot < 0 ||
        slot >= clientKeys.length ||
        saltB64 is! String ||
        saltB64.length > 128 ||
        serverPublicValueB64 is! String ||
        serverPublicValueB64.length > 1024 ||
        serverProof is! String ||
        serverProof.isEmpty ||
        serverProof.length > 256) {
      return null;
    }
    try {
      final keys = clientKeys[slot];
      final salt = base64.decode(saltB64);
      if (salt.length != 32 || !listEquals(salt, keys.salt)) {
        return null;
      }
      final serverPublicValue = base64.decode(serverPublicValueB64);
      if (serverPublicValue.length != LanPairingCrypto.publicValueBytes ||
          !LanPairingCrypto.isValidPublicValueForTesting(serverPublicValue)) {
        return null;
      }
      final associatedData = LanPairingCrypto.sessionAssociatedData(
        clientContext: clientContext,
        handshakeId: handshakeId,
        slot: slot,
        salt: salt,
        clientPublicValue: keys.publicValue,
        serverPublicValue: serverPublicValue,
        serverCertFingerprint: serverFingerprint,
        serverX25519PublicKey: serverX25519PublicKey,
        serverNetworkIdentityPublicKey: serverNetworkIdentityPublicKey,
      );
      final sessionSecrets = LanPairingCrypto.deriveSessionSecrets(
        localKeyPair: keys,
        remotePublicValue: serverPublicValue,
        associatedData: associatedData,
      );
      if (!LanPairingCrypto.verifyServerProof(sessionSecrets, serverProof)) {
        return null;
      }
      return _AcceptedPairingOffer(
        handshakeId: handshakeId,
        sessionSecrets: sessionSecrets,
        certFingerprint: serverFingerprint,
        serverX25519PublicKey: Uint8List.fromList(serverX25519PublicKey),
        serverNetworkIdentityPublicKey: Uint8List.fromList(
          serverNetworkIdentityPublicKey,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}
