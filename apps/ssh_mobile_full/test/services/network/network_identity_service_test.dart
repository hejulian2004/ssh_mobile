import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/network/network_identity_service.dart';

final class _MemorySecureStorage implements FlutterSecureStorage {
  final Map<String, String> values = <String, String>{};
  int readCount = 0;
  int writeCount = 0;
  Completer<void>? readBarrier;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        readCount++;
        return () async {
          await readBarrier?.future;
          return key == null ? null : values[key];
        }();
      case #write:
        writeCount++;
        final value = invocation.namedArguments[#value] as String?;
        if (key == null) return Future<void>.value();
        if (value == null) {
          values.remove(key);
        } else {
          values[key] = value;
        }
        return Future<void>.value();
      case #delete:
        if (key != null) values.remove(key);
        return Future<void>.value();
      default:
        throw UnimplementedError('Unexpected secure-storage call: $invocation');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'both identity reads start before either secure-store read finishes',
    () async {
      final barrier = Completer<void>();
      final storage = _MemorySecureStorage()..readBarrier = barrier;
      final service = NetworkIdentityService(secureStorage: storage);
      final identity = service.loadOrCreate();
      try {
        await Future<void>.delayed(Duration.zero);
        expect(storage.readCount, 2);
        expect(storage.writeCount, 0);
      } finally {
        barrier.complete();
        await identity;
      }
    },
  );

  test(
    'concurrent callers share one generated Ed25519/X25519 identity',
    () async {
      final storage = _MemorySecureStorage();
      final service = NetworkIdentityService(secureStorage: storage);

      final first = service.loadOrCreate();
      final second = service.loadOrCreate();
      final identities = await Future.wait(<Future<NetworkIdentityBundle>>[
        first,
        second,
      ]);

      expect(identities[0], same(identities[1]));
      expect(identities[0].ed25519PrivateSeed, hasLength(32));
      expect(identities[0].ed25519PublicKey, hasLength(32));
      expect(identities[0].x25519PrivateSeed, hasLength(32));
      expect(identities[0].x25519PublicKey, hasLength(32));
      expect(storage.readCount, 2);
      expect(storage.writeCount, 2);
    },
  );

  test('a new service reconstructs the persisted identity exactly', () async {
    final storage = _MemorySecureStorage();
    final original = await NetworkIdentityService(
      secureStorage: storage,
    ).loadOrCreate();

    final restored = await NetworkIdentityService(
      secureStorage: storage,
    ).loadOrCreate();

    expect(restored.ed25519PrivateSeed, original.ed25519PrivateSeed);
    expect(restored.ed25519PublicKey, original.ed25519PublicKey);
    expect(restored.x25519PrivateSeed, original.x25519PrivateSeed);
    expect(restored.x25519PublicKey, original.x25519PublicKey);
    expect(storage.writeCount, 2);
  });

  test(
    'invalid persisted seed fails closed and can be corrected explicitly',
    () async {
      final storage = _MemorySecureStorage()
        ..values['network_quic_ed25519_seed_v1'] = base64UrlEncode(<int>[
          1,
          2,
          3,
        ]);
      final service = NetworkIdentityService(secureStorage: storage);

      await expectLater(
        service.loadOrCreate(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('QUIC Ed25519'),
          ),
        ),
      );

      storage.values.remove('network_quic_ed25519_seed_v1');
      final corrected = await service.loadOrCreate();
      expect(corrected.ed25519PrivateSeed, hasLength(32));
      expect(corrected.x25519PrivateSeed, hasLength(32));
    },
  );
}
