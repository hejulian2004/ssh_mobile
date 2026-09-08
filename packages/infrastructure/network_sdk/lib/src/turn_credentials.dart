/// Ephemeral TURN credential contracts.
///
/// The SDK keeps only the typed in-memory value and never creates an HTTP
/// client, secure-storage record, timer or native WebRTC object. App Shell
/// supplies [TurnCredentialProvider] and decides when direct ICE needs relay.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'network_clients.dart';
import 'realtime.dart';
import 'network_error_models.dart';
import 'network_requests.dart';
import 'network_result_models.dart';
import 'network_routes.dart';

/// Short-lived credential returned by the authenticated TURN issuer.
final class EphemeralTurnCredential {
  EphemeralTurnCredential({
    required List<String> urls,
    required this.username,
    required this.password,
    required this.expiresAt,
  }) : urls = List.unmodifiable(urls) {
    if (this.urls.isEmpty || this.urls.any((url) => url.trim().isEmpty)) {
      throw ArgumentError.value(this.urls, 'urls');
    }
    if (username.trim().isEmpty || username.length > 256) {
      throw ArgumentError.value(username, 'username');
    }
    if (password.isEmpty || password.length > 512) {
      throw ArgumentError.value(password, 'password');
    }
    if (!expiresAt.isAfter(DateTime.now())) {
      throw ArgumentError.value(expiresAt, 'expiresAt');
    }
  }

  final List<String> urls;
  final String username;
  final String password;
  final DateTime expiresAt;

  bool isExpired([DateTime? now]) => !expiresAt.isAfter(now ?? DateTime.now());

  /// Deliberately omits credential material from diagnostics and logs.
  @override
  String toString() =>
      'EphemeralTurnCredential(urls: ${urls.length}, expiresAt: $expiresAt)';
}

/// App-injected authenticated credential issuance boundary.
abstract interface class TurnCredentialProvider {
  Future<SdkResult<EphemeralTurnCredential>> issue(RealtimeSessionToken token);
}

/// Signs a short-lived TURN request with the enrolled device proof.
///
/// Relay V2 requires both the bearer enrollment credential and a fresh
/// Ed25519 transcript proof. Keeping signing behind this App-injected port
/// keeps the SDK platform-neutral while preventing bearer-only requests.
abstract interface class TurnCredentialRequestSigner {
  Future<Map<String, String>> sign(SdkRequest request);
}

/// Authenticated HTTP implementation of [TurnCredentialProvider].
///
/// The request executor and access-token session remain App-owned. This SDK
/// client only creates a bounded JSON request, retries one expired bearer
/// token, and returns an in-memory credential. It never logs or persists the
/// username/password returned by the issuer.
final class JsonTurnCredentialProvider implements TurnCredentialProvider {
  JsonTurnCredentialProvider({
    required this.executor,
    required this.authSession,
    required this.requestSigner,
    required Uri endpoint,
    this.requestTimeout = const Duration(seconds: 10),
  }) : endpoint = _resolveTurnEndpoint(endpoint) {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
  }

  final SdkRequestExecutor executor;
  final AuthSessionProvider authSession;
  final TurnCredentialRequestSigner requestSigner;
  final Uri endpoint;
  final Duration requestTimeout;

  @override
  Future<SdkResult<EphemeralTurnCredential>> issue(
    RealtimeSessionToken token,
  ) async {
    final validation = _validateToken(token);
    if (validation != null) return SdkFailure(validation);
    final request = SdkRequest(
      method: 'POST',
      uri: endpoint.resolve(RelayBootstrapRoutes.turnCredentialsV2),
      headers: const <String, String>{
        'content-type': 'application/json',
        'accept': 'application/json',
        'cache-control': 'no-store',
      },
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'realtime_id': token.realtimeId,
            'generation': token.generation,
          }),
        ),
      ),
    );
    try {
      final initialToken = await authSession.readAccessToken();
      if (initialToken == null || initialToken.trim().isEmpty) {
        return SdkFailure(
          _authError('Authenticated TURN session is unavailable.'),
        );
      }
      var accessToken = initialToken.trim();
      var response = await _sendAuthenticated(request, accessToken);
      if (response.statusCode == 401) {
        final refreshed = await _refreshAccessToken();
        if (refreshed == null) {
          return SdkFailure(_authError('Authenticated TURN session expired.'));
        }
        accessToken = refreshed;
        response = await _sendAuthenticated(request, accessToken);
      }
      if (response.statusCode == 401) {
        await _invalidateSafely();
        return SdkFailure(_authError('Authenticated TURN session expired.'));
      }
      if (!response.isSuccessful) {
        return SdkFailure(_turnHttpError(response));
      }
      try {
        return SdkSuccess(_parseCredential(response.body));
      } on _ExpiredTurnCredential {
        return turnUnavailable(
          'TURN credential response is already expired.',
          peerId: token.peerId,
        );
      } on Object {
        return const SdkFailure(
          NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'TURN credential response is invalid.',
            operation: NetworkOperation.issueTurnCredential,
          ),
        );
      }
    } on _TurnCredentialProofException {
      return SdkFailure(
        _authError('TURN device authentication is unavailable.'),
      );
    } on Object catch (error) {
      return SdkFailure(_turnTransportError(error));
    }
  }

  Future<SdkResponse> _send(SdkRequest request) =>
      executor.execute(request).timeout(requestTimeout);

  Future<SdkResponse> _sendAuthenticated(
    SdkRequest request,
    String accessToken,
  ) async {
    final proof = await _deviceProof(request);
    return _send(_withBearerAndProof(request, accessToken, proof));
  }

  Future<Map<String, String>> _deviceProof(SdkRequest request) async {
    try {
      final proof = await requestSigner.sign(request);
      final normalized = <String, String>{
        for (final entry in proof.entries) entry.key.toLowerCase(): entry.value,
      };
      const requiredHeaders = <String>[
        'x-relay-timestamp',
        'x-relay-nonce',
        'x-relay-signature',
      ];
      if (requiredHeaders.any(
        (name) => normalized[name]?.trim().isNotEmpty != true,
      )) {
        throw const _TurnCredentialProofException();
      }
      return proof;
    } on _TurnCredentialProofException {
      rethrow;
    } on Object {
      throw const _TurnCredentialProofException();
    }
  }

  SdkRequest _withBearerAndProof(
    SdkRequest request,
    String token,
    Map<String, String> proof,
  ) => SdkRequest(
    method: request.method,
    uri: request.uri,
    headers: <String, String>{
      ...request.headers,
      ...proof,
      'authorization': 'Bearer ${token.trim()}',
    },
    body: request.body,
  );

  Future<String?> _refreshAccessToken() async {
    try {
      final refreshed = await authSession.refreshAccessToken();
      if (refreshed == null || refreshed.trim().isEmpty) {
        await _invalidateSafely();
        return null;
      }
      return refreshed.trim();
    } on Object {
      await _invalidateSafely();
      return null;
    }
  }

  Future<void> _invalidateSafely() async {
    try {
      await authSession.invalidate();
    } on Object {
      // Do not let cleanup errors expose or replace the authentication result.
    }
  }
}

/// In-memory credentials scoped by the native-authoritative Realtime token.
final class RealtimeTurnCredentialStore {
  final Map<RealtimeSessionToken, EphemeralTurnCredential> _credentials =
      <RealtimeSessionToken, EphemeralTurnCredential>{};

  EphemeralTurnCredential? getValid(
    RealtimeSessionToken token, {
    DateTime? now,
  }) {
    final credential = _credentials[token];
    if (credential == null) return null;
    if (credential.isExpired(now)) {
      _credentials.remove(token);
      return null;
    }
    return credential;
  }

  void put(RealtimeSessionToken token, EphemeralTurnCredential credential) {
    if (credential.isExpired()) {
      throw ArgumentError.value(credential, 'credential');
    }
    _credentials[token] = credential;
  }

  void clear(RealtimeSessionToken token) => _credentials.remove(token);

  void clearAll() => _credentials.clear();

  int get length => _credentials.length;
}

/// Maps an expired/invalid issuer result to the stable TURN error boundary.
SdkFailure<EphemeralTurnCredential> turnUnavailable(
  String message, {
  String? peerId,
}) => SdkFailure(
  NetworkError(
    code: NetworkErrorCode.credentialExpired,
    message: message,
    operation: NetworkOperation.issueTurnCredential,
    peerId: peerId,
  ),
);

NetworkError? _validateToken(RealtimeSessionToken token) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(token.realtimeId) ||
      token.generation <= 0 ||
      token.peerId.trim().isEmpty ||
      token.peerId.length > 128) {
    return const NetworkError(
      code: NetworkErrorCode.invalidArgument,
      message: 'Realtime TURN session token is invalid.',
      operation: NetworkOperation.issueTurnCredential,
    );
  }
  return null;
}

EphemeralTurnCredential _parseCredential(Uint8List bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map) {
    throw const FormatException('TURN response is not an object.');
  }
  final urlsValue = value['urls'];
  final username = value['username'];
  final password = value['password'];
  final expiresAt = value['expires_at'];
  if (urlsValue is! List ||
      urlsValue.isEmpty ||
      urlsValue.length > 8 ||
      urlsValue.any((url) => url is! String) ||
      username is! String ||
      password is! String ||
      expiresAt is! int ||
      expiresAt <= 0) {
    throw const FormatException('TURN response fields are invalid.');
  }
  final expiry = DateTime.fromMillisecondsSinceEpoch(
    expiresAt * Duration.millisecondsPerSecond,
    isUtc: true,
  );
  if (!expiry.isAfter(DateTime.now().toUtc())) {
    throw const _ExpiredTurnCredential();
  }
  return EphemeralTurnCredential(
    urls: urlsValue.cast<String>(),
    username: username,
    password: password,
    expiresAt: expiry,
  );
}

final class _ExpiredTurnCredential implements Exception {
  const _ExpiredTurnCredential();
}

final class _TurnCredentialProofException implements Exception {
  const _TurnCredentialProofException();
}

NetworkError _turnHttpError(SdkResponse response) {
  Map<String, dynamic>? body;
  try {
    final decoded = jsonDecode(utf8.decode(response.body));
    if (decoded is Map<String, dynamic>) body = decoded;
  } on Object {
    body = null;
  }
  final code = switch (response.statusCode) {
    400 => NetworkErrorCode.invalidArgument,
    401 || 403 => NetworkErrorCode.authenticationFailed,
    408 || 429 || >= 500 => NetworkErrorCode.timeout,
    _ => NetworkErrorCode.relayError,
  };
  return NetworkError(
    code: code,
    message: switch (code) {
      NetworkErrorCode.invalidArgument =>
        'TURN credential request was rejected.',
      NetworkErrorCode.authenticationFailed =>
        'TURN credential authentication failed.',
      NetworkErrorCode.timeout => 'TURN credential service timed out.',
      _ => 'TURN credential service rejected the request.',
    },
    operation: NetworkOperation.issueTurnCredential,
    retryDisposition: _retryDisposition(body?['retry_disposition']),
    retryAfterSeconds: _positiveInt(body?['retry_after_seconds']),
  );
}

NetworkError _turnTransportError(Object error) => NetworkError(
  code: error is TimeoutException
      ? NetworkErrorCode.timeout
      : error is ArgumentError
      ? NetworkErrorCode.invalidArgument
      : NetworkErrorCode.ioError,
  message: 'TURN credential request failed.',
  operation: NetworkOperation.issueTurnCredential,
);

NetworkError _authError(String message) => NetworkError(
  code: NetworkErrorCode.authenticationFailed,
  message: message,
  operation: NetworkOperation.issueTurnCredential,
);

RetryDisposition _retryDisposition(Object? value) {
  if (value is! String) return RetryDisposition.unspecified;
  return RetryDisposition.fromWire(switch (value) {
    'retry_with_backoff' => 2,
    'retry_after' => 3,
    'refresh_credential_then_retry' => 4,
    _ => 0,
  });
}

int _positiveInt(Object? value) => value is int && value > 0 ? value : 0;

Uri _resolveTurnEndpoint(Uri endpoint) {
  if ((endpoint.scheme != 'https' && endpoint.scheme != 'http') ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.query.isNotEmpty ||
      endpoint.fragment.isNotEmpty) {
    throw ArgumentError.value(endpoint, 'endpoint', 'invalid network endpoint');
  }
  return endpoint;
}
