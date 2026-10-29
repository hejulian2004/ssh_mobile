import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/android_credential_crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ssh_mobile/credential_protection');
  late AndroidCredentialCrypto crypto;
  late List<MethodCall> calls;
  Object? reply;
  String? errorCode;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    reply = true;
    errorCode = null;
    crypto = AndroidCredentialCrypto(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (errorCode != null) {
            throw PlatformException(
              code: errorCode!,
              message: 'untrusted-private-detail',
            );
          }
          return reply;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'capability initialization is single flight and unsupported platforms stay cold',
    () async {
      await Future.wait([crypto.initialize(), crypto.initialize()]);
      expect(crypto.supportsProtection, isTrue);
      expect(calls.map((call) => call.method), ['capability']);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final unsupported = AndroidCredentialCrypto(channel: channel);
      await unsupported.initialize();
      expect(unsupported.supportsProtection, isFalse);
      expect(calls, hasLength(1));
      await expectLater(
        unsupported.seal(
          connectionId: 'fixture',
          revision: 'revision',
          plaintext: Uint8List(1),
        ),
        throwsA(isA<CredentialProtectionException>()),
      );
    },
  );

  test(
    'ciphertext and authenticated plaintext cross only the native bridge',
    () async {
      await crypto.initialize();
      reply = {'iv': Uint8List(12), 'ciphertext': Uint8List(17)};
      final sealed = await crypto.seal(
        connectionId: 'fixture',
        revision: 'fresh-revision',
        plaintext: Uint8List.fromList([7]),
      );
      expect(sealed.iv, Uint8List(12));
      expect(sealed.ciphertext.length, 17);
      final sealedCall = calls.last;
      expect(sealedCall.method, 'seal');
      expect((sealedCall.arguments as Map)['connectionId'], 'fixture');
      expect((sealedCall.arguments as Map)['revision'], 'fresh-revision');
      expect((sealedCall.arguments as Map)['operationId'], isA<String>());
      reply = Uint8List.fromList([7]);
      expect(
        await crypto.open(
          connectionId: 'fixture',
          revision: 'fresh-revision',
          ciphertext: sealed,
        ),
        [7],
      );
      expect(calls.last.method, 'open');
      expect((calls.last.arguments as Map)['ciphertext'], sealed.ciphertext);
      reply = true;
      await crypto.removeKey(
        connectionId: 'fixture',
        revision: 'fresh-revision',
      );
      expect(calls.last.method, 'removeKey');
    },
  );

  test(
    'native errors are typed and never reveal provider exception text',
    () async {
      await crypto.initialize();
      final expected = {
        'CREDENTIAL_CANCELLED': CredentialProtectionError.cancelled,
        'CREDENTIAL_UNAVAILABLE': CredentialProtectionError.unsupported,
        'CREDENTIAL_INVALIDATED': CredentialProtectionError.keyInvalidated,
        'CREDENTIAL_MISSING': CredentialProtectionError.keyInvalidated,
        'CREDENTIAL_BUSY': CredentialProtectionError.locked,
        'CREDENTIAL_INVALID_ARGUMENT': CredentialProtectionError.corrupt,
        'CREDENTIAL_CRYPTO': CredentialProtectionError.authenticationFailed,
        'UNKNOWN': CredentialProtectionError.authenticationFailed,
      };
      for (final entry in expected.entries) {
        errorCode = entry.key;
        await expectLater(
          crypto.seal(
            connectionId: 'fixture',
            revision: 'revision',
            plaintext: Uint8List(1),
          ),
          throwsA(
            isA<CredentialProtectionException>()
                .having((error) => error.code, 'code', entry.value)
                .having(
                  (error) => error.toString(),
                  'message',
                  isNot(contains('private-detail')),
                ),
          ),
        );
      }
    },
  );

  test(
    'missing native plugin disables protection without preventing App startup',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await crypto.initialize();
      expect(crypto.supportsProtection, isFalse);
    },
  );

  test('malformed responses fail closed', () async {
    await crypto.initialize();
    for (final raw in [
      null,
      {'iv': Uint8List(0), 'ciphertext': Uint8List(16)},
      {'iv': Uint8List(12), 'ciphertext': Uint8List(1)},
    ]) {
      reply = raw;
      await expectLater(
        crypto.seal(
          connectionId: 'fixture',
          revision: 'revision',
          plaintext: Uint8List(1),
        ),
        throwsA(isA<CredentialProtectionException>()),
      );
    }
    reply = 'invalid-plaintext';
    await expectLater(
      crypto.open(
        connectionId: 'fixture',
        revision: 'revision',
        ciphertext: CredentialCiphertext(
          iv: Uint8List(12),
          ciphertext: Uint8List(16),
        ),
      ),
      throwsA(isA<CredentialProtectionException>()),
    );
  });

  test(
    'oversized input and invalid envelopes never reach the platform',
    () async {
      await crypto.initialize();
      await expectLater(
        crypto.seal(
          connectionId: 'fixture',
          revision: 'revision',
          plaintext: Uint8List(512 * 1024 + 1),
        ),
        throwsA(isA<CredentialProtectionException>()),
      );
      await expectLater(
        crypto.open(
          connectionId: 'fixture',
          revision: 'revision',
          ciphertext: CredentialCiphertext(
            iv: Uint8List(0),
            ciphertext: Uint8List(16),
          ),
        ),
        throwsA(isA<CredentialProtectionException>()),
      );
      expect(calls.map((c) => c.method), ['capability']);
      reply = false;
      await expectLater(
        crypto.removeKey(connectionId: 'fixture', revision: 'revision'),
        throwsA(isA<CredentialProtectionException>()),
      );
    },
  );
  testWidgets('a stalled native capability cannot keep App startup waiting', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => pending.future);
    var completed = false;
    final initializing = crypto.initialize().then((_) => completed = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    final completedWithinDeadline = completed;
    pending.complete(true);
    await tester.pump();
    await initializing;
    expect(completedWithinDeadline, isTrue);
    expect(crypto.supportsProtection, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}
