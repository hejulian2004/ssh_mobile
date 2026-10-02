// 从传输服务拆出的 LAN Control Protocol V2 配对确认处理逻辑。

part of 'lan_transfer_service.dart';

extension _LanPairingConfirmationOperations on LanTransferService {
  /// 校验配对证明并返回加密凭据。
  Future<void> _handleSecureHandshakeConfirm(
    HttpRequest request,
    Map<String, dynamic> json,
  ) async {
    final handshakeId = _trimmedPairingField(json, 'handshakeId');
    final senderDeviceId = _trimmedPairingField(json, 'deviceId');
    final targetDeviceId = _trimmedPairingField(json, 'targetDeviceId');
    final nonce = _trimmedPairingField(json, 'nonce');
    final clientProof = _trimmedPairingField(json, 'clientProof');
    final encryptedInboundCredential = _trimmedPairingField(json, 'credential');
    if (handshakeId.length < 16 ||
        handshakeId.length > 128 ||
        senderDeviceId.isEmpty ||
        senderDeviceId.length > 128 ||
        targetDeviceId != currentDeviceId ||
        nonce.length < 16 ||
        nonce.length > 128 ||
        clientProof.isEmpty ||
        clientProof.length > 256 ||
        encryptedInboundCredential.isEmpty ||
        encryptedInboundCredential.length > 4096) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN pairing confirmation.',
      );
    }

    _prunePendingPairingHandshakes();
    final pending = _pendingPairingHandshakes[handshakeId];
    final remoteAddress = _pairingRemoteAddress(request);
    if (pending == null ||
        pending.isExpired ||
        pending.senderDeviceId != senderDeviceId ||
        pending.nonce != nonce ||
        pending.remoteAddress != remoteAddress) {
      throw const LanHttpException(
        HttpStatus.unauthorized,
        'LAN pairing confirmation is invalid or expired.',
      );
    }
    _pendingPairingHandshakes.remove(handshakeId);
    if (!LanPairingCrypto.verifyClientProof(
      pending.sessionSecrets,
      clientProof,
    )) {
      _failPairingAuthentication(senderDeviceId);
    }

    final credentialAssociatedData = LanPairingCrypto.credentialAssociatedData(
      handshakeId: handshakeId,
      nonce: nonce,
      issuerDeviceId: senderDeviceId,
      recipientDeviceId: currentDeviceId,
    );
    late final String senderInboundAccessToken;
    try {
      final decodedCredential = await LanPairingCrypto.decryptCredential(
        encryptedInboundCredential,
        pending.sessionSecrets.sessionKey,
        associatedData: credentialAssociatedData,
      );
      final token = decodedCredential['inboundAccessToken'];
      if (token is! String || token.isEmpty || token.length > 256) {
        throw const FormatException();
      }
      senderInboundAccessToken = token;
    } catch (_) {
      _failPairingAuthentication(senderDeviceId);
    }

    if (!LanPairingCrypto.verifyAccessTokenHash(
      senderInboundAccessToken,
      pending.senderInboundAccessTokenHash,
    )) {
      _failPairingAuthentication(senderDeviceId);
    }

    _protocolGuard.checkPairingNonce(senderDeviceId, nonce);
    final accessToken = securityService.createPairingAccessToken();
    const status = 'paired';
    final requestHash = LanPairingCrypto.requestHash(pending.clientContext);
    final associatedData = LanPairingCrypto.credentialAssociatedData(
      handshakeId: handshakeId,
      nonce: nonce,
      issuerDeviceId: currentDeviceId,
      recipientDeviceId: senderDeviceId,
    );
    final encryptedCredential = await LanPairingCrypto.encryptCredential(
      {
        'protocolVersion': LanPairingCrypto.protocolVersion,
        'accessToken': accessToken,
        'status': status,
        'certFingerprint': pending.serverCertFingerprint,
        'requestNonce': nonce,
        'handshakeId': handshakeId,
        'requestHash': requestHash,
        'issuerDeviceId': currentDeviceId,
        'recipientDeviceId': senderDeviceId,
        'x25519PubKey': base64UrlEncode(pending.serverX25519PublicKey),
        'networkIdentityPubKey': base64UrlEncode(
          pending.serverNetworkIdentityPublicKey,
        ),
        'validForMs': LanPairingCrypto.credentialTtlMillis,
      },
      pending.sessionSecrets.sessionKey,
      associatedData: associatedData,
    );

    // One verified PIN is held in memory. Trust is written only when the
    // opposite direction proves the same certificate and public keys.
    final proof = LanPairingDirectionProof(
      peerDeviceId: senderDeviceId,
      initiatorDeviceId: senderDeviceId,
      certificateFingerprint: pending.senderCertFingerprint,
      x25519PublicKey: pending.senderX25519PublicKey,
      networkIdentityPublicKey: pending.senderNetworkIdentityPublicKey,
      inboundAccessToken: accessToken,
      outboundAccessToken: senderInboundAccessToken,
      alias: pending.alias,
      ip: remoteAddress,
      controlPort: pending.port,
      os: pending.os,
      notedAt: DateTime.now(),
    );
    final update = _reciprocalPairing.noteInbound(proof);
    try {
      final progress = await _applyReciprocalUpdate(
        update: update,
        observed: proof,
      );
      if (progress == null) {
        throw const LanHttpException(
          HttpStatus.unauthorized,
          'LAN pairing authentication failed.',
          discardPairingProofs: true,
        );
      }
    } on StateError {
      _discardReciprocalPairing(senderDeviceId);
      throw const LanHttpException(
        HttpStatus.conflict,
        'The device certificate changed. Unpair the device before re-pairing.',
        discardPairingProofs: true,
      );
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'protocolVersion': LanPairingCrypto.protocolVersion,
        'status': status,
        'credential': encryptedCredential,
      }),
    );
    await request.response.close();
  }
}
