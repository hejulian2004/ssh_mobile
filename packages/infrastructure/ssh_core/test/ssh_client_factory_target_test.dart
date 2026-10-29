import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

void main() {
  test(
    'a target revoked while native open is pending releases the new socket before SSH starts',
    () async {
      final stream = _MemoryNativeStream();
      final connector = _MemoryConnector(stream, delayed: true);
      final logger = _Logger();
      final factory = _factory(connector, logger);
      final revoked = StateError('approval_target_changed');
      var current = true;
      var validations = 0;
      final connecting = factory.connectClient(
        _config(),
        credentials: _credentials,
        peerId: 'peer-a',
        traceId: 'fixture-trace',
        validateTarget: (_) async {
          validations++;
          if (!current) throw revoked;
        },
      );
      final rejected = expectLater(connecting, throwsA(same(revoked)));
      await connector.opened.future;
      expect(stream.sent, isEmpty);
      current = false;
      connector.completeOpen();
      await rejected;
      expect(validations, 3);
      expect(connector.requests, [
        ('peer-a', kSshNativeStreamService, 'fixture-trace'),
      ]);
      expect(
        stream.sent,
        isEmpty,
        reason:
            'The SSHClient must not send even its identification before final approval.',
      );
      expect(stream.closeCalls, 1);
      expect(stream.destroyCalls, 0);
      expect(stream.releases, 1);
      expect(stream.incomingCancellations, 1);
      expect(
        connector.closeAllCalls,
        0,
        reason: 'Only this borrowed stream can be released.',
      );
    },
  );

  test(
    'an asynchronous validation failure after socket readiness releases only that stream',
    () async {
      final stream = _MemoryNativeStream();
      final connector = _MemoryConnector(stream);
      final factory = _factory(connector, _Logger());
      final approval = Completer<void>();
      final pending = Completer<void>();
      final rejectedApproval = StateError('credential_revision_changed');
      var validations = 0;
      final connecting = factory.connectClient(
        _config(),
        credentials: _credentials,
        peerId: 'peer-a',
        validateTarget: (_) async {
          validations++;
          if (validations == 3) {
            pending.complete();
            await approval.future;
            throw rejectedApproval;
          }
        },
      );
      final rejected = expectLater(connecting, throwsA(same(rejectedApproval)));
      await pending.future;
      expect(stream.sent, isEmpty);
      expect(stream.releases, 0);
      approval.complete();
      await rejected;
      expect(stream.sent, isEmpty);
      expect(stream.releases, 1);
      expect(stream.closeCalls, 1);
      expect(stream.incomingCancellations, 1);
    },
  );

  test(
    'a rejected socket whose graceful close fails is forcibly released and preserves original error',
    () async {
      final stream = _MemoryNativeStream()..failClose = true;
      addTearDown(stream.forceRelease);
      final connector = _MemoryConnector(stream);
      final logger = _Logger();
      final factory = _factory(connector, logger);
      final rejection = StateError('approval_revoked');
      var validations = 0;
      await expectLater(
        factory.connectClient(
          _config(),
          credentials: _credentials,
          peerId: 'peer-a',
          validateTarget: (_) async {
            if (++validations == 3) throw rejection;
          },
        ),
        throwsA(same(rejection)),
      );
      expect(stream.sent, isEmpty);
      expect(stream.closeCalls, 1);
      expect(
        stream.releases,
        1,
        reason:
            'A failed graceful close cannot leave the borrowed native stream owned forever.',
      );
      expect(stream.destroyCalls, 1);
      expect(connector.closeAllCalls, 0);
      expect(
        logger.records.any(
          (record) =>
              record.message ==
              'SSH socket cleanup failed after client setup failure',
        ),
        isTrue,
      );
    },
  );

  for (final validate in [true, false]) {
    test(
      'a ${validate ? 'valid target callback' : 'legacy caller'} reaches the existing SSH handshake',
      () async {
        final stream = _MemoryNativeStream()..rejectBanner = true;
        addTearDown(stream.forceRelease);
        final connector = _MemoryConnector(stream);
        var validations = 0;
        final factory = _factory(
          connector,
          _Logger(),
          peerIdResolver: (_) => 'resolved-peer',
        );
        await expectLater(
          factory.connectClient(
            _config(),
            credentials: _credentials,
            timeout: const Duration(seconds: 2),
            validateTarget: validate
                ? (_) async {
                    validations++;
                  }
                : null,
          ),
          throwsA(isA<SSHAuthAbortError>()),
        );
        expect(validations, validate ? 3 : 0);
        expect(connector.requests.single.$1, 'resolved-peer');
        expect(latin1.decode(stream.sent.first), startsWith('SSH-2.0-'));
        expect(
          latin1.decode(stream.sent.expand((chunk) => chunk).toList()),
          isNot(contains('fixture-password')),
        );
        expect(stream.releases, 1);
        expect(stream.incomingCancellations, 1);
        expect(connector.closeAllCalls, 0);
      },
    );
  }

  test(
    'revocation rejects before attempting to parse a supplied private key',
    () async {
      final stream = _MemoryNativeStream();
      final connector = _MemoryConnector(stream);
      final rejection = StateError('approval_revoked_before_identity');
      final config = _config()..authMethod = AuthMethod.both;
      await expectLater(
        _factory(connector, _Logger()).connectClient(
          config,
          credentials: const SshCredentials(
            password: 'fixture-password',
            privateKey: 'not-a-PEM-key',
          ),
          peerId: 'peer-a',
          validateTarget: (_) async => throw rejection,
        ),
        throwsA(same(rejection)),
      );
      expect(connector.requests, isEmpty);
      expect(stream.sent, isEmpty);
      await stream.forceRelease();
    },
  );
}

const _credentials = SshCredentials(
  password: 'fixture-password',
  privateKey: null,
);
ConnectionConfig _config() => ConnectionConfig(
  id: 'connection-a',
  name: 'Fixture',
  host: 'fixture.invalid',
  username: 'fixture',
);

SshClientFactory _factory(
  _MemoryConnector connector,
  _Logger logger, {
  SshPeerIdResolver? peerIdResolver,
}) => SshClientFactory(
  credentialRepository: _Credentials(),
  hostKeyRepository: _HostKeys(),
  logger: logger,
  nativeStreamConnector: connector,
  peerIdResolver: peerIdResolver,
);

final class _MemoryConnector implements SshNativeStreamConnector {
  _MemoryConnector(this.stream, {bool delayed = false}) {
    if (!delayed) completeOpen();
  }
  final _MemoryNativeStream stream;
  final opened = Completer<void>();
  final _ready = Completer<SshNativeStream>();
  final requests = <(String, String, String?)>[];
  int closeAllCalls = 0;
  void completeOpen() {
    if (!_ready.isCompleted) _ready.complete(stream);
  }

  @override
  Future<SshNativeStream> open({
    required String peerId,
    String service = kSshNativeStreamService,
    String? traceId,
  }) {
    requests.add((peerId, service, traceId));
    opened.complete();
    return _ready.future;
  }

  @override
  Future<void> closeAll() async {
    closeAllCalls++;
    await stream.forceRelease();
  }
}

/// An actual in-memory byte transport, not an SSHClient or factory mock.
final class _MemoryNativeStream implements SshNativeStream {
  _MemoryNativeStream() {
    _incoming = StreamController<Uint8List>(
      onCancel: () {
        incomingCancellations++;
      },
    );
  }
  late final StreamController<Uint8List> _incoming;
  final _done = Completer<void>();
  final sent = <Uint8List>[];
  int closeCalls = 0;
  int destroyCalls = 0;
  int releases = 0;
  int incomingCancellations = 0;
  bool failClose = false;
  bool rejectBanner = false;
  bool _released = false;
  @override
  Stream<Uint8List> get incoming => _incoming.stream;
  @override
  Future<void> get done => _done.future;
  @override
  Future<void> send(Uint8List bytes) async {
    sent.add(Uint8List.fromList(bytes));
    if (rejectBanner && sent.length == 1) {
      _incoming.add(
        Uint8List.fromList(latin1.encode('invalid-protocol-banner\r\n')),
      );
    }
  }

  @override
  Future<void> close() async {
    closeCalls++;
    if (failClose) throw StateError('native_close_failed');
    await forceRelease();
  }

  @override
  void destroy() {
    destroyCalls++;
    unawaited(forceRelease());
  }

  Future<void> forceRelease() async {
    if (_released) return;
    _released = true;
    releases++;
    if (!_done.isCompleted) _done.complete();
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }
}

final class _Credentials extends Fake implements CredentialRepository {}

final class _HostKeys extends Fake implements HostKeyRepository {}

final class _Logger implements AppLogger {
  final records = <LogRecord>[];
  @override
  void log(LogRecord record) => records.add(record);
  @override
  AppLogger scope(String name) => this;
}
