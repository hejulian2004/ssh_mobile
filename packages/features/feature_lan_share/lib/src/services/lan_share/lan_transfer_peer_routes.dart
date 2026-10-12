part of 'lan_transfer_service.dart';

extension LanTransferPeerRoutes on LanTransferService {
  /// 校验并记录对端广播。
  Future<void> _handleAnnounceRequest(HttpRequest request) async {
    final json = await _protocolGuard.readJson(request);

    final senderId = json['id'] is String ? (json['id'] as String).trim() : '';
    final alias = json['alias'] is String
        ? (json['alias'] as String).trim()
        : '';
    final os = json['os'] is String ? (json['os'] as String).trim() : '';
    var hostIp = request.connectionInfo?.remoteAddress.address ?? '';
    if (hostIp.startsWith('::ffff:')) {
      hostIp = hostIp.substring(7);
    }
    final port =
        (json['port'] as num?)?.toInt() ?? LanTransferService.defaultHttpPort;

    if (senderId.isEmpty ||
        senderId == currentDeviceId ||
        senderId.length > 128 ||
        alias.isEmpty ||
        alias.length > 128 ||
        os.isEmpty ||
        os.length > 64 ||
        hostIp.isEmpty ||
        port < 1 ||
        port > 65535) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid device announcement.',
      );
    }
    _protocolGuard.checkPairingInviteRate(hostIp);
    {
      final peer = resolvePeer(
        LanDiscoveredPeer(
          deviceId: senderId,
          alias: alias,
          ip: hostIp,
          controlPort: port,
          deviceType: _guessDeviceType(os),
          os: os,
          lastSeen: DateTime.now(),
        ),
      );
      _emit(_announcedPeerController, peer);
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'deviceId': currentDeviceId, 'port': activePort}),
    );
    await request.response.close();
  }

  /// 校验并记录传入配对邀请。
  Future<void> _handlePairingInviteRequest(HttpRequest request) async {
    final json = await _protocolGuard.readJson(request);
    final senderId = json['deviceId'] is String
        ? (json['deviceId'] as String).trim()
        : '';
    final sessionId = json['sessionId'] is String
        ? (json['sessionId'] as String).trim()
        : '';
    final validForMs = (json['validForMs'] as num?)?.toInt() ?? 0;
    final alias = json['alias'] is String
        ? (json['alias'] as String).trim()
        : '';
    final os = json['os'] is String ? (json['os'] as String).trim() : '';
    final port =
        (json['port'] as num?)?.toInt() ?? LanTransferService.defaultHttpPort;
    if (senderId.isEmpty ||
        senderId == currentDeviceId ||
        senderId.length > 128 ||
        sessionId.isEmpty ||
        sessionId.length > 128 ||
        alias.isEmpty ||
        alias.length > 128 ||
        os.isEmpty ||
        os.length > 64 ||
        port < 1 ||
        port > 65535 ||
        validForMs <= 0 ||
        validForMs > const Duration(minutes: 2).inMilliseconds) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid pairing invitation.',
      );
    }
    final expiresAt = DateTime.now().add(Duration(milliseconds: validForMs));
    var hostIp = request.connectionInfo?.remoteAddress.address ?? '';
    if (hostIp.startsWith('::ffff:')) {
      hostIp = hostIp.substring(7);
    }
    if (hostIp.isEmpty) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Pairing invitation has no source address.',
      );
    }
    _protocolGuard.checkPairingInviteRate(hostIp);
    final peer = resolvePeer(
      LanDiscoveredPeer(
        deviceId: senderId,
        alias: alias,
        ip: hostIp,
        controlPort: port,
        deviceType: _guessDeviceType(os),
        os: os,
        lastSeen: DateTime.now(),
      ),
    );
    _emit(
      _pairingInviteController,
      LanPairingRequest(
        peer: LanPeerViewState(discovery: peer),
        sessionId: sessionId,
        isIncoming: true,
        expiresAt: expiresAt,
      ),
    );
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'deviceId': currentDeviceId, 'port': activePort}),
    );
    await request.response.close();
  }

  /// 将对端操作系统标签映射为功能使用的设备类别。
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
}
