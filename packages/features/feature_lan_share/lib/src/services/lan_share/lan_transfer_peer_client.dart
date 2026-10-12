part of 'lan_transfer_service.dart';

final class _PairingInviteAttempt {
  bool cancelled = false;
  HttpClient? client;
  final done = Completer<void>();
}

extension LanTransferPeerClient on LanTransferService {
  /// Stops only the pending invitation request, never trust or shared runtime.
  void cancelPairingInvite(String peerId) {
    final attempt = _pairingInviteAttempts[peerId];
    if (attempt == null) return;
    attempt.cancelled = true;
    attempt.client?.close(force: true);
  }

  /// 广播本机存在，并返回对端端点。
  Future<NetworkResult<LanPairingEndpoint>> sendAnnouncement(
    LanDiscoveredPeer targetDevice,
    String localAlias,
  ) async {
    return _executeWithRetry(
      () async {
        final url = _lanEndpoint(targetDevice, '/api/lan/announce');
        final client = await _createHttpClient(
          peerDeviceId: targetDevice.deviceId,
        );

        try {
          final request = await client
              .postUrl(url)
              .timeout(const Duration(seconds: 4));
          request.followRedirects = false;
          request.headers.contentType = ContentType.json;
          request.write(
            jsonEncode({
              'id': currentDeviceId,
              'alias': localAlias,
              'os': Platform.operatingSystem,
              'port': activePort,
            }),
          );

          final response = await request.close().timeout(
            const Duration(seconds: 4),
          );
          final json = await readBoundedJsonResponse(response);
          if (response.statusCode != HttpStatus.ok) {
            throw lanHttpException(
              statusCode: response.statusCode,
              body: json,
              operation: NetworkOperation.sendAnnouncement,
              peerId: targetDevice.deviceId,
              fallbackMessage: 'LAN announcement was rejected.',
            );
          }
          final remoteDeviceId = json['deviceId'];
          final remotePort = json['port'];
          if (remoteDeviceId is! String ||
              remoteDeviceId.isEmpty ||
              remotePort is! num ||
              remotePort < 1 ||
              remotePort > 65535) {
            throw LanNetworkException(
              'LAN announcement response is invalid.',
              code: NetworkErrorCode.invalidArgument,
              operation: NetworkOperation.sendAnnouncement,
              peerId: targetDevice.deviceId,
              statusCode: response.statusCode,
            );
          }
          return NetworkSuccess(
            LanPairingEndpoint(
              remoteDeviceId: remoteDeviceId,
              remotePort: resolvePeer(targetDevice).controlPort,
            ),
          );
        } finally {
          client.close();
        }
      },
      peerId: targetDevice.deviceId,
      operation: NetworkOperation.sendAnnouncement,
    );
  }

  /// 邀请对端打开配对页面。PIN 握手仍是独立步骤，只有它可以建立信任。
  Future<NetworkResult<LanPairingEndpoint>> sendPairingInvite(
    LanDiscoveredPeer targetDevice,
    String localAlias, {
    required String sessionId,
    required DateTime expiresAt,
  }) async {
    NetworkFailure<LanPairingEndpoint> failure(NetworkErrorCode code) =>
        NetworkFailure(
          NetworkError(
            code: code,
            message: code == NetworkErrorCode.cancelled
                ? 'LAN pairing invitation cancelled.'
                : 'A pairing invitation is already connecting.',
            operation: NetworkOperation.sendPairingInvite,
            peerId: targetDevice.deviceId,
          ),
        );
    if (_closing || _closed) return failure(NetworkErrorCode.cancelled);
    if (_pairingInviteAttempts.containsKey(targetDevice.deviceId)) {
      return failure(NetworkErrorCode.invalidState);
    }
    final attempt = _PairingInviteAttempt();
    _pairingInviteAttempts[targetDevice.deviceId] = attempt;
    try {
      final url = _lanEndpoint(targetDevice, '/api/lan/pairing_invite');
      final client = await _createHttpClient(
        peerDeviceId: targetDevice.deviceId,
        allowUntrusted: true,
      );
      attempt.client = client;
      if (attempt.cancelled || _closing || _closed) {
        return failure(NetworkErrorCode.cancelled);
      }
      final validForMs = expiresAt
          .difference(DateTime.now())
          .inMilliseconds
          .clamp(1, const Duration(minutes: 2).inMilliseconds);
      final request = await client
          .postUrl(url)
          .timeout(const Duration(seconds: 4));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'deviceId': currentDeviceId,
          'alias': localAlias,
          'os': Platform.operatingSystem,
          'port': activePort,
          'sessionId': sessionId,
          'validForMs': validForMs,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      final json = await readBoundedJsonResponse(response);
      if (attempt.cancelled || _closing || _closed) {
        return failure(NetworkErrorCode.cancelled);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw lanHttpException(
          statusCode: response.statusCode,
          body: json,
          operation: NetworkOperation.sendPairingInvite,
          peerId: targetDevice.deviceId,
          fallbackMessage: 'LAN pairing invitation was rejected.',
        );
      }
      final remoteDeviceId = json['deviceId'];
      final remotePort = json['port'];
      if (remoteDeviceId is! String ||
          remoteDeviceId.isEmpty ||
          remotePort is! num ||
          remotePort < 1 ||
          remotePort > 65535) {
        throw const FormatException('Invalid LAN pairing endpoint response.');
      }
      return NetworkSuccess(
        LanPairingEndpoint(
          remoteDeviceId: remoteDeviceId,
          remotePort: resolvePeer(targetDevice).controlPort,
        ),
      );
    } catch (e) {
      if (attempt.cancelled || _closing || _closed) {
        return failure(NetworkErrorCode.cancelled);
      }
      return NetworkFailure(
        lanNetworkError(
          e,
          operation: NetworkOperation.sendPairingInvite,
          peerId: targetDevice.deviceId,
        ),
      );
    } finally {
      attempt.client?.close(force: true);
      if (identical(_pairingInviteAttempts[targetDevice.deviceId], attempt)) {
        _pairingInviteAttempts.remove(targetDevice.deviceId);
      }
      attempt.done.complete();
    }
  }
}
