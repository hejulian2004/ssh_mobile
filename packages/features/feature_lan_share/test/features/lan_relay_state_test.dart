// Relay 安全快照与纯重连策略测试。

import 'package:feature_lan_share/src/features/lan_share/services/lan_relay_state.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  const policy = LanRelayRetryPolicy(<Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
  ]);

  test('status exposes only derived connection flags', () {
    const connected = LanRelayStatus(
      endpoint: 'https://relay.example.test',
      state: RelayConnectionState.connected,
      enrolled: true,
      reconnectAttempt: 0,
    );
    const connecting = LanRelayStatus(
      endpoint: '',
      state: RelayConnectionState.connecting,
      enrolled: false,
      reconnectAttempt: 1,
    );

    expect(connected.isConnected, isTrue);
    expect(connected.isConnecting, isFalse);
    expect(connected.linkState, LanRelayLinkState.connected);
    expect(connecting.isConnected, isFalse);
    expect(connecting.isConnecting, isTrue);
    expect(connecting.linkState, LanRelayLinkState.connecting);
    expect(
      _status(RelayConnectionState.failed).linkState,
      LanRelayLinkState.failed,
    );
    expect(
      _status(RelayConnectionState.disconnected).linkState,
      LanRelayLinkState.idle,
    );
    expect(
      _status(RelayConnectionState.unspecified).linkState,
      LanRelayLinkState.idle,
    );
  });

  test('inactive or exhausted state does not retry', () {
    for (final decision in <LanRelayRetryDecision>[
      _decide(policy, timerScheduled: true),
      _decide(policy, reconnectEnabled: false),
      _decide(policy, explicitlyDisconnected: true),
      _decide(policy, enrolled: false),
      _decide(policy, state: RelayConnectionState.connected),
      _decide(policy, state: RelayConnectionState.connecting),
      _decide(policy, attempt: 2),
    ]) {
      expect(decision.action, LanRelayRetryAction.none);
      expect(decision.delay, isNull);
    }
  });

  test('terminal and credential errors select distinct actions', () {
    final noRetry = _decide(
      policy,
      error: _error(retryDisposition: RetryDisposition.noRetry),
    );
    final identityConflict = _decide(
      policy,
      error: _error(code: NetworkErrorCode.identityConflict),
      attempt: 2,
    );
    final refresh = _decide(
      policy,
      error: _error(
        retryDisposition: RetryDisposition.refreshCredentialThenRetry,
      ),
    );
    final expired = _decide(
      policy,
      error: _error(code: NetworkErrorCode.credentialExpired),
    );

    expect(noRetry.action, LanRelayRetryAction.stop);
    expect(identityConflict.action, LanRelayRetryAction.stop);
    expect(refresh.action, LanRelayRetryAction.refreshCredential);
    expect(expired.action, LanRelayRetryAction.refreshCredential);
  });

  test('backoff uses attempt while retryAfter clamps server delay', () {
    final first = _decide(policy);
    final second = _decide(policy, attempt: 1);
    final server = _decide(
      policy,
      error: _error(
        retryDisposition: RetryDisposition.retryAfter,
        retryAfterSeconds: 90,
      ),
    );
    final fallback = _decide(
      policy,
      error: _error(
        retryDisposition: RetryDisposition.retryAfter,
        retryAfterSeconds: 0,
      ),
    );

    expect(first.action, LanRelayRetryAction.schedule);
    expect(first.delay, const Duration(seconds: 1));
    expect(second.delay, const Duration(seconds: 2));
    expect(server.delay, const Duration(seconds: 60));
    expect(fallback.delay, const Duration(seconds: 1));
  });
}

LanRelayStatus _status(RelayConnectionState state) => LanRelayStatus(
  endpoint: '',
  state: state,
  enrolled: false,
  reconnectAttempt: 0,
);

LanRelayRetryDecision _decide(
  LanRelayRetryPolicy policy, {
  bool timerScheduled = false,
  bool reconnectEnabled = true,
  bool explicitlyDisconnected = false,
  bool enrolled = true,
  RelayConnectionState state = RelayConnectionState.failed,
  NetworkError? error,
  int attempt = 0,
}) => policy.decide(
  timerScheduled: timerScheduled,
  reconnectEnabled: reconnectEnabled,
  explicitlyDisconnected: explicitlyDisconnected,
  enrolled: enrolled,
  state: state,
  error: error,
  attempt: attempt,
);

NetworkError _error({
  NetworkErrorCode code = NetworkErrorCode.relayError,
  RetryDisposition retryDisposition = RetryDisposition.unspecified,
  int retryAfterSeconds = 0,
}) => NetworkError(
  code: code,
  message: 'test',
  operation: NetworkOperation.connectRelay,
  retryDisposition: retryDisposition,
  retryAfterSeconds: retryAfterSeconds,
);
