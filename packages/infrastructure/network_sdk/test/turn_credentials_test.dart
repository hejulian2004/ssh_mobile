import 'dart:convert';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  final token = const RealtimeSessionToken(
    realtimeId: '00112233445566778899aabbccddeeff',
    peerId: 'peer-a',
    generation: 7,
  );

  test('TURN credentials redact secret material and expire from the store', () {
    final now = DateTime.now();
    final credential = EphemeralTurnCredential(
      urls: const ['turns:relay.example'],
      username: '1700000000:peer-a',
      password: 'secret-value',
      expiresAt: now.add(const Duration(minutes: 1)),
    );
    expect(credential.toString(), isNot(contains('secret-value')));
    final store = RealtimeTurnCredentialStore();
    store.put(token, credential);
    expect(store.getValid(token, now: now), same(credential));
    expect(store.getValid(token, now: credential.expiresAt), isNull);
    expect(store.length, 0);
  });

  test(
    'new credentials replace the prior generation and clear is explicit',
    () {
      final credential = EphemeralTurnCredential(
        urls: const ['turns:relay.example'],
        username: '1700000001:peer-a',
        password: 'secret-value-2',
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      );
      final store = RealtimeTurnCredentialStore();
      store.put(token, credential);
      store.put(token, credential);
      expect(store.length, 1);
      store.clear(token);
      expect(store.getValid(token), isNull);
    },
  );

  test('expired credential response maps to the stable issuer operation', () {
    final failure = turnUnavailable('expired', peerId: 'peer-a');
    expect(failure.error.code, NetworkErrorCode.credentialExpired);
    expect(failure.error.operation, NetworkOperation.issueTurnCredential);
    expect(failure.error.peerId, 'peer-a');
  });

  test(
    'JSON provider uses bearer plus device proof and parses bounded data',
    () async {
      final executor = _TurnExecutor(<SdkResponse>[
        _jsonResponse(<String, dynamic>{
          'urls': <String>['turns:relay.example'],
          'username': '1700000000:device',
          'password': 'opaque-test-password',
          'expires_at':
              DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 2))
                  .millisecondsSinceEpoch ~/
              1000,
        }),
      ]);
      final auth = _TurnAuth();
      final provider = JsonTurnCredentialProvider(
        executor: executor,
        authSession: auth,
        requestSigner: const _TurnSigner(),
        endpoint: Uri.parse('https://relay.example'),
      );

      final result = await provider.issue(token);
      expect(result, isA<SdkSuccess<EphemeralTurnCredential>>());
      final credential = (result as SdkSuccess<EphemeralTurnCredential>).data;
      expect(credential.urls, ['turns:relay.example']);
      expect(
        executor.requests.single.headers['authorization'],
        'Bearer access-1',
      );
      expect(
        executor.requests.single.headers['X-Relay-Timestamp'],
        '1700000000',
      );
      expect(executor.requests.single.headers['X-Relay-Nonce'], 'nonce');
      expect(
        utf8.decode(executor.requests.single.body!),
        contains('"generation":7'),
      );
    },
  );

  test('JSON provider refreshes once after an expired bearer token', () async {
    final executor = _TurnExecutor(<SdkResponse>[
      SdkResponse(statusCode: 401, body: Uint8List(0)),
      _jsonResponse(<String, dynamic>{
        'urls': <String>['turns:relay.example'],
        'username': '1700000001:device',
        'password': 'opaque-test-password',
        'expires_at':
            DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 2))
                .millisecondsSinceEpoch ~/
            1000,
      }),
    ]);
    final auth = _TurnAuth();
    final provider = JsonTurnCredentialProvider(
      executor: executor,
      authSession: auth,
      requestSigner: const _TurnSigner(),
      endpoint: Uri.parse('https://relay.example'),
    );

    final result = await provider.issue(token);
    expect(result, isA<SdkSuccess<EphemeralTurnCredential>>());
    expect(auth.refreshCount, 1);
    expect(executor.requests[1].headers['authorization'], 'Bearer access-2');
  });

  test(
    'JSON provider fails closed when device proof cannot be produced',
    () async {
      final executor = _TurnExecutor(<SdkResponse>[]);
      final provider = JsonTurnCredentialProvider(
        executor: executor,
        authSession: _TurnAuth(),
        requestSigner: const _MissingTurnSigner(),
        endpoint: Uri.parse('https://relay.example'),
      );

      final result = await provider.issue(token);
      expect(result, isA<SdkFailure<EphemeralTurnCredential>>());
      expect(
        (result as SdkFailure<EphemeralTurnCredential>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(executor.requests, isEmpty);
    },
  );

  test(
    'JSON provider rejects an expired issuer response without retaining it',
    () async {
      final executor = _TurnExecutor(<SdkResponse>[
        _jsonResponse(<String, dynamic>{
          'urls': <String>['turns:relay.example'],
          'username': 'expired',
          'password': 'opaque-test-password',
          'expires_at': 1,
        }),
      ]);
      final provider = JsonTurnCredentialProvider(
        executor: executor,
        authSession: _TurnAuth(),
        requestSigner: const _TurnSigner(),
        endpoint: Uri.parse('https://relay.example'),
      );

      final result = await provider.issue(token);
      expect(result, isA<SdkFailure<EphemeralTurnCredential>>());
      expect(
        (result as SdkFailure<EphemeralTurnCredential>).error.code,
        NetworkErrorCode.credentialExpired,
      );
    },
  );
}

SdkResponse _jsonResponse(Map<String, dynamic> value) => SdkResponse(
  statusCode: 200,
  body: Uint8List.fromList(utf8.encode(jsonEncode(value))),
);

final class _TurnExecutor implements SdkRequestExecutor {
  _TurnExecutor(this.responses);

  final List<SdkResponse> responses;
  final List<SdkRequest> requests = <SdkRequest>[];

  @override
  Future<SdkResponse> execute(SdkRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}

final class _TurnAuth implements AuthSessionProvider {
  int refreshCount = 0;

  @override
  Future<String?> readAccessToken() async => 'access-1';

  @override
  Future<String?> refreshAccessToken() async {
    refreshCount++;
    return 'access-2';
  }

  @override
  Future<void> invalidate() async {}
}

final class _TurnSigner implements TurnCredentialRequestSigner {
  const _TurnSigner();

  @override
  Future<Map<String, String>> sign(SdkRequest request) async =>
      const <String, String>{
        'X-Relay-Timestamp': '1700000000',
        'X-Relay-Nonce': 'nonce',
        'X-Relay-Signature': 'signature',
      };
}

final class _MissingTurnSigner implements TurnCredentialRequestSigner {
  const _MissingTurnSigner();

  @override
  Future<Map<String, String>> sign(SdkRequest request) async =>
      const <String, String>{};
}
