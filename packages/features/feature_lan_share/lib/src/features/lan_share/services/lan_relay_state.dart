// LAN Relay 安全状态快照和纯重连策略。

import 'package:network_sdk/network_sdk.dart';

/// 页面展示的 Relay 连接状态。
enum LanRelayLinkState { connected, connecting, failed, idle }

/// Relay 配置和数据面状态的安全快照；不包含秘密材料。
final class LanRelayStatus {
  const LanRelayStatus({
    required this.endpoint,
    required this.state,
    required this.enrolled,
    required this.reconnectAttempt,
    this.error,
  });

  final String endpoint;
  final RelayConnectionState state;
  final bool enrolled;
  final int reconnectAttempt;
  final NetworkError? error;

  bool get isConnected => state == RelayConnectionState.connected;
  bool get isConnecting => state == RelayConnectionState.connecting;

  /// 页面使用的连接状态。SDK 枚举留在应用层。
  LanRelayLinkState get linkState => switch (state) {
    RelayConnectionState.connected => LanRelayLinkState.connected,
    RelayConnectionState.connecting => LanRelayLinkState.connecting,
    RelayConnectionState.failed => LanRelayLinkState.failed,
    RelayConnectionState.disconnected ||
    RelayConnectionState.unspecified => LanRelayLinkState.idle,
  };
}

/// Relay 失败后的下一项生命周期动作。
enum LanRelayRetryAction { none, stop, refreshCredential, schedule }

/// 纯策略返回的重连决策。
final class LanRelayRetryDecision {
  const LanRelayRetryDecision(this.action, {this.delay});

  final LanRelayRetryAction action;
  final Duration? delay;
}

/// 将 typed error、连接状态和有限退避转换为一个可测试决策。
final class LanRelayRetryPolicy {
  const LanRelayRetryPolicy(this.delays);

  final List<Duration> delays;

  LanRelayRetryDecision decide({
    required bool timerScheduled,
    required bool reconnectEnabled,
    required bool explicitlyDisconnected,
    required bool enrolled,
    required RelayConnectionState state,
    required NetworkError? error,
    required int attempt,
  }) {
    if (timerScheduled ||
        !reconnectEnabled ||
        explicitlyDisconnected ||
        !enrolled ||
        state == RelayConnectionState.connected ||
        state == RelayConnectionState.connecting) {
      return const LanRelayRetryDecision(LanRelayRetryAction.none);
    }
    final disposition = error?.retryDisposition ?? RetryDisposition.unspecified;
    if (disposition == RetryDisposition.noRetry ||
        error?.code == NetworkErrorCode.identityConflict) {
      return const LanRelayRetryDecision(LanRelayRetryAction.stop);
    }
    if (disposition == RetryDisposition.refreshCredentialThenRetry ||
        error?.code == NetworkErrorCode.credentialExpired) {
      return const LanRelayRetryDecision(LanRelayRetryAction.refreshCredential);
    }
    if (attempt >= delays.length) {
      return const LanRelayRetryDecision(LanRelayRetryAction.none);
    }
    var delay = delays[attempt];
    if (disposition == RetryDisposition.retryAfter &&
        (error?.retryAfterSeconds ?? 0) > 0) {
      delay = Duration(seconds: error!.retryAfterSeconds.clamp(1, 60));
    }
    return LanRelayRetryDecision(LanRelayRetryAction.schedule, delay: delay);
  }
}
