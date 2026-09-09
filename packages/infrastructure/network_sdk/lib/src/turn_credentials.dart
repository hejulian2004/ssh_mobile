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

const _maxTurnResponseBytes = 64 * 1024;
const _maxTurnUrls = 8;
const _maxTurnUrlBytes = 2048;
const _maxTurnUsernameBytes = 256;
const _maxTurnPasswordBytes = 512;
const _defaultTurnStoreCapacity = 32;

/// Short-lived credential returned by the authenticated TURN issuer.
final class EphemeralTurnCredential {
  EphemeralTurnCredential({
    required List<String> urls,
    required this.username,
    required this.password,
    required this.expiresAt,
  }) : urls = List.unmodifiable(urls) {
    if (this.urls.isEmpty ||
        this.urls.length > _maxTurnUrls ||
        this.urls.any((url) => url.trim().isEmpty)) {
      throw ArgumentError('TURN server URLs are invalid.');
    }
    for (final url in this.urls) {
      _validateTurnUrl(url);
    }
    if (username.trim().isEmpty ||
        utf8.encode(username).length > _maxTurnUsernameBytes) {
      throw ArgumentError('TURN username is invalid.');
    }
    if (password.isEmpty ||
        utf8.encode(password).length > _maxTurnPasswordBytes) {
      throw ArgumentError('TURN password is invalid.');
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
    this.allowLoopbackHttp = false,
  }) : endpoint = _resolveTurnEndpoint(endpoint, allowLoopbackHttp) {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
  }

  final SdkRequestExecutor executor;
  final AuthSessionProvider authSession;
  final TurnCredentialRequestSigner requestSigner;
  final Uri endpoint;
  final Duration requestTimeout;

  /// HTTP is only permitted for an explicitly opted-in local test issuer.
  /// Production callers must use HTTPS.
  final bool allowLoopbackHttp;

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
  RealtimeTurnCredentialStore({this.maxEntries = _defaultTurnStoreCapacity}) {
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
  }

  final int maxEntries;
  final Map<RealtimeSessionToken, EphemeralTurnCredential> _credentials =
      <RealtimeSessionToken, EphemeralTurnCredential>{};

  EphemeralTurnCredential? getValid(
    RealtimeSessionToken token, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    _sweep(current);
    final credential = _credentials[token];
    if (credential == null) return null;
    if (credential.isExpired(current)) {
      _credentials.remove(token);
      return null;
    }
    return credential;
  }

  void put(RealtimeSessionToken token, EphemeralTurnCredential credential) {
    if (credential.isExpired()) {
      throw ArgumentError('TURN credential is expired.');
    }
    final now = DateTime.now();
    _sweep(now);
    _credentials.removeWhere(
      (existing, _) =>
          existing.realtimeId == token.realtimeId &&
          existing.generation != token.generation,
    );
    if (!_credentials.containsKey(token) && _credentials.length >= maxEntries) {
      throw StateError('TURN credential store capacity exhausted.');
    }
    _credentials[token] = credential;
  }

  void clear(RealtimeSessionToken token) {
    _sweep(DateTime.now());
    _credentials.remove(token);
  }

  void clearAll() => _credentials.clear();

  int get length {
    _sweep(DateTime.now());
    return _credentials.length;
  }

  void _sweep(DateTime now) {
    _credentials.removeWhere((_, credential) => credential.isExpired(now));
  }
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
      utf8.encode(token.peerId).length > 128) {
    return const NetworkError(
      code: NetworkErrorCode.invalidArgument,
      message: 'Realtime TURN session token is invalid.',
      operation: NetworkOperation.issueTurnCredential,
    );
  }
  return null;
}

EphemeralTurnCredential _parseCredential(Uint8List bytes) {
  if (bytes.length > _maxTurnResponseBytes) {
    throw const FormatException('TURN response is too large.');
  }
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
      urlsValue.length > _maxTurnUrls ||
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
    if (response.body.length > _maxTurnResponseBytes) {
      throw const FormatException('TURN error response is too large.');
    }
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

Uri _resolveTurnEndpoint(Uri endpoint, bool allowLoopbackHttp) {
  final https = endpoint.scheme == 'https';
  final loopbackHttp =
      endpoint.scheme == 'http' &&
      allowLoopbackHttp &&
      _isLoopbackHost(endpoint.host);
  if ((!https && !loopbackHttp) ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.query.isNotEmpty ||
      endpoint.fragment.isNotEmpty) {
    throw ArgumentError('TURN issuer endpoint is invalid.');
  }
  return endpoint;
}

void _validateTurnUrl(String value) {
  if (utf8.encode(value).length > _maxTurnUrlBytes ||
      value != value.trim() ||
      RegExp(r'[\u0000-\u0020\u007f]').hasMatch(value)) {
    throw ArgumentError('TURN server URL is invalid.');
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'turn' && uri.scheme != 'turns') ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw ArgumentError('TURN server URL is invalid.');
  }

  final authority = uri.host.isNotEmpty
      ? (uri.path.isEmpty ? (uri.host, uri.hasPort ? uri.port : null) : null)
      : _parseOpaqueTurnAuthority(uri.path);
  if (authority == null ||
      !_isValidTurnHost(authority.$1) ||
      (authority.$2 != null &&
          (authority.$2! <= 0 || authority.$2! > 65_535))) {
    throw ArgumentError('TURN server URL is invalid.');
  }
}

(String, int?)? _parseOpaqueTurnAuthority(String value) {
  if (value.isEmpty) return null;
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close <= 1) return null;
    final host = value.substring(1, close);
    final suffix = value.substring(close + 1);
    if (suffix.isEmpty) return (host, null);
    if (!suffix.startsWith(':')) return null;
    return (host, int.tryParse(suffix.substring(1)));
  }
  if (value.contains('[') ||
      value.contains(']') ||
      value.contains('/') ||
      value.contains('\\')) {
    return null;
  }
  final firstColon = value.indexOf(':');
  if (firstColon < 0) return (value, null);
  if (firstColon == 0 || firstColon != value.lastIndexOf(':')) return null;
  final port = int.tryParse(value.substring(firstColon + 1));
  if (port == null) return null;
  return (value.substring(0, firstColon), port);
}

bool _isValidTurnHost(String host) {
  if (host.isEmpty ||
      host.contains('@') ||
      host.contains('/') ||
      host.contains('\\') ||
      host.contains('[') ||
      host.contains(']')) {
    return false;
  }
  return !RegExp(r'[\u0000-\u0020\u007f]').hasMatch(host);
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}
