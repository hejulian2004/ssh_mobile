import 'dart:convert';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  test(
    'provider keeps bearer and device proof in the injected request',
    () async {
      final executor = _Executor(
        SdkResponse(
          statusCode: 200,
          body: Uint8List.fromList(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'urls': <String>['turns:relay.example'],
                'username': 'device-user',
                'password': 'opaque-password',
                'expires_at':
                    DateTime.now()
                        .toUtc()
                        .add(const Duration(minutes: 1))
                        .millisecondsSinceEpoch ~/
                    1000,
              }),
            ),
          ),
        ),
      );
      final provider = JsonTurnCredentialProvider(
        executor: executor,
        authSession: const _Auth(),
        requestSigner: const _Signer(),
        endpoint: Uri.parse('https://relay.example'),
      );

      final result = await provider.issue(
        const RealtimeSessionToken(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          generation: 3,
        ),
      );

      expect(result, isA<SdkSuccess<EphemeralTurnCredential>>());
      expect(executor.request.headers['authorization'], 'Bearer access-token');
      expect(executor.request.headers['X-Relay-Signature'], 'signature');
    },
  );
}

final class _Executor implements SdkRequestExecutor {
  _Executor(this.response);

  final SdkResponse response;
  late SdkRequest request;

  @override
  Future<SdkResponse> execute(SdkRequest request) async {
    this.request = request;
    return response;
  }
}

final class _Auth implements AuthSessionProvider {
  const _Auth();

  @override
  Future<String?> readAccessToken() async => 'access-token';

  @override
  Future<String?> refreshAccessToken() async => null;

  @override
  Future<void> invalidate() async {}
}

final class _Signer implements TurnCredentialRequestSigner {
  const _Signer();

  @override
  Future<Map<String, String>> sign(SdkRequest request) async =>
      const <String, String>{
        'X-Relay-Timestamp': '1700000000',
        'X-Relay-Nonce': 'nonce',
        'X-Relay-Signature': 'signature',
      };
}
