// SFTP Module 生命周期测试。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_core/app_core.dart';
import 'package:feature_sftp/feature_sftp.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/sftp_test_fakes.dart';

void main() {
  test(
    'Module dispose cancels its document transfer without closing the backend',
    () async {
      final manager = FakeSshSessionManager();
      final backend = FakeSftpBackend();
      final database = SftpDatabase.forTesting(NativeDatabase.memory());
      final module = SftpModule(databaseFactory: () => database);
      await module.register(
        ModuleContext.fromMap(<Type, Object>{
          SshSessionManager: manager,
          SftpBackend: backend,
        }),
      );
      await module.initialize();
      final service = module.service;
      await service.connect('connection-1');
      final started = Completer<void>();
      final cancelled = Completer<void>();
      backend.onDownloadFile =
          (entry, {required localPath, required maxBytes}) async {
            started.complete();
            await cancelled.future;
            throw const SftpTransferCancelledException();
          };
      backend.onCancelTransfer = () {
        cancelled.complete();
      };
      final operation = service.downloadToDocument(
        entry: const SftpEntry(
          connectionId: 'connection-1',
          targetFingerprint: 'fingerprint',
          name: 'sample.bin',
          path: '/sample.bin',
          lowerName: 'sample.bin',
          isDirectory: false,
          isLink: false,
          size: 3,
          sizeLabel: '3 B',
        ),
        sink: _DrainingSink()..abortGate.complete(),
      );
      final checked = expectLater(
        operation,
        throwsA(isA<SftpTransferCancelledException>()),
      );
      await started.future;
      await module.dispose();
      await checked;
      expect(cancelled.isCompleted, isTrue);
      expect(backend.isConnected, isTrue);
      expect(manager.closeCalls, 0);
    },
  );

  for (final direction in ['source', 'sink']) {
    test(
      'Module dispose drains a blocked document $direction before database close',
      () async {
        final manager = FakeSshSessionManager();
        final backend = FakeSftpBackend();
        final database = SftpDatabase.forTesting(NativeDatabase.memory());
        final module = SftpModule(databaseFactory: () => database);
        await module.register(
          ModuleContext.fromMap(<Type, Object>{
            SshSessionManager: manager,
            SftpBackend: backend,
          }),
        );
        await module.initialize();
        final service = module.service;
        await service.connect('connection-1');
        final source = _DrainingSource();
        final sink = _DrainingSink();
        File? staging;
        backend.onDownloadFile =
            (entry, {required localPath, required maxBytes}) async {
              staging = File(localPath);
              await staging!.writeAsBytes([1, 2, 3]);
            };
        final operation = direction == 'source'
            ? service.uploadFromDocument(source: source, filename: 'sample.bin')
            : service.downloadToDocument(
                entry: const SftpEntry(
                  connectionId: 'connection-1',
                  targetFingerprint: 'fingerprint',
                  name: 'sample.bin',
                  path: '/sample.bin',
                  lowerName: 'sample.bin',
                  isDirectory: false,
                  isLink: false,
                  size: 3,
                  sizeLabel: '3 B',
                ),
                sink: sink,
              );
        final operationChecked = expectLater(
          operation,
          throwsA(isA<SftpTransferCancelledException>()),
        );
        await (direction == 'source'
            ? source.readStarted.future
            : sink.closeStarted.future);
        var disposed = false;
        final disposal = module.dispose().then((_) {
          disposed = true;
        });
        await (direction == 'source'
            ? source.closeRequested.future
            : sink.abortRequested.future);
        try {
          await Future<void>.delayed(Duration.zero);
          expect(disposed, isFalse);
          expect(database.isDisposed, isFalse);
          expect(backend.isConnected, isTrue);
          if (staging != null) expect(await staging!.exists(), isTrue);
        } finally {
          source.closeGate.complete();
          sink.abortGate.complete();
          await operationChecked;
          await disposal;
        }
        expect(database.isDisposed, isTrue);
        expect(backend.isConnected, isTrue);
        expect(manager.closeCalls, 0);
        final close = service.close();
        expect(identical(close, service.close()), isTrue);
        await close;
        if (staging != null) expect(await staging!.exists(), isFalse);
      },
    );
  }

  test('SftpModule shares initialization and owns sftp.db', () async {
    final manager = FakeSshSessionManager();
    final backend = FakeSftpBackend();
    final database = SftpDatabase.forTesting(NativeDatabase.memory());
    final module = SftpModule(databaseFactory: () => database);

    await module.register(
      ModuleContext.fromMap(<Type, Object>{
        SshSessionManager: manager,
        SftpBackend: backend,
      }),
    );
    expect(module.state, ModuleState.registered);

    final firstInitialization = module.initialize();
    expect(identical(firstInitialization, module.initialize()), isTrue);
    await firstInitialization;
    expect(module.state, ModuleState.initialized);
    expect(module.service, isA<SftpService>());

    await module.activate();
    expect(module.state, ModuleState.active);
    await module.service.connect('connection-1');
    await module.service.openPath('/srv');
    expect(manager.ensureInitializedCalls, 1);
    expect(
      (await module.service.loadRecentPaths()).map((record) => record.path),
      contains('/srv'),
    );

    await module.deactivate();
    expect(module.state, ModuleState.inactive);

    final firstDispose = module.dispose();
    expect(identical(firstDispose, module.dispose()), isTrue);
    await firstDispose;
    expect(module.state, ModuleState.disposed);
    expect(() => module.database, throwsStateError);
    expect(() => module.service, throwsStateError);
  });

  test('dispose cancels a late initializer and closes its database', () async {
    final manager = FakeSshSessionManager();
    final backend = FakeSftpBackend();
    final database = SftpDatabase.forTesting(NativeDatabase.memory());
    final databaseReady = Completer<SftpDatabase>();
    final module = SftpModule(databaseFactory: () => databaseReady.future);
    await module.register(
      ModuleContext.fromMap(<Type, Object>{
        SshSessionManager: manager,
        SftpBackend: backend,
      }),
    );

    final activation = module.activate();
    final initialization = module.initialize();
    final disposal = module.dispose();
    final activationExpectation = expectLater(activation, throwsStateError);
    final initializationExpectation = expectLater(
      initialization,
      throwsStateError,
    );
    expect(module.state, ModuleState.disposed);
    databaseReady.complete(database);

    await initializationExpectation;
    await activationExpectation;
    await disposal;
    expect(module.state, ModuleState.disposed);
    expect(() => module.service, throwsStateError);
    expect(database.isDisposed, isTrue);
  });
}

final class _DrainingSource implements SftpDocumentSource {
  final readStarted = Completer<void>();
  final closeRequested = Completer<void>();
  final closeGate = Completer<void>();
  bool _sent = false;
  @override
  String get displayName => 'sample.bin';
  @override
  int? get sizeBytes => null;
  @override
  Future<Uint8List?> readChunk() async {
    if (!_sent) {
      _sent = true;
      return Uint8List.fromList([1, 2, 3]);
    }
    readStarted.complete();
    await closeRequested.future;
    return null;
  }

  @override
  Future<void> close() async {
    closeRequested.complete();
    await closeGate.future;
  }
}

final class _DrainingSink implements SftpDocumentSink {
  final closeStarted = Completer<void>();
  final abortRequested = Completer<void>();
  final abortGate = Completer<void>();
  final _finished = Completer<void>();
  @override
  Future<void> addChunk(Uint8List bytes) async {}
  @override
  Future<void> close() async {
    closeStarted.complete();
    await _finished.future;
  }

  @override
  Future<void> abort() async {
    abortRequested.complete();
    await abortGate.future;
    _finished.complete();
  }
}
