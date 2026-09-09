import 'package:network_sdk/network_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('store replaces stale generations before applying capacity', () {
    const first = RealtimeSessionToken(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
      generation: 1,
    );
    const next = RealtimeSessionToken(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
      generation: 2,
    );
    final credential = EphemeralTurnCredential(
      urls: const ['turns:relay.example'],
      username: 'device-user',
      password: 'opaque-password',
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    );
    final store = RealtimeTurnCredentialStore(maxEntries: 1);

    store.put(first, credential);
    store.put(next, credential);

    expect(store.length, 1);
    expect(store.getValid(first), isNull);
    expect(store.getValid(next), same(credential));
  });
}
