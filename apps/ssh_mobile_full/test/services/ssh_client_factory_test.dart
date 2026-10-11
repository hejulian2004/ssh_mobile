import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_mobile/core/services/ssh_host_key_policy.dart';
import 'package:connection_core/connection_core.dart';
import 'package:ssh_mobile/core/services/ssh_client_factory.dart';

void main() {
  group('SshClientFactory', () {
    test(
      'answers a single hidden keyboard-interactive prompt with the password',
      () {
        final responses =
            SshClientFactory.keyboardInteractiveResponsesForPassword(
              const _FakeKeyboardInteractiveRequest('password', [
                _FakeKeyboardInteractivePrompt('Password: ', false),
              ]),
              'secret',
            );
        expect(responses, ['secret']);
      },
    );

    test(
      'skips multi-factor keyboard-interactive prompts it cannot answer safely',
      () {
        final responses =
            SshClientFactory.keyboardInteractiveResponsesForPassword(
              const _FakeKeyboardInteractiveRequest('mfa', [
                _FakeKeyboardInteractivePrompt('Password: ', false),
                _FakeKeyboardInteractivePrompt('Verification code: ', false),
              ]),
              'secret',
            );
        expect(responses, isNull);
      },
    );

    test('answers username and localized password prompts', () {
      final responses =
          SshClientFactory.keyboardInteractiveResponsesForPassword(
            const _FakeKeyboardInteractiveRequest('login', [
              _FakeKeyboardInteractivePrompt('Login: ', true),
              _FakeKeyboardInteractivePrompt('密码：', false),
            ]),
            'secret',
            username: 'alice',
          );

      expect(responses, ['alice', 'secret']);
    });

    test(
      'passes the exact saved password to password authentication',
      () async {
        final options = SshClientFactory.buildAuthOptions(
          config: ConnectionConfig(
            id: 'id',
            name: 'server',
            host: 'example.com',
            username: 'alice',
            authMethod: AuthMethod.password,
          ),
          credentials: const SshCredentials(
            password: 'secret with spaces',
            privateKey: null,
          ),
          identities: null,
        );

        expect(await options.onPasswordRequest!(), 'secret with spaces');
      },
    );

    test('rejects password auth when the password is missing', () {
      expect(
        () => SshClientFactory.validateAuthSecrets(
          config: ConnectionConfig(
            id: 'id',
            name: 'server',
            host: 'example.com',
            username: 'user',
            authMethod: AuthMethod.password,
          ),
          password: null,
          privateKey: null,
        ),
        throwsStateError,
      );
    });

    test('does not expose password callbacks for private-key-only auth', () {
      final options = SshClientFactory.buildAuthOptions(
        config: ConnectionConfig(
          id: 'id',
          name: 'server',
          host: 'example.com',
          username: 'user',
          authMethod: AuthMethod.privateKey,
        ),
        credentials: const SshCredentials(password: null, privateKey: null),
        identities: null,
      );

      expect(options.onPasswordRequest, isNull);
      expect(options.onUserInfoRequest, isNull);
    });

    test(
      'host key policy trusts an unknown key only after confirmation',
      () async {
        final config = ConnectionConfig(
          id: 'id',
          name: 'server',
          host: 'example.com',
          username: 'user',
        );
        var persisted = false;
        final policy = SshHostKeyPolicy(
          onUnknownHostKey: (request) {
            expect(
              request.fingerprint,
              'MD5:00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f',
            );
            return true;
          },
          persistTrust: (config) async {
            persisted = true;
          },
          now: () => DateTime.utc(2026, 6, 18, 10, 0),
        );

        final accepted = await policy.verifyHostKey(
          config: config,
          algorithm: 'ssh-ed25519',
          md5Fingerprint: Uint8List.fromList(
            List<int>.generate(16, (index) => index),
          ),
        );

        expect(accepted, isTrue);
        expect(persisted, isTrue);
        expect(config.hostKeyAlgorithm, 'ssh-ed25519');
        expect(
          config.hostKeyFingerprint,
          'MD5:00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f',
        );
        expect(config.hostKeyTrustedAt, DateTime.utc(2026, 6, 18, 10, 0));
      },
    );

    test(
      'host key policy rejects unknown hosts without a confirmation callback',
      () async {
        final policy = SshHostKeyPolicy();
        final config = ConnectionConfig(
          id: 'id',
          name: 'server',
          host: 'example.com',
          username: 'user',
        );

        expect(
          policy.verifyHostKey(
            config: config,
            algorithm: 'ssh-ed25519',
            md5Fingerprint: Uint8List(16),
          ),
          throwsA(isA<SshHostKeyUntrustedException>()),
        );
      },
    );

    test(
      'host key policy allows trusted fingerprint with same algorithm',
      () async {
        final policy = SshHostKeyPolicy();
        final config = ConnectionConfig(
          id: 'id',
          name: 'server',
          host: 'example.com',
          username: 'user',
          hostKeyAlgorithm: 'ssh-ed25519',
          hostKeyFingerprint:
              'MD5:00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f',
        );

        final accepted = await policy.verifyHostKey(
          config: config,
          algorithm: 'ssh-ed25519',
          md5Fingerprint: Uint8List.fromList(
            List<int>.generate(16, (index) => index),
          ),
        );

        expect(accepted, isTrue);
      },
    );

    test(
      'host key policy blocks trusted fingerprint with changed algorithm',
      () async {
        final policy = SshHostKeyPolicy();
        final config = ConnectionConfig(
          id: 'id',
          name: 'server',
          host: 'example.com',
          username: 'user',
          hostKeyAlgorithm: 'ssh-ed25519',
          hostKeyFingerprint:
              'MD5:00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f',
        );

        expect(
          policy.verifyHostKey(
            config: config,
            algorithm: 'rsa-sha2-512',
            md5Fingerprint: Uint8List.fromList(
              List<int>.generate(16, (index) => index),
            ),
          ),
          throwsA(isA<SshHostKeyMismatchException>()),
        );
      },
    );

    test('host key policy matches normalized MD5 fingerprints', () async {
      final policy = SshHostKeyPolicy();
      final config = ConnectionConfig(
        id: 'id',
        name: 'server',
        host: 'example.com',
        username: 'user',
        hostKeyAlgorithm: 'ssh-ed25519',
        hostKeyFingerprint: '000102030405060708090A0B0C0D0E0F',
      );

      final accepted = await policy.verifyHostKey(
        config: config,
        algorithm: 'ssh-ed25519',
        md5Fingerprint: Uint8List.fromList(
          List<int>.generate(16, (index) => index),
        ),
      );

      expect(accepted, isTrue);
    });

    test(
      'host key policy rejects when confirmation callback declines',
      () async {
        final policy = SshHostKeyPolicy(onUnknownHostKey: (_) => false);
        final config = ConnectionConfig(
          id: 'id',
          name: 'server',
          host: 'example.com',
          username: 'user',
        );

        expect(
          policy.verifyHostKey(
            config: config,
            algorithm: 'ssh-ed25519',
            md5Fingerprint: Uint8List(16),
          ),
          throwsA(isA<SshHostKeyRejectedException>()),
        );
      },
    );

    test('host key policy blocks changed fingerprints', () async {
      final policy = SshHostKeyPolicy(onUnknownHostKey: (_) => true);
      final config = ConnectionConfig(
        id: 'id',
        name: 'server',
        host: 'example.com',
        username: 'user',
        hostKeyAlgorithm: 'ssh-ed25519',
        hostKeyFingerprint:
            'MD5:00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f',
      );

      expect(
        policy.verifyHostKey(
          config: config,
          algorithm: 'ssh-ed25519',
          md5Fingerprint: Uint8List.fromList(
            List<int>.generate(16, (index) => 15 - index),
          ),
        ),
        throwsA(isA<SshHostKeyMismatchException>()),
      );
    });

    test('host key exceptions implement SSHError', () {
      expect(
        const SshHostKeyUntrustedException(
          connectionName: 'test',
          host: '127.0.0.1',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: 'MD5:...',
        ),
        isA<SSHError>(),
      );
      expect(
        const SshHostKeyRejectedException(
          connectionName: 'test',
          host: '127.0.0.1',
          port: 22,
          algorithm: 'ssh-ed25519',
          fingerprint: 'MD5:...',
        ),
        isA<SSHError>(),
      );
      expect(
        const SshHostKeyMismatchException(
          connectionName: 'test',
          host: '127.0.0.1',
          port: 22,
          expectedAlgorithm: 'ssh-ed25519',
          expectedFingerprint: 'MD5:...',
          actualAlgorithm: 'ssh-ed25519',
          actualFingerprint: 'MD5:abc...',
        ),
        isA<SSHError>(),
      );
    });
  });
}

class _FakeKeyboardInteractiveRequest {
  final String name;
  final List<_FakeKeyboardInteractivePrompt> prompts;

  const _FakeKeyboardInteractiveRequest(this.name, this.prompts);
}

class _FakeKeyboardInteractivePrompt {
  final String promptText;
  final bool echo;

  const _FakeKeyboardInteractivePrompt(this.promptText, this.echo);
}
