import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('credential model enforces UTF-8 bounds and redacts its password', () {
    final credential = EphemeralTurnCredential(
      urls: const ['turns:relay.example'],
      username: 'device-user',
      password: 'opaque-password',
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );

    expect(credential.toString(), isNot(contains('opaque-password')));
    expect(
      () => EphemeralTurnCredential(
        urls: const ['turns:relay.example'],
        username: '界' * 100,
        password: 'password',
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
