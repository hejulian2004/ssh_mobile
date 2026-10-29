import 'dart:async';
import 'dart:typed_data';

import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

void main() {
  final fingerprint = Uint8List.fromList(
    List<int>.generate(16, (index) => index),
  );
  final revoked = const CredentialProtectionException(
    CredentialProtectionError.stale,
  );
  ConnectionConfig config() => ConnectionConfig(
    id: 'fixture',
    name: 'Fixture',
    host: 'fixture.invalid',
    username: 'fixture-user',
  );

  for (final change in ['credential revision', 'remote target']) {
    test(
      'Host Key approval cannot authenticate after $change changes during the prompt',
      () async {
        final selected = config();
        final prompt = Completer<void>();
        final answer = Completer<bool>();
        var current = true;
        var trustWrites = 0;
        final policy = SshHostKeyPolicy(
          onUnknownHostKey: (_) {
            prompt.complete();
            return answer.future;
          },
          persistTrust: (_) async {
            trustWrites++;
          },
          validateTarget: (_) async {
            if (!current) throw revoked;
          },
        );
        final verification = policy.verifyHostKey(
          config: selected,
          algorithm: 'ssh-ed25519',
          md5Fingerprint: fingerprint,
        );
        final rejected = expectLater(verification, throwsA(same(revoked)));
        await prompt.future;
        current = false;
        answer.complete(true);
        await rejected;
        expect(trustWrites, 0);
        expect(selected.hostKeyFingerprint, isNull);
      },
    );
  }

  test('a trusted key still requires a current credential revision', () async {
    final selected = config()
      ..hostKeyAlgorithm = 'ssh-ed25519'
      ..hostKeyFingerprint = SshHostKeyPolicy.formatMd5Fingerprint(fingerprint);
    final policy = SshHostKeyPolicy(
      validateTarget: (_) async {
        throw revoked;
      },
    );
    await expectLater(
      policy.verifyHostKey(
        config: selected,
        algorithm: 'ssh-ed25519',
        md5Fingerprint: fingerprint,
      ),
      throwsA(same(revoked)),
    );
  });

  test(
    'only a valid first Host Key may enrich the authenticated snapshot',
    () async {
      final selected = config();
      ConnectionConfig? authenticated;
      final policy = SshHostKeyPolicy(
        onUnknownHostKey: (_) async => true,
        persistTrust: (value) async {
          expect(value.hostKeyAlgorithm, 'ssh-ed25519');
          expect(value.host, 'fixture.invalid');
        },
        validateTarget: (value) async {
          if (value == null) return;
          expect(value.id, 'fixture');
          expect(value.host, 'fixture.invalid');
          expect(value.username, 'fixture-user');
          expect(
            value.hostKeyFingerprint,
            SshHostKeyPolicy.formatMd5Fingerprint(fingerprint),
          );
          authenticated = value;
        },
      );
      expect(
        await policy.verifyHostKey(
          config: selected,
          algorithm: 'ssh-ed25519',
          md5Fingerprint: fingerprint,
        ),
        isTrue,
      );
      expect(authenticated, isNotNull);
    },
  );

  test(
    'revocation during trust persistence cannot grant authentication permission',
    () async {
      final selected = config();
      final writing = Completer<void>();
      final commit = Completer<void>();
      var current = true;
      final policy = SshHostKeyPolicy(
        onUnknownHostKey: (_) async => true,
        persistTrust: (_) async {
          writing.complete();
          await commit.future;
        },
        validateTarget: (_) async {
          if (!current) throw revoked;
        },
      );
      final verification = policy.verifyHostKey(
        config: selected,
        algorithm: 'ssh-ed25519',
        md5Fingerprint: fingerprint,
      );
      final rejected = expectLater(verification, throwsA(same(revoked)));
      await writing.future;
      current = false;
      commit.complete();
      await rejected;
    },
  );
}
