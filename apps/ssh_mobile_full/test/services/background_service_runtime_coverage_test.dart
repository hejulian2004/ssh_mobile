import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/services/background_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'background runtime routes tmux IO and closes sessions safely',
    () async {
      final service = _FakeServiceInstance();
      final clients = <String, _FakeSshClient>{};
      startBackgroundSshRuntimeForTesting(
        service,
        sessionFactory: (data) async {
          final client = _FakeSshClient(_FakeSshSession());
          clients[data['sessionId'] as String] = client;
          return client;
        },
      );

      service.emit('sshConnect', <String, dynamic>{'name': 'missing id'});
      await _pump();
      expect(
        service.messages,
        contains('Ignoring sshConnect without sessionId'),
      );

      service.emit(
        'sshConnect',
        _connectData('runtime-tmux', launchMode: 'tmux'),
      );
      await _waitUntil(
        () => service.invocations.any(
          (call) =>
              call.method == 'sshStateChanged' &&
              call.args?['state'] == 'connected',
        ),
      );
      final tmux = clients['runtime-tmux']!;
      expect(
        tmux.session.stdinText,
        contains("tmux attach-session -t 'fixture_name'"),
      );
      expect(
        tmux.session.stdinText,
        contains('@ssh_mobile_auto_delete_seconds 30'),
      );

      service.emit('sshInput', <String, dynamic>{
        'sessionId': 'runtime-tmux',
        'data': 'echo ready\n',
      });
      service.emit('sshResize', <String, dynamic>{
        'sessionId': 'runtime-tmux',
        'width': 120,
        'height': 40,
      });
      tmux.session.emitStdout('stdout\n');
      tmux.session.emitStderr('stderr\n');
      await _pump();
      expect(tmux.session.stdinText, contains('echo ready\n'));
      expect(tmux.session.resizeCalls, <({int width, int height})>[
        (width: 120, height: 40),
      ]);
      expect(
        service.invocations.where((call) => call.method == 'sshDataReceived'),
        hasLength(2),
      );

      final overview = service.invocations
          .where((call) => call.method == 'sshOverviewUpdated')
          .last
          .args!;
      expect(overview['windowCount'], 1);
      expect((overview['overview'] as Map)['server-a']['count'], 1);

      service.emit(
        'sshConnect',
        _connectData('runtime-plain', launchMode: 'ssh'),
      );
      await _waitUntil(
        () =>
            service.invocations
                .where(
                  (call) =>
                      call.method == 'sshStateChanged' &&
                      call.args?['state'] == 'connected',
                )
                .length >=
            2,
      );
      final twoSessionOverview = service.invocations
          .where((call) => call.method == 'sshOverviewUpdated')
          .last
          .args!;
      expect(twoSessionOverview['windowCount'], 2);

      service.emit('sshDisconnect', <String, dynamic>{
        'sessionId': 'runtime-tmux',
      });
      await _waitUntil(
        () => service.invocations.any(
          (call) =>
              call.method == 'sshStateChanged' &&
              call.args?['sessionId'] == 'runtime-tmux' &&
              call.args?['state'] == 'disconnected',
        ),
      );
      expect(tmux.runCommands, contains(contains('tmux kill-session')));

      final plain = clients['runtime-plain']!;
      await plain.session.closeStdout();
      await _waitUntil(
        () => service.invocations.any(
          (call) =>
              call.method == 'sshStateChanged' &&
              call.args?['sessionId'] == 'runtime-plain' &&
              call.args?['state'] == 'disconnected',
        ),
      );

      service.emit('sshDisconnectAll', const <String, dynamic>{});
      await _pump();
      service.emit('stopService', const <String, dynamic>{});
      await _waitUntil(() => service.stopSelfCalls == 1);
      expect(
        service.invocations.map((call) => call.method),
        contains('sshServiceStopped'),
      );
      await service.dispose();
    },
  );

  test(
    'background runtime reports connection failures and ignores invalid input',
    () async {
      final service = _FakeServiceInstance();
      startBackgroundSshRuntimeForTesting(
        service,
        sessionFactory: (data) async {
          throw StateError('fixture connect failure');
        },
      );

      service.emit('sshConnect', _connectData('runtime-failure'));
      await _waitUntil(
        () => service.invocations.any(
          (call) =>
              call.method == 'sshStateChanged' &&
              call.args?['sessionId'] == 'runtime-failure' &&
              call.args?['state'] == 'error',
        ),
      );
      expect(service.messages, contains('SSH connection failed'));

      service.emit('sshInput', <String, dynamic>{
        'sessionId': 'missing',
        'data': 'ignored',
      });
      service.emit('sshResize', <String, dynamic>{
        'sessionId': 'missing',
        'width': null,
        'height': 24,
      });
      await _pump();
      expect(
        service.messages,
        contains('Ignoring input for missing SSH session'),
      );

      service.emit('stopService', const <String, dynamic>{});
      await _waitUntil(() => service.stopSelfCalls == 1);
      await service.dispose();
    },
  );

  test(
    'background runtime rejects missing password before creating a client',
    () async {
      final service = _FakeServiceInstance();
      var factoryCalled = false;
      startBackgroundSshRuntimeForTesting(
        service,
        sessionFactory: (_) async {
          factoryCalled = true;
          return _FakeSshClient(_FakeSshSession());
        },
      );

      final data = _connectData('runtime-missing-password');
      data['password'] = null;
      service.emit('sshConnect', data);

      await _waitUntil(
        () => _stateFor(service, 'runtime-missing-password') == 'error',
      );
      expect(factoryCalled, isFalse);
      expect(service.messages, contains('SSH connection failed'));

      service.emit('stopService', const <String, dynamic>{});
      await _waitUntil(() => service.stopSelfCalls == 1);
      await service.dispose();
    },
  );

  test(
    'background runtime reports tmux failures and releases partial clients',
    () async {
      final service = _FakeServiceInstance();
      final clients = <String, _FakeSshClient>{};
      startBackgroundSshRuntimeForTesting(
        service,
        sessionFactory: (data) async {
          final id = data['sessionId'] as String;
          final client = _FakeSshClient(
            _FakeSshSession(),
            tmuxExitCode: id == 'tmux-missing' ? 1 : 0,
            runError: id == 'tmux-error'
                ? StateError('tmux probe failed')
                : null,
            closeError: id == 'tmux-error'
                ? StateError('client close failed')
                : null,
          );
          clients[id] = client;
          return client;
        },
      );

      service.emit(
        'sshConnect',
        _connectData('tmux-missing', launchMode: 'tmux'),
      );
      await _waitUntil(() => _stateFor(service, 'tmux-missing') == 'error');
      expect(service.messages, contains('tmux is not installed on server'));

      service.emit(
        'sshConnect',
        _connectData('tmux-error', launchMode: 'tmux'),
      );
      await _waitUntil(() => _stateFor(service, 'tmux-error') == 'error');
      expect(clients['tmux-error']!.closeCalls, 1);
      expect(
        service.messages,
        contains('Failed to release SSH connection attempt resources'),
      );
      await service.dispose();
    },
  );

  test(
    'background runtime handles stdout errors and keep-alive outcomes',
    () async {
      final service = _FakeServiceInstance();
      final clients = <String, _FakeSshClient>{};
      startBackgroundSshRuntimeForTesting(
        service,
        sessionFactory: (data) async {
          final client = _FakeSshClient(
            _FakeSshSession(),
            pingError: data['sessionId'] == 'runtime-ping-failure'
                ? StateError('keep-alive failed')
                : null,
          );
          clients[data['sessionId'] as String] = client;
          return client;
        },
      );

      service.emit('sshConnect', _connectData('runtime-stream-error'));
      await _waitUntil(
        () => _stateFor(service, 'runtime-stream-error') == 'connected',
      );
      clients['runtime-stream-error']!.session.emitStdoutError(
        StateError('stdout fixture error'),
      );
      await _waitUntil(
        () => _stateFor(service, 'runtime-stream-error') == 'disconnected',
      );
      expect(service.messages, contains('SSH stdout stream error'));

      service.emit('sshConnect', _connectData('runtime-ping-success'));
      await _waitUntil(
        () => _stateFor(service, 'runtime-ping-success') == 'connected',
      );
      await _waitUntil(
        () => service.invocations.any(
          (call) =>
              call.method == 'sshKeepAlive' &&
              call.args?['sessionId'] == 'runtime-ping-success' &&
              call.args?['ok'] == true,
        ),
        timeout: const Duration(seconds: 5),
      );

      service.emit('sshConnect', _connectData('runtime-ping-failure'));
      await _waitUntil(
        () => _stateFor(service, 'runtime-ping-failure') == 'connected',
      );
      await _waitUntil(
        () => _stateFor(service, 'runtime-ping-failure') == 'disconnected',
        timeout: const Duration(seconds: 5),
      );
      expect(
        service.invocations.any(
          (call) =>
              call.method == 'sshKeepAlive' &&
              call.args?['sessionId'] == 'runtime-ping-failure' &&
              call.args?['ok'] == false,
        ),
        isTrue,
      );
      service.emit('stopService', const <String, dynamic>{});
      await _waitUntil(() => service.stopSelfCalls == 1);
      await service.dispose();
    },
  );

  test(
    'background socket boundary prefers native streams and falls back to TCP',
    () async {
      final connector = _FakeNativeConnector();
      sshBackgroundNativeStreamConnector = connector;
      addTearDown(() => sshBackgroundNativeStreamConnector = null);

      final socket = await openBackgroundSshSocketForTesting(
        host: 'ignored',
        port: 22,
        peerId: 'peer-native',
      );
      expect(socket, isA<ssh_core.SshNativeSocket>());
      await socket.close();
      expect(connector.openedPeerIds, <String>['peer-native']);

      sshBackgroundNativeStreamConnector = null;
      await expectLater(
        openBackgroundSshSocketForTesting(host: '127.0.0.1', port: 1),
        throwsA(isA<Object>()),
      );
    },
  );
}

Map<String, dynamic> _connectData(
  String sessionId, {
  String launchMode = 'ssh',
}) => <String, dynamic>{
  'sessionId': sessionId,
  'id': 'server-a',
  'name': 'Fixture Server',
  'host': '127.0.0.1',
  'port': 22,
  'username': 'fixture-user',
  'authMethod': 'password',
  'password': 'fixture-password',
  'terminalWidth': 80,
  'terminalHeight': 24,
  'keepAliveInterval': 3,
  'launchMode': launchMode,
  'tmuxSessionName': 'fixture.name',
  'tmuxAutoDeleteSeconds': 1,
  'showServerNameInNotification': true,
};

Future<void> _pump() => Future<void>.delayed(Duration.zero);

String? _stateFor(_FakeServiceInstance service, String sessionId) => service
    .invocations
    .where(
      (call) =>
          call.method == 'sshStateChanged' &&
          call.args?['sessionId'] == sessionId,
    )
    .map((call) => call.args?['state'] as String?)
    .lastOrNull;

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for background runtime fixture.');
}

final class _FakeServiceInstance implements ServiceInstance {
  final Map<String, StreamController<Map<String, dynamic>?>> _events = {};
  final List<({String method, Map<String, dynamic>? args})> invocations =
      <({String method, Map<String, dynamic>? args})>[];
  bool stopped = false;
  int stopSelfCalls = 0;

  Iterable<String> get messages => invocations
      .where((call) => call.method == 'sshLogReceived')
      .map((call) => call.args?['message'] as String? ?? '');

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    invocations.add((method: method, args: args));
  }

  @override
  Stream<Map<String, dynamic>?> on(String method) => _events
      .putIfAbsent(
        method,
        () => StreamController<Map<String, dynamic>?>.broadcast(sync: true),
      )
      .stream;

  void emit(String method, Map<String, dynamic> data) {
    _events[method]?.add(data);
  }

  @override
  Future<void> stopSelf() async {
    stopSelfCalls++;
    stopped = true;
  }

  Future<void> dispose() async {
    await Future.wait<void>(
      _events.values.map((controller) => controller.close()),
    );
  }
}

final class _FakeSshClient implements SSHClient {
  _FakeSshClient(
    this.session, {
    this.tmuxExitCode = 0,
    this.runError,
    this.pingError,
    this.closeError,
  });

  final _FakeSshSession session;
  final int tmuxExitCode;
  final Object? runError;
  final Object? pingError;
  final Object? closeError;
  int closeCalls = 0;
  int pingCalls = 0;
  final List<String> runCommands = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #authenticated) {
      return Future<void>.value();
    }
    if (invocation.memberName == #shell) {
      return Future<SSHSession>.value(session);
    }
    if (invocation.memberName == #ping) {
      pingCalls++;
      if (pingError != null) throw pingError!;
      return Future<void>.value();
    }
    if (invocation.memberName == #runWithResult) {
      runCommands.add(invocation.positionalArguments.first as String);
      if (runError != null) throw runError!;
      return Future<SSHRunResult>.value(
        SSHRunResult(
          output: Uint8List(0),
          stdout: Uint8List(0),
          stderr: Uint8List(0),
          exitCode: tmuxExitCode,
          exitSignal: null,
        ),
      );
    }
    if (invocation.memberName == #close) {
      closeCalls++;
      if (closeError != null) throw closeError!;
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}

final class _FakeSshSession implements SSHSession {
  final StreamController<Uint8List> _stdout =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<Uint8List> _stderr =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<Uint8List> _stdin =
      StreamController<Uint8List>.broadcast(sync: true);
  final List<({int width, int height})> resizeCalls =
      <({int width, int height})>[];
  final List<String> _stdinChunks = <String>[];
  int closeCalls = 0;

  String get stdinText => _stdinChunks.join();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #stdout) return _stdout.stream;
    if (invocation.memberName == #stderr) return _stderr.stream;
    if (invocation.memberName == #stdin) {
      return _RecordingSink(_stdin.sink, _stdinChunks);
    }
    if (invocation.memberName == #resizeTerminal) {
      resizeCalls.add((
        width: invocation.positionalArguments[0] as int,
        height: invocation.positionalArguments[1] as int,
      ));
      return null;
    }
    if (invocation.memberName == #close) {
      closeCalls++;
      return null;
    }
    if (invocation.memberName == #done) return Future<void>.value();
    return super.noSuchMethod(invocation);
  }

  void emitStdout(String value) =>
      _stdout.add(Uint8List.fromList(utf8.encode(value)));

  void emitStderr(String value) =>
      _stderr.add(Uint8List.fromList(utf8.encode(value)));

  void emitStdoutError(Object error) => _stdout.addError(error);

  Future<void> closeStdout() => _stdout.close();
}

final class _RecordingSink implements StreamSink<Uint8List> {
  _RecordingSink(this._delegate, this._chunks);

  final StreamSink<Uint8List> _delegate;
  final List<String> _chunks;

  @override
  void add(Uint8List data) {
    _chunks.add(utf8.decode(data));
    _delegate.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) =>
      _delegate.addStream(stream);

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<void> get done => _delegate.done;
}

final class _FakeNativeConnector implements ssh_core.SshNativeStreamConnector {
  final List<String> openedPeerIds = <String>[];

  @override
  Future<ssh_core.SshNativeStream> open({
    required String peerId,
    String service = ssh_core.kSshNativeStreamService,
    String? traceId,
  }) async {
    openedPeerIds.add(peerId);
    return _FakeNativeStream();
  }

  @override
  Future<void> closeAll() async {}
}

final class _FakeNativeStream implements ssh_core.SshNativeStream {
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  final Completer<void> _done = Completer<void>();

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async => destroy();

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }
}
