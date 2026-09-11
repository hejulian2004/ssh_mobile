/// Dart、Rust、FFI、LAN 和 Relay 共享的 Network V2 public error codes.
enum NetworkErrorCode {
  unspecified(0),
  invalidArgument(1),
  authenticationFailed(2),
  noRoute(3),
  timeout(4),
  peerOffline(5),
  quicError(6),
  natError(7),
  relayError(8),
  ioError(10),
  cancelled(11),
  credentialExpired(12),
  identityConflict(13),
  configuration(14),
  securityPolicyMismatch(15),
  relayRequiresE2ee(16),
  peerNotReady(17),
  resourceLimit(18),
  lifecycle(19),
  protocolMismatch(20),
  staleOperation(21),
  invalidState(22),
  pathLost(23),
  resumeRejected(24),
  streamClosed(25);

  const NetworkErrorCode(this.wireValue);

  final int wireValue;

  static NetworkErrorCode fromWire(int value) => NetworkErrorCode.values
      .firstWhere((code) => code.wireValue == value, orElse: () => unspecified);
}

extension NetworkErrorCodePolicy on NetworkErrorCode {
  bool get retryable => switch (this) {
    NetworkErrorCode.timeout ||
    NetworkErrorCode.peerOffline ||
    NetworkErrorCode.noRoute ||
    NetworkErrorCode.relayError ||
    NetworkErrorCode.pathLost ||
    NetworkErrorCode.peerNotReady => true,
    _ => false,
  };
}

/// 服务端建议的重试策略；默认 Unspecified 表示未指定。
enum RetryDisposition {
  unspecified(0),
  noRetry(1),
  retryWithBackoff(2),
  retryAfter(3),
  refreshCredentialThenRetry(4);

  const RetryDisposition(this.wireValue);

  final int wireValue;

  static RetryDisposition fromWire(int value) =>
      RetryDisposition.values.firstWhere(
        (disposition) => disposition.wireValue == value,
        orElse: () => unspecified,
      );
}

/// v1 网络操作的稳定标识。
enum NetworkOperation {
  start('start'),
  stop('stop'),
  upsertPeer('upsert_peer'),
  removePeer('remove_peer'),
  connect('connect'),
  disconnect('disconnect'),
  configureRelay('configure_relay'),
  disconnectRelay('disconnect_relay'),
  send('send'),
  cancel('cancel'),
  respondToIncoming('respond_incoming'),
  state('state'),
  startLanListener('start_lan_listener'),
  stopLanListener('stop_lan_listener'),
  closeLanConnections('close_lan_connections'),
  connectWebSocket('connect_websocket'),
  authorizeLanRequest('authorize_lan_request'),
  sendHandshake('send_handshake'),
  sendMeta('send_meta'),
  sendFile('send_file'),
  sendRecall('send_recall'),
  sendAnnouncement('send_announcement'),
  sendPairingInvite('send_pairing_invite'),
  fetchCapabilities('fetch_capabilities'),
  checkPair('check_pair'),
  readCapabilities('read_capabilities'),
  lanRequest('lan_request'),
  webShareRequest('webshare_request'),
  webShareSendMeta('webshare_send_meta'),
  webShareSendFile('webshare_send_file'),
  startAdvertising('start_advertising'),
  stopAdvertising('stop_advertising'),
  startDiscovery('start_discovery'),
  stopDiscovery('stop_discovery'),
  startWebShare('start_webshare'),
  stopWebShare('stop_webshare'),
  enrollRelay('enroll_relay'),
  refreshCredential('refresh_credential'),
  issueTurnCredential('issue_turn_credential'),
  connectRelay('connect_relay'),
  bootstrapProbe('bootstrap_probe'),
  listPeers('list_peers'),
  requestConnection('request_connection');

  const NetworkOperation(this.wireName);

  final String wireName;

  static NetworkOperation? fromWire(String? value) {
    if (value == null || value.isEmpty) return null;
    for (final operation in values) {
      if (operation.wireName == value) return operation;
    }
    return null;
  }
}

/// 可安全传递给 UI/日志的结构化网络错误。
final class NetworkError {
  const NetworkError({
    required this.code,
    required this.message,
    this.operation,
    this.peerId,
    this.retryDisposition = RetryDisposition.unspecified,
    this.retryAfterSeconds = 0,
  });

  final NetworkErrorCode code;
  final String message;
  final NetworkOperation? operation;
  final String? peerId;

  /// 服务端建议的重试策略；[RetryDisposition.unspecified] 表示未指定。
  final RetryDisposition retryDisposition;

  /// 服务端建议的 `RetryAfter` 秒数；0 表示未指定。
  final int retryAfterSeconds;

  NetworkError copyWith({
    NetworkErrorCode? code,
    String? message,
    NetworkOperation? operation,
    String? peerId,
    RetryDisposition? retryDisposition,
    int? retryAfterSeconds,
  }) => NetworkError(
    code: code ?? this.code,
    message: message ?? this.message,
    operation: operation ?? this.operation,
    peerId: peerId ?? this.peerId,
    retryDisposition: retryDisposition ?? this.retryDisposition,
    retryAfterSeconds: retryAfterSeconds ?? this.retryAfterSeconds,
  );

  /// 服务端携带重试策略时以其为准；未指定时回退到 [NetworkErrorCode.retryable]。
  bool get retryable => switch (retryDisposition) {
    RetryDisposition.unspecified => code.retryable,
    RetryDisposition.noRetry => false,
    RetryDisposition.retryWithBackoff ||
    RetryDisposition.retryAfter ||
    RetryDisposition.refreshCredentialThenRetry => true,
  };

  @override
  String toString() =>
      'NetworkError(${code.name}, operation: $operation, peerId: $peerId)';
}
