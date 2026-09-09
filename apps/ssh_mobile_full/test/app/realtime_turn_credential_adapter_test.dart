import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import 'package:ssh_mobile/app/realtime_turn_credential_adapter.dart';

void main() {
  const token = RealtimeSessionToken(
    realtimeId: '00112233445566778899aabbccddeeff',
    peerId: 'peer-a',
    generation: 3,
  );
  final credential = EphemeralTurnCredential(
    urls: const ['turns:relay.example'],
    username: '1700000000:peer-a',
    password: 'opaque-test-password',
    expiresAt: DateTime.now().add(const Duration(minutes: 1)),
  );

  test('provider delegates the native session token to the issuer', () async {
    RealtimeSessionToken? received;
    final provider = AppRealtimeTurnCredentialProvider(
      issueCredential: (value) async {
        received = value;
        return SdkSuccess(credential);
      },
    );

    final result = await provider.issue(token);

    expect(received, same(token));
    expect(result, isA<SdkSuccess<EphemeralTurnCredential>>());
    expect(
      (result as SdkSuccess<EphemeralTurnCredential>).data,
      same(credential),
    );
  });

  test('signer creates a fresh proof for a valid TURN request', () async {
    final endpoint = Uri.parse('https://relay.example');
    final enrollment = _FakeRelayEnrollment(
      configuration: lan.RelayNativeConfiguration(
        endpoint: endpoint,
        credential: 'opaque-enrollment',
        signingSeed: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
    );
    final signer = AppTurnCredentialRequestSigner(
      relayEnrollment: enrollment,
      relayEndpoint: endpoint,
    );

    final headers = await signer.sign(
      SdkRequest(
        method: 'post',
        uri: endpoint.resolve(RelayBootstrapRoutes.turnCredentialsV2),
      ),
    );

    expect(enrollment.requestedSettings?.endpoint, endpoint);
    expect(headers['X-Relay-Timestamp'], matches(RegExp(r'^\d+$')));
    expect(headers['X-Relay-Nonce'], isNotEmpty);
    expect(headers['X-Relay-Signature'], isNotEmpty);
  });

  test('signer rejects invalid endpoint and request targets', () async {
    final endpoint = Uri.parse('https://relay.example');
    final enrollment = _FakeRelayEnrollment();

    expect(
      () => AppTurnCredentialRequestSigner(
        relayEnrollment: enrollment,
        relayEndpoint: Uri.parse('https://relay.example/path'),
      ),
      throwsArgumentError,
    );

    final signer = AppTurnCredentialRequestSigner(
      relayEnrollment: enrollment,
      relayEndpoint: endpoint,
    );
    await expectLater(
      signer.sign(
        SdkRequest(
          method: 'GET',
          uri: endpoint.resolve(RelayBootstrapRoutes.turnCredentialsV2),
        ),
      ),
      throwsArgumentError,
    );
  });

  test(
    'signer fails closed when native proof material is unavailable',
    () async {
      final endpoint = Uri.parse('https://relay.example');
      final signer = AppTurnCredentialRequestSigner(
        relayEnrollment: _FakeRelayEnrollment(),
        relayEndpoint: endpoint,
      );

      await expectLater(
        signer.sign(
          SdkRequest(
            method: 'POST',
            uri: endpoint.resolve(RelayBootstrapRoutes.turnCredentialsV2),
          ),
        ),
        throwsStateError,
      );
    },
  );
}

final class _FakeRelayEnrollment implements lan.LanRelayEnrollmentPort {
  _FakeRelayEnrollment({this.configuration});

  final lan.RelayNativeConfiguration? configuration;
  lan.RelaySettings? requestedSettings;

  @override
  Future<NetworkResult<void>> enroll(
    lan.RelaySettings settings,
    String enrollmentToken,
  ) async => const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> refreshCredential(
    lan.RelaySettings settings,
  ) async => const NetworkSuccess<void>(null);

  @override
  Future<bool> hasStoredCredential(lan.RelaySettings settings) async => false;

  @override
  Future<bool> isEnrolled(lan.RelaySettings settings) async =>
      configuration != null;

  @override
  Future<lan.RelayNativeConfiguration?> nativeConfiguration(
    lan.RelaySettings settings,
  ) async {
    requestedSettings = settings;
    return configuration;
  }

  @override
  Future<void> clearEnrollment() async {}

  @override
  Future<void> dispose() async {}
}
