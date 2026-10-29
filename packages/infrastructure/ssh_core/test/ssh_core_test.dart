import 'dart:async';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

void main() {
  group('SshSessionManagerImpl', () {
    test(
      'concurrent ensureInitialized calls share one initialization',
      () async {
        final runtime = _FakeRuntime();
        final manager = SshSessionManagerImpl(
          runtime: runtime,
          sessionPool: SshSessionPool(idleTimeout: Duration.zero),
        );

        final first = manager.ensureInitialized();
        final second = manager.ensureInitialized();
        expect(identical(first, second), isTrue);
        runtime.completeInitialization();
        await Future.wait([first, second]);
        expect(runtime.initializeCount, 1);
        expect(manager.initialized, isTrue);

        await manager.close();
        expect(runtime.disposeCount, 1);
        await manager.close();
        expect(runtime.disposeCount, 1);
      },
    );

    test('initialization failure resets state and can retry', () async {
      final runtime = _FakeRuntime(failFirstInitialization: true);
      final manager = SshSessionManagerImpl(runtime: runtime);

      await expectLater(manager.ensureInitialized(), throwsStateError);
      expect(manager.initialized, isFalse);
      final retry = manager.ensureInitialized();
      runtime.completeInitialization();
      await retry;
      expect(manager.initialized, isTrue);
      expect(runtime.initializeCount, 2);
      await manager.close();
    });

    test(
      'multiple consumers share a session and idle cleanup closes its stream',
      () async {
        final runtime = _FakeRuntime();
        final manager = SshSessionManagerImpl(
          runtime: runtime,
          sessionPool: SshSessionPool(
            idleTimeout: const Duration(milliseconds: 10),
          ),
        );
        var creates = 0;
        final firstFuture = manager.acquire(
          sessionId: 'session-a',
          create: () async {
            creates++;
            return SshSession(
              id: 'session-a',
              connectionId: 'connection-a',
              connectionName: 'Server A',
            );
          },
        );
        runtime.completeInitialization();
        final first = await firstFuture;
        final done = Completer<void>();
        first.session.output.listen((_) {}, onDone: done.complete);
        final second = await manager.acquire(
          sessionId: 'session-a',
          create: () async {
            creates++;
            return SshSession(
              id: 'session-a',
              connectionId: 'connection-a',
              connectionName: 'Server A',
            );
          },
        );

        expect(identical(first.session, second.session), isTrue);
        expect(creates, 1);
        await first.release();
        expect(second.isReleased, isFalse);
        await second.release();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await done.future;

        await manager.close();
      },
    );

    test('pool exposes idle timer count for lifecycle diagnostics', () async {
      final pool = SshSessionPool(
        idleTimeout: const Duration(milliseconds: 20),
      );
      final lease = await pool.acquire(
        sessionId: 'session-a',
        create: () async => SshSession(
          id: 'session-a',
          connectionId: 'connection-a',
          connectionName: 'Server A',
        ),
      );

      expect(pool.idleTimerCount, 0);
      await lease.release();
      expect(pool.idleTimerCount, 1);
      await pool.close();
      expect(pool.idleTimerCount, 0);
    });
  });

  group('SshClientFactory native stream', () {
    test('revoked credential approval fails before any Socket opens', () async {
      final connector = _ThrowingConnector();
      final factory = SshClientFactory(
        credentialRepository: _FakeCredentialRepository(),
        hostKeyRepository: _FakeHostKeyRepository(),
        logger: _FakeLogger(),
        nativeStreamConnector: connector,
      );
      await expectLater(
        factory.connectClient(
          ConnectionConfig(
            id: 'fixture',
            name: 'Public fixture',
            host: 'fixture.example.invalid',
            username: 'fixture',
            authMethod: AuthMethod.password,
          ),
          credentials: const SshCredentials(
            password: 'public-fixture',
            privateKey: null,
          ),
          peerId: 'fixture-peer',
          validateTarget: (_) async =>
              throw StateError('approval_target_changed'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            'approval_target_changed',
          ),
        ),
      );
      expect(connector.openedPeerIds, isEmpty);
    });
    test(
      'connectClient opens a native stream when peerId is provided',
      () async {
        final connector = _ThrowingConnector();
        final factory = SshClientFactory(
          credentialRepository: _FakeCredentialRepository(),
          hostKeyRepository: _FakeHostKeyRepository(),
          logger: _FakeLogger(),
          nativeStreamConnector: connector,
        );
        final config = ConnectionConfig(
          id: 'id',
          name: 'server',
          host: 'example.com',
          username: 'user',
          authMethod: AuthMethod.password,
        );

        await expectLater(
          factory.connectClient(
            config,
            credentials: const SshCredentials(password: 'pw', privateKey: null),
            peerId: 'peer-a',
            traceId: 'trace-a',
          ),
          throwsA(isA<StateError>()),
        );
        expect(connector.openedPeerIds, ['peer-a']);
        expect(connector.openedTraceIds, ['trace-a']);
      },
    );

    test(
      'connectClient does not open a native stream without a peer binding',
      () async {
        final connector = _ThrowingConnector();
        final factory = SshClientFactory(
          credentialRepository: _FakeCredentialRepository(),
          hostKeyRepository: _FakeHostKeyRepository(),
          logger: _FakeLogger(),
          nativeStreamConnector: connector,
        );
        final config = ConnectionConfig(
          id: 'id',
          name: 'server',
          host: '127.0.0.1',
          port: 1,
          username: 'user',
          authMethod: AuthMethod.password,
        );

        await expectLater(
          factory.connectClient(
            config,
            credentials: const SshCredentials(password: 'pw', privateKey: null),
            timeout: const Duration(seconds: 2),
          ),
          throwsA(anything),
        );
        expect(connector.openedPeerIds, isEmpty);
      },
    );
  });

  group('SshClientFactory contracts', () {
    test('answers one hidden password prompt only', () {
      final responses =
          SshClientFactory.keyboardInteractiveResponsesForPassword(
            const _KeyboardRequest([_KeyboardPrompt('Password: ', false)]),
            'secret',
          );
      expect(responses, ['secret']);
      expect(
        SshClientFactory.keyboardInteractiveResponsesForPassword(
          const _KeyboardRequest([
            _KeyboardPrompt('Password: ', false),
            _KeyboardPrompt('Verification code: ', false),
          ]),
          'secret',
        ),
        isNull,
      );
    });

    test('answers a keyboard-interactive username and password challenge', () {
      final responses =
          SshClientFactory.keyboardInteractiveResponsesForPassword(
            const _KeyboardRequest([
              _KeyboardPrompt('Login: ', true),
              _KeyboardPrompt('密码：', false),
            ]),
            'secret',
            username: 'alice',
          );

      expect(responses, ['alice', 'secret']);
    });

    test(
      'exposes the entered password to the password auth callback',
      () async {
        final options = SshClientFactory.buildAuthOptions(
          config: ConnectionConfig(
            id: 'connection-a',
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

    test('target binding excludes secrets and detects route edits', () {
      final config = ConnectionConfig(
        id: 'connection-a',
        name: 'Server A',
        host: 'EXAMPLE.com',
        username: 'root',
        password: 'secret',
        privateKey: 'private-key',
      );
      final binding = SshTargetBinding.fromConfig(config);
      expect(binding.fingerprint, isNot(contains('secret')));
      expect(binding.config.password, isNull);
      expect(binding.config.privateKey, isNull);
      expect(binding.matches(config), isTrue);
      expect(
        binding.matches(config.copyWith(host: 'other.example.com')),
        isFalse,
      );
    });
  });

  group('SshHostKeyPolicy', () {
    test(
      'persistence failure leaves caller untrusted and retry confirms again',
      () async {
        final config = ConnectionConfig(
          id: 'connection-a',
          name: 'Server A',
          host: 'example.com',
          username: 'root',
        );
        var confirmationCount = 0;
        var persistenceCount = 0;
        final policy = SshHostKeyPolicy(
          now: () => DateTime.utc(2040),
          onUnknownHostKey: (_) {
            confirmationCount++;
            return true;
          },
          persistTrust: (candidate) async {
            persistenceCount++;
            expect(identical(candidate, config), isFalse);
            expect(candidate.hostKeyAlgorithm, 'ssh-ed25519');
            expect(
              candidate.hostKeyFingerprint,
              'MD5:00:01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f',
            );
            expect(candidate.hostKeyTrustedAt, DateTime.utc(2040));
            throw StateError('host key database unavailable');
          },
        );
        final fingerprint = Uint8List.fromList(
          List<int>.generate(16, (i) => i),
        );

        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            policy.verifyHostKey(
              config: config,
              algorithm: 'ssh-ed25519',
              md5Fingerprint: fingerprint,
            ),
            throwsStateError,
          );
          expect(config.hostKeyAlgorithm, isNull);
          expect(config.hostKeyFingerprint, isNull);
          expect(config.hostKeyTrustedAt, isNull);
        }
        expect(confirmationCount, 2);
        expect(persistenceCount, 2);
      },
    );
  });
}

final class _FakeRuntime implements SshRuntimeAdapter {
  _FakeRuntime({this.failFirstInitialization = false});

  final bool failFirstInitialization;
  final StreamController<SshRuntimeEvent> _events =
      StreamController<SshRuntimeEvent>.broadcast();
  Completer<void>? _initializationCompleter;
  int initializeCount = 0;
  int disposeCount = 0;

  @override
  bool get supportsBackgroundService => false;

  @override
  Stream<SshRuntimeEvent> get events => _events.stream;

  @override
  Future<void> ensureInitialized() {
    initializeCount++;
    if (failFirstInitialization && initializeCount == 1) {
      return Future<void>.error(StateError('initialization failed'));
    }
    final completer = Completer<void>();
    _initializationCompleter = completer;
    return completer.future;
  }

  void completeInitialization() {
    _initializationCompleter?.complete();
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _events.close();
  }
}

final class _ThrowingConnector implements SshNativeStreamConnector {
  final List<String> openedPeerIds = <String>[];
  final List<String?> openedTraceIds = <String?>[];

  @override
  Future<SshNativeStream> open({
    required String peerId,
    String service = kSshNativeStreamService,
    String? traceId,
  }) {
    openedPeerIds.add(peerId);
    openedTraceIds.add(traceId);
    throw StateError('native stream open failed');
  }

  @override
  Future<void> closeAll() async {}
}

final class _FakeCredentialRepository implements CredentialRepository {
  @override
  Future<String?> getPassword(String connectionId) async => null;

  @override
  Future<String?> getPrivateKey(String connectionId) async => null;

  @override
  Future<void> saveCredentials({
    required String connectionId,
    String? password,
    String? privateKey,
  }) async {}

  @override
  Future<void> deleteCredentials(String connectionId) async {}
}

final class _FakeHostKeyRepository implements HostKeyRepository {
  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {}
}

final class _FakeLogger implements AppLogger {
  @override
  void log(LogRecord record) {}

  @override
  AppLogger scope(String name) => this;
}

final class _KeyboardRequest {
  const _KeyboardRequest(this.prompts);

  final List<_KeyboardPrompt> prompts;
}

final class _KeyboardPrompt {
  const _KeyboardPrompt(this.promptText, this.echo);

  final String promptText;
  final bool echo;
}
