import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('lan-document-stream-');
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('send starts only after a complete bounded copy', () async {
    final harness = await _SendHarness.open(sandbox);
    addTearDown(harness.close);
    final payload = Uint8List.fromList(
      List<int>.generate(20 * 1024 + 40, (index) => index % 199),
    );

    final result = await harness.viewModel.sendDocument(
      peerId: 'peer-a',
      source: _ChunkSource(payload, displayName: 'photo.png', pieceBytes: 1000),
      maxBytes: LanDocumentLimits.maxSendBytes,
    );

    expect(result, isA<NetworkFailure<TransferSession>>());
    expect(harness.policy.calls, 1);
    expect(harness.policy.bytesAtSend, payload);
    expect(harness.facade.transferCalls, 0);
    final staged = sandbox.listSync().whereType<File>().single;
    expect(staged.uri.pathSegments.last, 'photo.png');
    expect(await staged.readAsBytes(), payload);
  });

  test('a failed copy deletes the partial spill and does not send', () async {
    final harness = await _SendHarness.open(sandbox);
    addTearDown(harness.close);
    final source = _ChunkSource(
      Uint8List.fromList(List<int>.filled(300, 3)),
      displayName: 'clip.mp4',
      pieceBytes: 50,
      onRead: (index) {
        if (index == 2) throw StateError('read failed');
      },
    );

    final result = await harness.viewModel.sendDocument(
      peerId: 'peer-a',
      source: source,
      maxBytes: 1000,
    );

    expect(result, isA<NetworkFailure<TransferSession>>());
    expect(
      (result as NetworkFailure<TransferSession>).error.code,
      NetworkErrorCode.ioError,
    );
    expect(harness.policy.calls, 0);
    expect(harness.facade.transferCalls, 0);
    expect(sandbox.listSync(), isEmpty);
  });

  test('an oversized document fails closed before send', () async {
    final harness = await _SendHarness.open(sandbox);
    addTearDown(harness.close);
    final source = _ChunkSource(
      Uint8List(0),
      displayName: 'big.bin',
      pieceBytes: 1,
      sizeBytes: 32,
    );

    final result = await harness.viewModel.sendDocument(
      peerId: 'peer-a',
      source: source,
      maxBytes: 16,
    );

    expect(result, isA<NetworkFailure<TransferSession>>());
    expect(
      (result as NetworkFailure<TransferSession>).error.code,
      NetworkErrorCode.resourceLimit,
    );
    expect(source.readCount, 0);
    expect(harness.policy.calls, 0);
    expect(sandbox.listSync(), isEmpty);

    final streaming = _ChunkSource(
      Uint8List.fromList(List<int>.filled(40, 9)),
      displayName: 'stream.bin',
      pieceBytes: 10,
    );
    final streamed = await harness.viewModel.sendDocument(
      peerId: 'peer-a',
      source: streaming,
      maxBytes: 25,
    );
    expect(
      (streamed as NetworkFailure<TransferSession>).error.code,
      NetworkErrorCode.resourceLimit,
    );
    expect(harness.policy.calls, 0);
    expect(sandbox.listSync(), isEmpty);
  });

  test('sandbox export writes every chunk and fails closed', () async {
    final harness = await _SendHarness.open(sandbox);
    addTearDown(harness.close);
    final payload = Uint8List.fromList(
      List<int>.generate(20 * 1024 + 25, (index) => index % 87),
    );
    final received = File(
      '${sandbox.path}${Platform.pathSeparator}received.bin',
    );
    await received.writeAsBytes(payload);

    final sink = _CollectingSink();
    await harness.viewModel.exportSandboxToDocument(
      sandboxPath: received.path,
      sink: sink,
    );
    expect(sink.chunks.length, greaterThan(1));
    expect(sink.bytes, payload);
    expect(sink.closed, isTrue);
    expect(await received.readAsBytes(), payload);

    final failing = _CollectingSink(failOnChunk: 1);
    await expectLater(
      harness.viewModel.exportSandboxToDocument(
        sandboxPath: received.path,
        sink: failing,
      ),
      throwsA(isA<LanDocumentTransferException>()),
    );
    expect(failing.closed, isFalse);
    expect(failing.chunks, isNotEmpty);
    expect(await received.exists(), isTrue);

    final outside = File(
      '${sandbox.parent.path}${Platform.pathSeparator}outside.bin',
    );
    await outside.writeAsBytes(const [1, 2, 3]);
    addTearDown(() async {
      if (await outside.exists()) await outside.delete();
    });
    final outsideSink = _CollectingSink();
    await expectLater(
      harness.viewModel.exportSandboxToDocument(
        sandboxPath: outside.path,
        sink: outsideSink,
      ),
      throwsA(isA<LanDocumentTransferException>()),
    );
    expect(outsideSink.aborted, isTrue);
  });

  test('directory send is still rejected', () async {
    final facade = _IdleFacade();
    final coordinator = LanNativeTransferCoordinator(
      transferService: FakeLanTransferService(),
      networkFacade: facade,
      policyPort: _RecordingPolicy(sandbox),
      storageService: LanStorageService(
        sandboxDirectoryProvider: () async => sandbox,
        freeDiskSpaceBytesProvider: () async => 1024 * 1024 * 1024 * 1024,
      ),
    );
    addTearDown(() async {
      await coordinator.dispose();
      await facade.close();
    });

    final result = await coordinator.sendFile(
      peerId: 'peer-a',
      transferId: 'tx-directory',
      filePath: sandbox.path,
    );

    expect(result, isA<NetworkFailure<TransferSession>>());
    expect(
      (result as NetworkFailure<TransferSession>).error.code,
      isIn(<NetworkErrorCode>[
        NetworkErrorCode.ioError,
        NetworkErrorCode.invalidArgument,
      ]),
    );
    expect(facade.transferCalls, 0);
  });

  test(
    'shutdown closes a source while native document copying is pending',
    () async {
      final harness = await _SendHarness.open(sandbox);
      addTearDown(harness.close);
      final source = _PendingSource();
      addTearDown(source.close);
      final sending = harness.viewModel.sendDocument(
        peerId: 'peer-a',
        source: source,
      );
      await source.started.future;
      await harness.viewModel.shutdown();
      expect(source.closed, isTrue);
      expect(
        (await sending as NetworkFailure).error.code,
        NetworkErrorCode.cancelled,
      );
      expect(harness.policy.calls, 0);
      expect(sandbox.listSync(), isEmpty);
    },
  );

  test(
    'shutdown aborts a sink while native document writing is pending',
    () async {
      final harness = await _SendHarness.open(sandbox);
      addTearDown(harness.close);
      final source = File('${sandbox.path}${Platform.pathSeparator}source.bin');
      await source.writeAsBytes([1]);
      final sink = _PendingSink();
      addTearDown(sink.abort);
      final exporting = harness.viewModel
          .exportSandboxToDocument(sandboxPath: source.path, sink: sink)
          .then<Object?>((_) => null, onError: (Object error) => error);
      await sink.started.future;
      await harness.viewModel.shutdown();
      expect(sink.aborted, isTrue);
      expect(
        await exporting,
        isA<LanDocumentTransferException>().having(
          (error) => error.code,
          'code',
          NetworkErrorCode.cancelled,
        ),
      );
    },
  );

  test('an incoming peer localPath is still ignored', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = LanPeerTrustStore();
    final security = LanSecurityService(
      appOwnedX25519PrivateSeed: Uint8List.fromList(List<int>.filled(32, 1)),
      peerTrustStore: store,
    );
    await store.save(
      LanPeerTrustRecord(
        deviceId: 'device-b',
        certificateFingerprint: '0' * 64,
        inboundAccessToken: 'valid-inbound-token',
        outboundAccessToken: 'outbound',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      ),
    );
    final service = LanTransferService(
      currentDeviceId: 'device-a',
      securityService: security,
      storageService: LanStorageService(
        sandboxDirectoryProvider: () async => sandbox,
        freeDiskSpaceBytesProvider: () async => 1024 * 1024 * 1024 * 1024,
      ),
    );
    addTearDown(() async {
      await service.close();
      await store.dispose();
    });

    final plain = utf8.encode(
      jsonEncode(<String, Object?>{
        'id': 'text-1',
        'senderId': 'device-b',
        'receiverId': 'device-a',
        'senderAlias': 'B',
        'payloadType': 'text',
        'textContent': 'hello',
        'localPath': '/tmp/peer-supplied',
        'fileName': 'secret.txt',
      }),
    );
    final body = await security.encryptE2EFor(
      Uint8List.fromList(plain),
      await security.getStaticX25519PublicKeyBytes(),
    );
    final request = _BodyRequest('/api/lan/meta', 'POST', body);
    request.headers.set('x-device-id', 'device-b');
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer valid-inbound-token',
    );
    request.headers.set('x-e2e-pubkey', '1');
    final incoming = service.incomingMessageStream.first;
    service.handleHttpRequest(request);
    await request.response.closed.future.timeout(const Duration(seconds: 2));

    expect(request.response.statusCode, 200);
    final received = await incoming;
    expect(received.localPath, isNull);
    expect(received.fileName, isNull);
    expect(received.textContent, 'hello');
    expect(received.isIncoming, isTrue);
  });
}

final class _PendingSource implements LanDocumentSource {
  final started = Completer<void>();
  final stopped = Completer<Uint8List?>();
  var closed = false;
  @override
  String get displayName => 'pending.bin';
  @override
  int? get sizeBytes => null;
  @override
  Future<Uint8List?> readChunk() {
    started.complete();
    return stopped.future;
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!stopped.isCompleted) stopped.complete(null);
  }
}

final class _PendingSink implements LanDocumentSink {
  final started = Completer<void>();
  final stopped = Completer<void>();
  var aborted = false;
  @override
  Future<void> addChunk(Uint8List bytes) {
    started.complete();
    return stopped.future;
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> abort() async {
    aborted = true;
    if (!stopped.isCompleted) stopped.complete();
  }
}

final class _SendHarness {
  _SendHarness(this.viewModel, this.policy, this.facade, this.coordinator);

  final LanShareViewModel viewModel;
  final _RecordingPolicy policy;
  final _IdleFacade facade;
  final LanNativeTransferCoordinator coordinator;

  static Future<_SendHarness> open(Directory sandbox) async {
    final settings = FakeLanShareSettings();
    final facade = _IdleFacade();
    final policy = _RecordingPolicy(sandbox);
    final transfer = FakeLanTransferService();
    final coordinator = LanNativeTransferCoordinator(
      transferService: transfer,
      networkFacade: facade,
      policyPort: policy,
      storageService: LanStorageService(
        sandboxDirectoryProvider: () async => sandbox,
        freeDiskSpaceBytesProvider: () async => 1024 * 1024 * 1024 * 1024,
      ),
    );
    final viewModel = LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: FakeLanSecurityService(),
      storageService: LanStorageService(
        sandboxDirectoryProvider: () async => sandbox,
        freeDiskSpaceBytesProvider: () async => 1024 * 1024 * 1024 * 1024,
      ),
      transferService: transfer,
      nativeTransferCoordinator: coordinator,
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
    return _SendHarness(viewModel, policy, facade, coordinator);
  }

  Future<void> close() async {
    viewModel.dispose();
    await coordinator.dispose();
    await facade.close();
  }
}

final class _RecordingPolicy extends Fake implements LanNativePeerPolicyPort {
  _RecordingPolicy(this.sandbox);

  final Directory sandbox;
  int calls = 0;
  Uint8List? bytesAtSend;

  @override
  Future<NetworkResult<LanPeerPolicySnapshot>> getPeerPolicy(
    String peerId,
  ) async {
    calls += 1;
    final files = sandbox.listSync().whereType<File>().toList();
    bytesAtSend = await files.single.readAsBytes();
    return const NetworkSuccess<LanPeerPolicySnapshot>(LanPeerPolicySnapshot());
  }
}

final class _IdleFacade extends Fake implements NetworkFacade {
  final StreamController<SdkEvent> _events =
      StreamController<SdkEvent>.broadcast();
  int transferCalls = 0;

  @override
  Stream<SdkEvent> get events => _events.stream;

  @override
  Future<SdkResult<SdkTransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  }) async {
    transferCalls += 1;
    throw StateError('native send was not expected');
  }

  Future<void> close() => _events.close();
}

final class _ChunkSource implements LanDocumentSource {
  _ChunkSource(
    this.payload, {
    required this.displayName,
    required this.pieceBytes,
    this.sizeBytes,
    this.onRead,
  });

  final Uint8List payload;
  @override
  final String displayName;
  final int pieceBytes;
  @override
  final int? sizeBytes;
  final void Function(int index)? onRead;
  int readCount = 0;
  int _offset = 0;

  @override
  Future<Uint8List?> readChunk() async {
    final index = readCount;
    readCount += 1;
    onRead?.call(index);
    if (_offset >= payload.length) return null;
    final end = _offset + pieceBytes;
    final next = end > payload.length ? payload.length : end;
    final chunk = Uint8List.sublistView(payload, _offset, next);
    _offset = next;
    return Uint8List.fromList(chunk);
  }

  @override
  Future<void> close() async {}
}

final class _CollectingSink implements LanDocumentSink {
  _CollectingSink({this.failOnChunk});

  final int? failOnChunk;
  final chunks = <Uint8List>[];
  var closed = false;
  var aborted = false;

  Uint8List get bytes {
    final builder = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> addChunk(Uint8List bytes) async {
    if (failOnChunk != null && chunks.length == failOnChunk) {
      throw StateError('sink failed');
    }
    chunks.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }
}

final class _BodyRequest extends Stream<Uint8List> implements HttpRequest {
  _BodyRequest(String path, this.method, List<int> body)
    : body = Uint8List.fromList(body),
      uri = Uri.parse(path);

  final Uint8List body;

  @override
  final String method;

  @override
  final Uri uri;

  @override
  final _Headers headers = _Headers();

  @override
  final _Response response = _Response();

  @override
  int get contentLength => body.length;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<Uint8List>.value(body).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response extends Fake implements HttpResponse {
  final _Headers _headers = _Headers();
  final closed = Completer<void>();

  @override
  int statusCode = HttpStatus.ok;

  @override
  HttpHeaders get headers => _headers;

  @override
  void write(Object? object) {}

  @override
  Future<HttpResponse> close([Object? data]) async {
    if (!closed.isCompleted) closed.complete();
    return this;
  }
}

final class _Headers extends Fake implements HttpHeaders {
  final Map<String, String> _values = {};

  @override
  ContentType? contentType;

  @override
  int contentLength = -1;

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }
}
