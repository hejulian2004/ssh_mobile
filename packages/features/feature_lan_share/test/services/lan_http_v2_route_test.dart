import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  test(
    'authenticated content routes preserve E2EE and sender identity',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List.fromList(List.filled(32, 1)),
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
        storageService: LanStorageService(),
      );
      addTearDown(() async {
        await service.close();
        await store.dispose();
      });
      Future<_Response> dispatch(
        String path, {
        Object? payload,
        bool encrypted = true,
        String method = 'POST',
        List<int>? bytes,
      }) async {
        final plain = utf8.encode(jsonEncode(payload));
        final body =
            bytes ??
            (path == '/api/lan/meta' && encrypted
                ? await security.encryptE2EFor(
                    Uint8List.fromList(plain),
                    await security.getStaticX25519PublicKeyBytes(),
                  )
                : plain);
        final request = _BodyRequest(path, method, body);
        request.headers.set('x-device-id', 'device-b');
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer valid-inbound-token',
        );
        if (encrypted) request.headers.set('x-e2e-pubkey', '1');
        service.handleHttpRequest(request);
        await request.response.closed.future.timeout(
          const Duration(seconds: 2),
        );
        return request.response;
      }

      final message = <String, Object?>{
        'id': 'text-1',
        'senderId': 'device-b',
        'receiverId': 'device-a',
        'senderAlias': 'B',
        'payloadType': 'text',
        'textContent': 'hello',
        'localPath': 'untrusted',
        'fileName': 'untrusted',
      };
      final incoming = service.incomingMessageStream.first;
      expect(
        (await dispatch('/api/lan/meta', payload: message)).statusCode,
        200,
      );
      final received = await incoming;
      expect(received.textContent, 'hello');
      expect(received.senderId, 'device-b');
      expect(received.localPath, isNull);
      expect(received.fileName, isNull);
      expect(received.isIncoming, isTrue);
      expect(received.status, LanTransferStatus.completed);
      expect(
        (await dispatch(
          '/api/lan/meta',
          payload: message,
          encrypted: false,
        )).statusCode,
        426,
      );
      expect(
        (await dispatch('/api/lan/meta', bytes: [1, 2, 3])).statusCode,
        400,
      );
      expect((await dispatch('/api/lan/meta', payload: [])).statusCode, 400);
      expect(
        (await dispatch(
          '/api/lan/meta',
          payload: {...message, 'payloadType': 'file'},
        )).statusCode,
        426,
      );
      expect(
        (await dispatch(
          '/api/lan/meta',
          payload: {...message, 'senderId': 4},
        )).statusCode,
        400,
      );
      expect(
        (await dispatch(
          '/api/lan/meta',
          payload: {...message, 'senderId': 'imposter'},
        )).statusCode,
        400,
      );
      expect(
        (await dispatch(
          '/api/lan/meta',
          payload: {'payloadType': 'text', 'textContent': 'x' * (1024 * 1024)},
        )).statusCode,
        413,
      );
      final recalled = service.recalledMessageIdStream.first;
      expect(
        (await dispatch(
          '/api/lan/recall',
          payload: {'messageId': ' text-1 '},
        )).statusCode,
        200,
      );
      expect((await recalled).messageId, 'text-1');
      expect(
        (await dispatch(
          '/api/lan/recall',
          payload: {'messageId': 1},
        )).statusCode,
        400,
      );
      expect(
        (await dispatch(
          '/api/lan/check_pair?deviceId=device-b',
          method: 'GET',
        )).statusCode,
        200,
      );
      expect(
        (await dispatch(
          '/api/lan/check_pair?deviceId=imposter',
          method: 'GET',
        )).statusCode,
        403,
      );
      expect((await dispatch('/api/lan/ws', method: 'GET')).statusCode, 400);
      for (final (id, expected) in [('imposter', 403), ('device-b', 500)]) {
        final request = _BodyRequest('/api/lan/ws?deviceId=$id', 'GET', []);
        request.headers.set('x-device-id', 'device-b');
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer valid-inbound-token',
        );
        request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
        request.headers.set(HttpHeaders.upgradeHeader, 'websocket');
        request.headers.set('sec-websocket-version', '13');
        request.headers.set('sec-websocket-key', 'dGhlIHNhbXBsZSBub25jZQ==');
        service.handleHttpRequest(request);
        await request.response.closed.future;
        expect(request.response.statusCode, expected);
      }
      // A malformed numeric announcement is normalized without exposing exception details.
      final invalid = await dispatch(
        '/api/lan/announce',
        payload: {'port': 'bad'},
      );
      expect(invalid.statusCode, 500);
      expect(
        jsonDecode(invalid.body.toString())['message'],
        'LAN request failed.',
      );
      await service.close();
      expect(
        (await dispatch(
          '/api/lan/recall',
          payload: {'messageId': 'text-1'},
        )).statusCode,
        503,
      );
    },
  );

  test(
    'announcements derive peer categories and require a valid source',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final service = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
        ),
        storageService: LanStorageService(),
      );
      addTearDown(service.close);
      var source = 0;
      for (final (os, kind) in [
        ('android', LanDeviceType.mobile),
        ('web', LanDeviceType.webBrowser),
        ('windows', LanDeviceType.desktop),
      ]) {
        final peerFuture = service.announcedPeerStream.first;
        final request = _BodyRequest(
          '/api/lan/announce',
          'POST',
          utf8.encode(
            jsonEncode({
              'id': 'device-b',
              'alias': 'B',
              'os': os,
              'port': 55000,
            }),
          ),
          address: InternetAddress('::ffff:127.0.0.${++source}'),
        );
        service.handleHttpRequest(request);
        await request.response.closed.future;
        expect(request.response.statusCode, 200);
        final peer = await peerFuture;
        expect(peer.controlPort, 55000);
        expect(peer.ip, '127.0.0.$source');
        expect(peer.deviceType, kind);
      }
      final request = _BodyRequest(
        '/api/lan/announce',
        'POST',
        utf8.encode('{}'),
      );
      service.handleHttpRequest(request);
      await request.response.closed.future;
      expect(request.response.statusCode, 400);
    },
  );
  test('the legacy native HTTP upload route is not exposed in V2', () async {
    // Keep this contract test independent of the Flutter test runner's HTTP
    // interception and of a second TLS/native runtime. A live loopback test
    // cannot distinguish a missing route from a runner-owned HTTP override.
    final sourceFile = _sourceFile();
    expect(sourceFile.existsSync(), isTrue, reason: sourceFile.path);
    final source = await sourceFile.readAsString();

    expect(
      source,
      isNot(matches(RegExp(r'''path\s*==\s*['"]\/api\/lan\/upload['"]'''))),
    );
    for (final removedSymbol in <String>[
      '_handleUploadRequest',
      'LanPendingUpload',
      '_pendingUploads',
      '_activeUploads',
    ]) {
      expect(source, isNot(contains(removedSymbol)), reason: removedSymbol);
    }
  });

  test(
    'the in-process route dispatcher returns 404 for legacy upload',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final service = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
        ),
        storageService: LanStorageService(),
      );
      addTearDown(service.close);

      final request = _Request();
      service.handleHttpRequest(request);
      await request.response.closed.future.timeout(const Duration(seconds: 1));

      expect(request.response.statusCode, HttpStatus.notFound);
    },
  );

  test(
    '/api/lan/capabilities response includes protocolVersion == 2',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      );
      final service = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: security,
        storageService: LanStorageService(),
        networkIdentityPublicKeyProvider: () async => Uint8List(32),
        nativeTransferPortProvider: () => 43123,
      );
      addTearDown(() async {
        await service.close();
        await store.dispose();
      });

      final trust = LanPeerTrustRecord(
        deviceId: 'device-b',
        certificateFingerprint:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        inboundAccessToken: 'valid-inbound-token',
        outboundAccessToken: 'valid-outbound-token',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      );
      await store.save(trust);

      final request = _CapabilitiesRequest();
      service.handleHttpRequest(request);
      await request.response.closed.future.timeout(const Duration(seconds: 1));

      expect(request.response.statusCode, HttpStatus.ok);
      final decoded =
          jsonDecode(request.response.body.toString()) as Map<String, dynamic>;
      expect(decoded['protocolVersion'], LanControlProtocol.version);
      expect(decoded['protocolVersion'], 2);
      expect(decoded['quicFileTransfer'], isTrue);
      expect(decoded['quicPort'], 43123);
    },
  );
}

final class _BodyRequest extends Stream<Uint8List> implements HttpRequest {
  _BodyRequest(String path, this.method, this.body, {this.address})
    : uri = Uri.parse(path);
  final List<int> body;
  final InternetAddress? address;
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
  HttpConnectionInfo? get connectionInfo =>
      address == null ? null : _ConnectionInfo(address!);
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<Uint8List>.value(Uint8List.fromList(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ConnectionInfo extends Fake implements HttpConnectionInfo {
  _ConnectionInfo(this.remoteAddress);
  @override
  final InternetAddress remoteAddress;
}

File _sourceFile() {
  const relativePath =
      'lib/src/services/lan_share/lan_transfer_http_routes.dart';
  final fromCurrentDirectory = File(relativePath);
  if (fromCurrentDirectory.existsSync()) return fromCurrentDirectory;

  final fromRepositoryRoot = File(
    'packages/features/feature_lan_share/$relativePath',
  );
  if (fromRepositoryRoot.existsSync()) return fromRepositoryRoot;

  // Aggregate test commands may execute from the repository root rather than
  // this package. Platform.script is a final fallback for runners that use a
  // package-local working directory without the package-relative path.
  final testFile = File.fromUri(Platform.script);
  final packageRoot = testFile.parent.parent.parent;
  return File.fromUri(packageRoot.uri.resolve(relativePath));
}

final class _Request extends Fake implements HttpRequest {
  final _Response _response = _Response();
  final _Headers _headers = _Headers();

  @override
  String get method => 'POST';

  @override
  Uri get uri => Uri.parse('/api/lan/upload');

  @override
  HttpHeaders get headers => _headers;

  @override
  _Response get response => _response;
}

final class _Response extends Fake implements HttpResponse {
  final _Headers _headers = _Headers();
  final StringBuffer body = StringBuffer();
  final closed = Completer<void>();

  @override
  int statusCode = HttpStatus.ok;

  @override
  HttpHeaders get headers => _headers;

  @override
  void write(Object? object) => body.write(object);

  @override
  Future<HttpResponse> close([Object? data]) async {
    if (data != null) body.write(data);
    if (!closed.isCompleted) closed.complete();
    return this;
  }
}

final class _CapabilitiesRequest extends Fake implements HttpRequest {
  final _Response _response = _Response();
  final _Headers _headers = _Headers();

  _CapabilitiesRequest() {
    _headers.set('x-device-id', 'device-b');
    _headers.set(HttpHeaders.authorizationHeader, 'Bearer valid-inbound-token');
  }

  @override
  String get method => 'GET';

  @override
  Uri get uri => Uri.parse('/api/lan/capabilities');

  @override
  HttpHeaders get headers => _headers;

  @override
  _Response get response => _response;
}

final class _Headers implements HttpHeaders {
  final Map<String, String> _values = {};

  @override
  DateTime? date;

  @override
  DateTime? expires;

  @override
  DateTime? ifModifiedSince;

  @override
  String? host;

  @override
  int? port;

  @override
  ContentType? contentType;

  @override
  int contentLength = -1;

  @override
  bool persistentConnection = true;

  @override
  bool chunkedTransferEncoding = false;

  @override
  List<String>? operator [](String name) {
    final value = _values[name.toLowerCase()];
    return value == null ? null : [value];
  }

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  void remove(String name, Object value) {
    _values.remove(name.toLowerCase());
  }

  @override
  void removeAll(String name) {
    _values.remove(name.toLowerCase());
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach((k, v) => action(k, [v]));
  }

  @override
  void noFolding(String name) {}

  @override
  void clear() {
    _values.clear();
  }
}
