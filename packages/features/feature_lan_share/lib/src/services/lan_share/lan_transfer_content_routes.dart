part of 'lan_transfer_service.dart';

extension LanTransferContentRoutes on LanTransferService {
  /// 校验并接收文本/剪贴板元数据。
  ///
  /// Binary metadata is intentionally rejected. Files are transferred through
  /// Network V2 and never through this HTTPS control plane.
  Future<void> _handleMetaRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final e2ePubKeyHeader = request.headers.value('x-e2e-pubkey');
    final isEncrypted = e2ePubKeyHeader == '1';
    if (!isEncrypted) {
      throw const LanHttpException(
        HttpStatus.upgradeRequired,
        'LAN metadata requires application E2E encryption.',
      );
    }
    Map<String, dynamic> json;
    final blob = await _protocolGuard.readBytes(
      request,
      maxBytes: LanTransferProtocolGuard.maxMetadataBodyBytes + 60,
    );
    try {
      final plainBytes = await securityService.decryptE2E(blob);
      if (plainBytes.length > LanTransferProtocolGuard.maxMetadataBodyBytes) {
        throw const LanHttpException(
          HttpStatus.requestEntityTooLarge,
          'Metadata is too large.',
        );
      }
      final decoded = jsonDecode(utf8.decode(plainBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object.');
      }
      json = decoded;
    } on LanHttpException {
      rethrow;
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Encrypted metadata is invalid.',
      );
    }

    final payloadName = json['payloadType'];
    final validPayload =
        payloadName == LanPayloadType.text.name ||
        payloadName == LanPayloadType.clipboard.name;
    if (!validPayload) {
      throw const LanHttpException(
        HttpStatus.upgradeRequired,
        'Binary LAN payloads require Network V2 transfer.',
      );
    }

    late final LanMessage decodedMessage;
    try {
      decodedMessage = LanMessage.fromJson({
        ...json,
        'localPath': null,
        'isIncoming': true,
        'isRecalled': false,
      });
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN message metadata.',
      );
    }
    if (decodedMessage.id.isEmpty ||
        decodedMessage.id.length > 128 ||
        decodedMessage.senderId != senderDeviceId ||
        decodedMessage.receiverId != currentDeviceId ||
        decodedMessage.senderAlias.isEmpty ||
        decodedMessage.senderAlias.length > 128 ||
        decodedMessage.fileSize != 0 ||
        (decodedMessage.textContent?.length ?? 0) > 512 * 1024) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN message metadata.',
      );
    }

    final message = LanMessage(
      id: decodedMessage.id,
      senderId: senderDeviceId,
      senderAlias: decodedMessage.senderAlias,
      receiverId: currentDeviceId,
      payloadType: decodedMessage.payloadType,
      textContent: decodedMessage.textContent,
      fileName: null,
      fileSize: 0,
      status: LanTransferStatus.completed,
      bytesTransferred: 0,
      createdAt: DateTime.now(),
      isIncoming: true,
    );

    if (_closing || _closed) {
      throw const LanHttpException(
        HttpStatus.serviceUnavailable,
        'LAN transfer service is shutting down.',
      );
    }

    _emit(_incomingMessageController, message);

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'id': message.id}));
    await request.response.close();
  }

  /// 校验并广播已配对对端发来的撤回请求。
  Future<void> _handleRecallRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final json = await _protocolGuard.readJson(request);
    final messageId = json['messageId'] is String
        ? (json['messageId'] as String).trim()
        : '';
    if (messageId.isEmpty || messageId.length > 128) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid recalled message ID.',
      );
    }
    _emit(
      _recalledMessageIdController,
      LanRecallRequest(senderDeviceId: senderDeviceId, messageId: messageId),
    );

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'messageId': messageId}));
    await request.response.close();
  }
}
