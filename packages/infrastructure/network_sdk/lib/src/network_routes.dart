/// Relay Bootstrap 协议版本与常量定义。
abstract final class RelayBootstrapProtocol {
  /// 当前生效的 Relay Bootstrap 协议版本。
  static const int version = 2;
}

/// Relay Bootstrap API 规范定义的标准契约路由与常量。
abstract final class RelayBootstrapRoutes {
  /// 当前协议版本。
  static const int protocolVersion = RelayBootstrapProtocol.version;

  /// 健康检查/存活探测路径。
  static const String healthz = '/healthz';

  /// 设备注册端点路径。
  static const String enrollV2 = '/v2/devices/enroll';

  /// 设备凭据刷新端点路径。
  static const String refreshV2 = '/v2/devices/refresh';

  /// Device-authenticated, short-lived TURN REST credential endpoint.
  static const String turnCredentialsV2 = '/v2/turn/credentials';

  /// 构造设备凭据刷新签名的 canonical transcript。
  static String buildRefreshTranscript(int timestamp, String nonce) =>
      'POST\n$refreshV2\n$timestamp\n$nonce';
}
