import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/sftp_backend_adapters.dart' hide SftpService;
import 'package:ssh_mobile/app/sftp_io_backend_adapters.dart';

import '../test_utils/test_storage_adapter.dart';

import 'sftp_transfer_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'ssh_mobile_sftp_transfer_',
    );
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => tempDir.path,
        );
    await SftpFileCache.clearAll();
  });

  tearDown(() async {
    await SftpFileCache.clearAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // Windows can briefly keep app.log open after async log writes.
      }
    }
  });

  group('SFTP stream transfers', () {
    test(
      'document identity rejects a saved target rebound behind a live session',
      () async {
        final connection = makeConnection('server-1');
        final fixture = TransferFixture(
          connection: connection,
          remote: MemorySftpClient(),
          entry: makeFileEntry(connection, 'up.bin'),
        );
        addTearDown(fixture.dispose);
        await fixture.storage.connectionRepository.addConnection(connection);
        expect(
          fixture.service.targetFingerprint,
          fixture.entry.targetFingerprint,
        );
        await fixture.storage.connectionRepository.updateConnection(
          connection.copyWith(host: 'two.example.com'),
        );
        expect(fixture.service.isConnected, isTrue);
        expect(fixture.service.targetFingerprint, isNull);
      },
    );

    test(
      'cancel during upload metadata I/O prevents remote creation',
      () async {
        final connection = makeConnection('server-1');
        final remote = MemorySftpClient()..setListing('/srv', const []);
        final fixture = TransferFixture(
          connection: connection,
          remote: remote,
          entry: makeFileEntry(connection, 'up.bin'),
        );
        addTearDown(fixture.dispose);
        final local = File('${tempDir.path}/input.bin');
        await local.writeAsBytes([1, 2, 3]);
        final upload = fixture.service.uploadFile(
          localPath: local.path,
          filename: 'up.bin',
        );
        fixture.service.cancelActiveTransfer();
        await expectLater(
          upload,
          throwsA(isA<SftpTransferCancelledException>()),
        );
        expect(remote.files, isEmpty);
        expect(fixture.service.hasActiveTransfer, isFalse);
      },
    );

    test('upload freezes the remote directory before local file I/O', () async {
      final connection = makeConnection('server-1');
      final remote = MemorySftpClient()
        ..setListing('/srv', const [])
        ..setListing('/other', const []);
      final fixture = TransferFixture(
        connection: connection,
        remote: remote,
        entry: makeFileEntry(connection, 'up.bin'),
      );
      addTearDown(fixture.dispose);
      final local = File('${tempDir.path}/input.bin');
      await local.writeAsBytes([1, 2, 3]);
      // Cached navigation completes in microtasks before local filesystem I/O.
      await fixture.storage.connectionRepository.addConnection(connection);
      await fixture.service.openPath('/other');
      await fixture.service.openPath('/srv');
      expect(
        fixture.service.targetFingerprint,
        fixture.entry.targetFingerprint,
      );
      final upload = fixture.service.uploadFile(
        localPath: local.path,
        filename: 'up.bin',
      );
      await fixture.service.openPath('/other');
      expect(fixture.service.currentPath, '/other');
      await upload;
      expect(remote.fileBytes('/srv/up.bin'), [1, 2, 3]);
      expect(remote.files.containsKey('/other/up.bin'), isFalse);
    });

    test('downloadFile streams bounded bytes into a new local file', () async {
      final connection = makeConnection('server-1');
      final bytes = Uint8List.fromList(
        List<int>.generate((256 * 1024) + 11, (index) => index % 251),
      );
      final fixture = TransferFixture(
        connection: connection,
        remote: MemorySftpClient()..setFile('/srv/demo.bin', bytes),
        entry: makeFileEntry(connection, 'demo.bin', size: bytes.length),
      );
      addTearDown(fixture.dispose);
      final localPath = '${tempDir.path}/nested/out/demo.bin';

      await fixture.service.downloadFile(
        fixture.entry,
        localPath: localPath,
        maxBytes: bytes.length + 1,
      );

      expect(await File(localPath).readAsBytes(), bytes);
      expect(fixture.service.state, SftpConnectionState.connected);
      expect(fixture.service.hasActiveTransfer, isFalse);
      expect(fixture.remote.openReadPaths, contains('/srv/demo.bin'));
      expect(fixture.remote.closedReadPaths, contains('/srv/demo.bin'));
    });

    test('downloadFile rejects directory entries explicitly', () async {
      final connection = makeConnection('server-1');
      final fixture = TransferFixture(
        connection: connection,
        remote: MemorySftpClient(),
        entry: makeDirEntry(connection, 'folder'),
      );
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.service.downloadFile(
          fixture.entry,
          localPath: '${tempDir.path}/out.bin',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Directories cannot be downloaded'),
          ),
        ),
      );
    });

    test(
      'downloadFile and downloadBytes fail on a missing SFTP session',
      () async {
        final storage = TestStorageAdapter();
        final service = SftpService(
          connectionRepository: storage.connectionRepository,
          credentialRepository: storage.credentialRepository,
          hostKeyRepository: storage.hostKeyRepository,
        );
        addTearDown(() {
          service.dispose();
          storage.dispose();
        });
        await service.connect('missing-connection');

        final entry = makeFileEntry(
          makeConnection('missing-connection'),
          'x.bin',
        );
        await expectLater(
          service.downloadFile(entry, localPath: '${tempDir.path}/x.bin'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          service.downloadBytes(entry),
          throwsA(isA<StateError>()),
        );
        expect(service.state, SftpConnectionState.error);
      },
    );

    test(
      'downloadFile removes the partial local file when the read fails',
      () async {
        final connection = makeConnection('server-1');
        final bytes = Uint8List.fromList(List<int>.filled(4096, 3));
        final remote = MemorySftpClient()..setFile('/srv/demo.bin', bytes);
        remote.readError = StateError('Permission denied');
        final fixture = TransferFixture(
          connection: connection,
          remote: remote,
          entry: makeFileEntry(connection, 'demo.bin', size: bytes.length),
        );
        addTearDown(fixture.dispose);
        final localPath = '${tempDir.path}/partial.bin';

        await expectLater(
          fixture.service.downloadFile(
            fixture.entry,
            localPath: localPath,
            maxBytes: 8192,
          ),
          throwsA(isA<StateError>()),
        );

        expect(fixture.service.state, SftpConnectionState.error);
        expect(fixture.service.errorMessage, contains('Download failed'));
        expect(File(localPath).existsSync(), isFalse);
        expect(fixture.service.activeTransfer, isNull);
      },
    );

    test(
      'downloadFile cancellation removes the partial file and restores state',
      () async {
        final connection = makeConnection('server-1');
        final bytes = Uint8List.fromList(List<int>.filled(300 * 1024, 7));
        final remote = MemorySftpClient()..setFile('/srv/demo.bin', bytes);
        remote.readGate = Completer<void>();
        final fixture = TransferFixture(
          connection: connection,
          remote: remote,
          entry: makeFileEntry(connection, 'demo.bin', size: bytes.length),
        );
        addTearDown(fixture.dispose);
        final localPath = '${tempDir.path}/cancelled.bin';

        final operation = fixture.service.downloadFile(
          fixture.entry,
          localPath: localPath,
          maxBytes: bytes.length + 1,
        );
        await remote.readStarted.future;
        fixture.service.cancelActiveTransfer();
        expect(fixture.service.activeTransfer?.isCancelled, isTrue);
        remote.readGate!.complete();

        await expectLater(
          operation,
          throwsA(isA<SftpTransferCancelledException>()),
        );
        expect(fixture.service.state, SftpConnectionState.connected);
        expect(File(localPath).existsSync(), isFalse);
        expect(fixture.service.activeTransfer, isNull);
      },
    );

    test(
      'misbehaving remote overrun is rejected during stream download',
      () async {
        final connection = makeConnection('server-1');
        final remote = MemorySftpClient()
          ..setFile('/srv/oversize.bin', Uint8List(4096))
          ..ignoreReadLength = true;
        final fixture = TransferFixture(
          connection: connection,
          remote: remote,
          entry: makeFileEntry(connection, 'oversize.bin', size: 16),
        );
        addTearDown(fixture.dispose);
        final localPath = '${tempDir.path}/oversize.bin';

        await expectLater(
          fixture.service.downloadFile(
            fixture.entry,
            localPath: localPath,
            maxBytes: 1024,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Download exceeds max size'),
            ),
          ),
        );

        expect(File(localPath).existsSync(), isFalse);
      },
    );

    test(
      'downloadBytes with updateState reports connected after success',
      () async {
        final connection = makeConnection('server-1');
        final bytes = Uint8List.fromList('payload'.codeUnits);
        final fixture = TransferFixture(
          connection: connection,
          remote: MemorySftpClient()..setFile('/srv/demo.bin', bytes),
          entry: makeFileEntry(connection, 'demo.bin', size: bytes.length),
        );
        addTearDown(fixture.dispose);

        final result = await fixture.service.downloadBytes(
          fixture.entry,
          updateState: true,
          bypassCache: true,
        );

        expect(result, bytes);
        expect(fixture.service.state, SftpConnectionState.connected);
      },
    );

    test(
      'downloadBytes with updateState reports error after failure',
      () async {
        final connection = makeConnection('server-1');
        final bytes = Uint8List.fromList('payload'.codeUnits);
        final remote = MemorySftpClient()..setFile('/srv/demo.bin', bytes);
        remote.openError = StateError('No such file');
        final fixture = TransferFixture(
          connection: connection,
          remote: remote,
          entry: makeFileEntry(connection, 'demo.bin', size: bytes.length),
        );
        addTearDown(fixture.dispose);

        await expectLater(
          fixture.service.downloadBytes(
            fixture.entry,
            updateState: true,
            bypassCache: true,
          ),
          throwsA(isA<StateError>()),
        );
        expect(fixture.service.state, SftpConnectionState.error);
        expect(fixture.service.errorMessage, contains('Download failed'));
      },
    );

    test(
      'uploadFile streams a local file and refreshes the directory',
      () async {
        final connection = makeConnection('server-1');
        final bytes = Uint8List.fromList(
          List<int>.generate((256 * 1024) + 9, (index) => index % 199),
        );
        final remote = MemorySftpClient()
          ..setListing('/srv', [makeRemoteFile('up.bin', size: bytes.length)]);
        final fixture = TransferFixture(
          connection: connection,
          remote: remote,
          entry: makeFileEntry(connection, 'up.bin', size: bytes.length),
          currentPath: '/srv',
        );
        addTearDown(fixture.dispose);
        final localPath = '${tempDir.path}/source.bin';
        await File(localPath).writeAsBytes(bytes);

        await fixture.service.uploadFile(
          localPath: localPath,
          filename: 'up.bin',
        );

        expect(remote.fileBytes('/srv/up.bin'), bytes);
        expect(fixture.service.state, SftpConnectionState.connected);
        expect(fixture.service.entries.single.name, 'up.bin');
        expect(remote.closedWritePaths, contains('/srv/up.bin'));
        expect(remote.listCount('/srv'), 1);
      },
    );

    test('uploadFile fails fast when the local file is missing', () async {
      final connection = makeConnection('server-1');
      final fixture = TransferFixture(
        connection: connection,
        remote: MemorySftpClient(),
        entry: makeFileEntry(connection, 'up.bin'),
      );
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.service.uploadFile(
          localPath: '${tempDir.path}/missing.bin',
          filename: 'up.bin',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(fixture.service.state, SftpConnectionState.connected);
      expect(fixture.service.activeTransfer, isNull);
    });

    test('uploadFile cancellation removes the remote partial file', () async {
      final connection = makeConnection('server-1');
      final bytes = Uint8List.fromList(List<int>.filled(300 * 1024, 4));
      final remote = MemorySftpClient()..setListing('/srv', const []);
      remote.writeGate = Completer<void>();
      final fixture = TransferFixture(
        connection: connection,
        remote: remote,
        entry: makeFileEntry(connection, 'up.bin', size: bytes.length),
        currentPath: '/srv',
      );
      addTearDown(fixture.dispose);
      final localPath = '${tempDir.path}/source.bin';
      await File(localPath).writeAsBytes(bytes);

      final operation = fixture.service.uploadFile(
        localPath: localPath,
        filename: 'up.bin',
      );
      await remote.writeStarted.future;
      fixture.service.cancelActiveTransfer();
      remote.writeGate!.complete();

      await expectLater(
        operation,
        throwsA(isA<SftpTransferCancelledException>()),
      );
      expect(fixture.service.state, SftpConnectionState.connected);
      expect(remote.removedPaths, contains('/srv/up.bin'));
      expect(fixture.service.activeTransfer, isNull);
    });

    test(
      'uploadFile remote failure moves the service to error state',
      () async {
        final connection = makeConnection('server-1');
        final bytes = Uint8List.fromList('data'.codeUnits);
        final remote = MemorySftpClient()..setListing('/srv', const []);
        remote.openError = StateError('No space left on device');
        final fixture = TransferFixture(
          connection: connection,
          remote: remote,
          entry: makeFileEntry(connection, 'up.bin', size: bytes.length),
          currentPath: '/srv',
        );
        addTearDown(fixture.dispose);
        final localPath = '${tempDir.path}/source.bin';
        await File(localPath).writeAsBytes(bytes);

        await expectLater(
          fixture.service.uploadFile(localPath: localPath, filename: 'up.bin'),
          throwsA(isA<StateError>()),
        );

        expect(fixture.service.state, SftpConnectionState.error);
        expect(fixture.service.errorMessage, contains('Upload failed'));
        expect(fixture.service.activeTransfer, isNull);
      },
    );

    test('uploadBytes without a session is a safe no-op', () async {
      final storage = TestStorageAdapter();
      final service = SftpService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
      );
      addTearDown(() {
        service.dispose();
        storage.dispose();
      });

      await service.uploadBytes(
        filename: 'x.txt',
        bytes: Uint8List.fromList('x'.codeUnits),
      );

      expect(service.state, SftpConnectionState.disconnected);
    });

    test(
      'uploadBytes remote failure moves the service to error state',
      () async {
        final connection = makeConnection('server-1');
        final remote = MemorySftpClient()..setListing('/srv', const []);
        remote.openError = StateError('Permission denied');
        final fixture = TransferFixture(
          connection: connection,
          remote: remote,
          entry: makeFileEntry(connection, 'up.txt'),
        );
        addTearDown(fixture.dispose);

        await expectLater(
          fixture.service.uploadBytes(
            filename: 'up.txt',
            bytes: Uint8List.fromList('data'.codeUnits),
          ),
          throwsA(isA<StateError>()),
        );

        expect(fixture.service.state, SftpConnectionState.error);
        expect(fixture.service.errorMessage, contains('Upload failed'));
      },
    );
  });
}
