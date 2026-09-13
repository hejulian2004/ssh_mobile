import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  test('client aggregate keeps authentication and lifecycle boundaries', () {
    final sessions = _FakeSessionClient();
    final events = _FakeEvents(sessions.events);
    final realtime = _FakeRealtimeClient();
    final sdk = NetworkSdkClients(
      bootstrap: _FakeBootstrapClient(),
      authenticatedApi: _FakeAuthenticatedApiClient(),
      sessions: sessions,
      realtime: realtime,
      events: events,
    );

    expect(identical(sdk.sessions, sessions), isTrue);
    expect(identical(sdk.events, events), isTrue);
    expect(sdk.bootstrap, isA<BootstrapClient>());
    expect(sdk.authenticatedApi, isA<AuthenticatedApiClient>());
    expect(identical(sdk.realtime, realtime), isTrue);
  });

  test(
    'typed result exposes stable retry policy without transport details',
    () {
      const result = SdkFailure<void>(
        NetworkError(code: NetworkErrorCode.timeout, message: 'safe message'),
      );

      expect(result.error.code.retryable, isTrue);
      expect(result.toString(), isNot(contains('socket')));
    },
  );

  test('bootstrap client keeps enrollment unauthenticated and typed', () async {
    final executor = _FakeExecutor([
      _response(204),
      _response(200, <String, dynamic>{
        'credential': 'credential',
        'expires_at': 200,
        'server_time': 100,
        'protocol_version': 2,
      }),
    ]);
    final client = JsonBootstrapClient(executor: executor);

    final probe = await client.probe(Uri.parse('https://relay.example'));
    final enrollment = await client.enroll(
      Uri.parse('https://relay.example'),
      EnrollmentRequest(
        deviceId: 'device-1',
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        enrollmentToken: 'enrollment-token',
        platform: 'windows',
      ),
    );

    expect(probe, isA<SdkSuccess<BootstrapMetadata>>());
    expect(enrollment, isA<SdkSuccess<DeviceEnrollment>>());
    final request = executor.requests[1];
    expect(request.method, 'POST');
    expect(request.uri.path, '/v2/devices/enroll');
    expect(request.headers.containsKey('authorization'), isFalse);
    final body = jsonDecode(utf8.decode(request.body!)) as Map<String, dynamic>;
    expect(body['device_id'], 'device-1');
    expect(body['protocol_version'], 2);
    expect(body['platform'], 'windows');
  });

  test(
    'authenticated client refreshes a bearer token once after 401',
    () async {
      final executor = _FakeExecutor([
        _response(401),
        _response(200, <String, dynamic>{
          'peers': [
            {'peer_id': 'peer-1', 'display_name': 'Peer 1'},
          ],
        }),
      ]);
      final auth = _FakeAuthSession();
      final client = JsonAuthenticatedApiClient(
        executor: executor,
        authSession: auth,
        routes: AuthenticatedApiRoutes(
          listPeers: Uri.parse('https://control.example/v1/peers'),
          requestConnection: (peerId) =>
              Uri.parse('https://control.example/v1/peers/$peerId/connect'),
        ),
      );

      final result = await client.listPeers();

      expect(result, isA<SdkSuccess<List<PeerDescriptor>>>());
      expect(
        (result as SdkSuccess<List<PeerDescriptor>>).data.single.peerId,
        'peer-1',
      );
      expect(executor.requests[0].headers['authorization'], 'Bearer old-token');
      expect(executor.requests[1].headers['authorization'], 'Bearer new-token');
      expect(auth.refreshCount, 1);
      expect(auth.invalidated, isFalse);
    },
  );

  test(
    'authenticated client does not issue a request without a token',
    () async {
      final executor = _FakeExecutor(const <SdkResponse>[]);
      final auth = _FakeAuthSession()..token = null;
      final client = JsonAuthenticatedApiClient(
        executor: executor,
        authSession: auth,
        routes: AuthenticatedApiRoutes(
          listPeers: Uri.parse('https://control.example/v1/peers'),
          requestConnection: (peerId) =>
              Uri.parse('https://control.example/$peerId'),
        ),
      );

      final result = await client.listPeers();

      expect(result, isA<SdkFailure<List<PeerDescriptor>>>());
      expect(
        (result as SdkFailure<List<PeerDescriptor>>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(executor.requests, isEmpty);
    },
  );

  test('authenticated client maps token read failure to SdkFailure', () async {
    final executor = _FakeExecutor(const <SdkResponse>[]);
    final auth = _FakeAuthSession()
      ..readTokenError = StateError('secure storage unavailable');
    final client = JsonAuthenticatedApiClient(
      executor: executor,
      authSession: auth,
      routes: AuthenticatedApiRoutes(
        listPeers: Uri.parse('https://control.example/v1/peers'),
        requestConnection: (peerId) =>
            Uri.parse('https://control.example/$peerId'),
      ),
    );

    final result = await client.listPeers();

    expect(result, isA<SdkFailure<List<PeerDescriptor>>>());
    expect(
      (result as SdkFailure<List<PeerDescriptor>>).error.code,
      NetworkErrorCode.ioError,
    );
    expect(executor.requests, isEmpty);
  });

  test(
    'authenticated client invalidates on refresh failure and returns authenticationFailed',
    () async {
      final executor = _FakeExecutor([_response(401)]);
      final auth = _FakeAuthSession()
        ..refreshTokenError = StateError('refresh failed');
      final client = JsonAuthenticatedApiClient(
        executor: executor,
        authSession: auth,
        routes: AuthenticatedApiRoutes(
          listPeers: Uri.parse('https://control.example/v1/peers'),
          requestConnection: (peerId) =>
              Uri.parse('https://control.example/$peerId'),
        ),
      );

      final result = await client.listPeers();

      expect(result, isA<SdkFailure<List<PeerDescriptor>>>());
      expect(
        (result as SdkFailure<List<PeerDescriptor>>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
      expect(auth.invalidated, isTrue);
    },
  );

  test(
    'authenticated client maps route resolver failure to SdkFailure',
    () async {
      final executor = _FakeExecutor(const <SdkResponse>[]);
      final auth = _FakeAuthSession();
      final client = JsonAuthenticatedApiClient(
        executor: executor,
        authSession: auth,
        routes: AuthenticatedApiRoutes(
          listPeers: Uri.parse('https://control.example/v1/peers'),
          requestConnection: (peerId) =>
              throw ArgumentError.value(peerId, 'peerId', 'bad route'),
        ),
      );

      final result = await client.requestConnection('peer-1');

      expect(result, isA<SdkFailure<ConnectionTicket>>());
      expect(
        (result as SdkFailure<ConnectionTicket>).error.code,
        NetworkErrorCode.invalidArgument,
      );
      expect(executor.requests, isEmpty);
    },
  );

  test(
    'authenticated client preserves authenticationFailed when invalidate fails',
    () async {
      final executor = _FakeExecutor([_response(401), _response(401)]);
      final auth = _FakeAuthSession()
        ..invalidateError = StateError('invalidate failed');
      final client = JsonAuthenticatedApiClient(
        executor: executor,
        authSession: auth,
        routes: AuthenticatedApiRoutes(
          listPeers: Uri.parse('https://control.example/v1/peers'),
          requestConnection: (peerId) =>
              Uri.parse('https://control.example/$peerId'),
        ),
      );

      final result = await client.listPeers();

      expect(result, isA<SdkFailure<List<PeerDescriptor>>>());
      expect(
        (result as SdkFailure<List<PeerDescriptor>>).error.code,
        NetworkErrorCode.authenticationFailed,
      );
    },
  );

  test('NetworkErrorCode.fromWire resolves credential and identity codes', () {
    expect(NetworkErrorCode.credentialExpired.wireValue, 12);
    expect(NetworkErrorCode.identityConflict.wireValue, 13);
    expect(NetworkErrorCode.fromWire(12), NetworkErrorCode.credentialExpired);
    expect(NetworkErrorCode.fromWire(13), NetworkErrorCode.identityConflict);
    expect(NetworkErrorCode.fromWire(99), NetworkErrorCode.unspecified);
    expect(NetworkErrorCode.credentialExpired.retryable, isFalse);
    expect(NetworkErrorCode.identityConflict.retryable, isFalse);
  });

  test('RetryDisposition mirrors wire values and rejects unknown values', () {
    expect(RetryDisposition.unspecified.wireValue, 0);
    expect(RetryDisposition.noRetry.wireValue, 1);
    expect(RetryDisposition.retryWithBackoff.wireValue, 2);
    expect(RetryDisposition.retryAfter.wireValue, 3);
    expect(RetryDisposition.refreshCredentialThenRetry.wireValue, 4);
    expect(
      RetryDisposition.fromWire(4),
      RetryDisposition.refreshCredentialThenRetry,
    );
    expect(RetryDisposition.fromWire(99), RetryDisposition.unspecified);
  });

  test('NetworkError carries retry fields with safe defaults', () {
    const error = NetworkError(
      code: NetworkErrorCode.timeout,
      message: 'safe message',
    );
    expect(error.retryDisposition, RetryDisposition.unspecified);
    expect(error.retryAfterSeconds, 0);
    expect(error.retryable, isTrue);

    const withRetry = NetworkError(
      code: NetworkErrorCode.credentialExpired,
      message: 'expired',
      retryDisposition: RetryDisposition.refreshCredentialThenRetry,
      retryAfterSeconds: 30,
    );
    expect(
      withRetry.retryDisposition,
      RetryDisposition.refreshCredentialThenRetry,
    );
    expect(withRetry.retryAfterSeconds, 30);
    expect(withRetry.retryable, isTrue);

    const noRetry = NetworkError(
      code: NetworkErrorCode.timeout,
      message: 'no retry',
      retryDisposition: RetryDisposition.noRetry,
    );
    expect(noRetry.retryable, isFalse);
  });

  test(
    'bootstrap client maps relay identity conflict into typed code',
    () async {
      final executor = _FakeExecutor([
        _response(409, <String, dynamic>{
          'code': 13,
          'message':
              'Relay device identity conflicts with an existing enrollment.',
          'operation': 'enroll_relay',
          'peer_id': 'device-1',
        }),
      ]);
      final client = JsonBootstrapClient(executor: executor);
      final result = await client.enroll(
        Uri.parse('https://relay.example'),
        EnrollmentRequest(
          deviceId: 'device-1',
          identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        ),
      );

      expect(result, isA<SdkFailure<DeviceEnrollment>>());
      final error = (result as SdkFailure<DeviceEnrollment>).error;
      expect(error.code, NetworkErrorCode.identityConflict);
      expect(error.retryDisposition, RetryDisposition.unspecified);
      expect(error.retryAfterSeconds, 0);
    },
  );

  test(
    'bootstrap client maps expired relay credential with retry fields',
    () async {
      final executor = _FakeExecutor([
        _response(401, <String, dynamic>{
          'code': 12,
          'message': 'Relay device authentication failed.',
          'operation': 'connect_relay',
          'retry_disposition': 4,
          'retry_after_seconds': 30,
        }),
      ]);
      final client = JsonBootstrapClient(executor: executor);
      final result = await client.enroll(
        Uri.parse('https://relay.example'),
        EnrollmentRequest(
          deviceId: 'device-1',
          identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        ),
      );

      expect(result, isA<SdkFailure<DeviceEnrollment>>());
      final error = (result as SdkFailure<DeviceEnrollment>).error;
      expect(error.code, NetworkErrorCode.credentialExpired);
      expect(
        error.retryDisposition,
        RetryDisposition.refreshCredentialThenRetry,
      );
      expect(error.retryAfterSeconds, 30);
    },
  );

  test('bootstrap client keeps other 401s as authenticationFailed', () async {
    final executor = _FakeExecutor([
      _response(401, <String, dynamic>{
        'code': 2,
        'message': 'Relay enrollment authentication failed.',
      }),
    ]);
    final client = JsonBootstrapClient(executor: executor);
    final result = await client.enroll(
      Uri.parse('https://relay.example'),
      EnrollmentRequest(
        deviceId: 'device-1',
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
    );

    expect(result, isA<SdkFailure<DeviceEnrollment>>());
    final error = (result as SdkFailure<DeviceEnrollment>).error;
    expect(error.code, NetworkErrorCode.authenticationFailed);
    expect(error.retryDisposition, RetryDisposition.unspecified);
    expect(error.retryAfterSeconds, 0);
  });

  test('bootstrap client refresh signs a device refresh request', () async {
    final executor = _FakeExecutor([
      _response(200, <String, dynamic>{
        'credential': 'refreshed-credential',
        'expires_at': 200,
        'server_time': 100,
        'protocol_version': 2,
      }),
    ]);
    final client = JsonBootstrapClient(executor: executor);
    final nonce = _encodedBytes(32, 3);
    final signature = _encodedBytes(64, 5);
    final result = await client.refresh(
      Uri.parse('https://relay.example'),
      RefreshRequest(
        deviceId: 'device-1',
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        timestamp: 1700000000,
        nonce: nonce,
        signature: signature,
      ),
    );

    expect(result, isA<SdkSuccess<DeviceEnrollment>>());
    expect(
      (result as SdkSuccess<DeviceEnrollment>).data.relayCredential,
      'refreshed-credential',
    );
    final request = executor.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/v2/devices/refresh');
    expect(request.headers.containsKey('authorization'), isFalse);
    final body = jsonDecode(utf8.decode(request.body!)) as Map<String, dynamic>;
    expect(body['device_id'], 'device-1');
    expect(body['timestamp'], 1700000000);
    expect(body['nonce'], nonce);
    expect(body['signature'], signature);
  });

  test('bootstrap client rejects malformed refresh proofs locally', () async {
    final executor = _FakeExecutor(const <SdkResponse>[]);
    final client = JsonBootstrapClient(executor: executor);
    final nonce = _encodedBytes(32, 3);
    final signature = _encodedBytes(64, 5);
    final invalidProofs = <RefreshRequest>[
      for (final timestamp in <int>[0, -1, 1 << 63])
        RefreshRequest(
          deviceId: 'device-1',
          identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
          timestamp: timestamp,
          nonce: nonce,
          signature: signature,
        ),
      RefreshRequest(
        deviceId: 'device-1',
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        timestamp: 1700000000,
        nonce: 'not-canonical',
        signature: signature,
      ),
      RefreshRequest(
        deviceId: 'device-1',
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        timestamp: 1700000000,
        nonce: nonce,
        signature: '$signature=',
      ),
    ];

    for (final request in invalidProofs) {
      final result = await client.refresh(
        Uri.parse('https://relay.example'),
        request,
      );

      expect(result, isA<SdkFailure<DeviceEnrollment>>());
      expect(
        (result as SdkFailure<DeviceEnrollment>).error.code,
        NetworkErrorCode.invalidArgument,
      );
    }
    expect(executor.requests, isEmpty);
  });

  test(
    'bootstrap client refresh maps 404 to noRoute re-enroll signal',
    () async {
      final executor = _FakeExecutor([
        _response(404, <String, dynamic>{
          'code': 1,
          'message': 'Relay device is not enrolled; re-enroll with a token.',
          'operation': 'refresh_credential',
          'peer_id': 'device-1',
        }),
      ]);
      final client = JsonBootstrapClient(executor: executor);
      final result = await client.refresh(
        Uri.parse('https://relay.example'),
        RefreshRequest(
          deviceId: 'device-1',
          identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
          timestamp: 1700000000,
          nonce: _encodedBytes(32, 3),
          signature: _encodedBytes(64, 5),
        ),
      );

      expect(result, isA<SdkFailure<DeviceEnrollment>>());
      final error = (result as SdkFailure<DeviceEnrollment>).error;
      expect(error.code, NetworkErrorCode.noRoute);
      expect(error.operation, NetworkOperation.refreshCredential);
    },
  );

  test('bootstrap client refresh maps 409 to identityConflict', () async {
    final executor = _FakeExecutor([
      _response(409, <String, dynamic>{
        'code': 13,
        'message': 'Relay device identity conflicts.',
        'operation': 'refresh_credential',
        'peer_id': 'device-1',
      }),
    ]);
    final client = JsonBootstrapClient(executor: executor);
    final result = await client.refresh(
      Uri.parse('https://relay.example'),
      RefreshRequest(
        deviceId: 'device-1',
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        timestamp: 1700000000,
        nonce: _encodedBytes(32, 3),
        signature: _encodedBytes(64, 5),
      ),
    );

    expect(result, isA<SdkFailure<DeviceEnrollment>>());
    final error = (result as SdkFailure<DeviceEnrollment>).error;
    expect(error.code, NetworkErrorCode.identityConflict);
  });

  test('bootstrap client refresh maps 401 code 12 with retry fields', () async {
    final executor = _FakeExecutor([
      _response(401, <String, dynamic>{
        'code': 12,
        'message': 'Relay device authentication failed.',
        'operation': 'refresh_credential',
        'peer_id': 'device-1',
        'retry_disposition': 4,
        'retry_after_seconds': 30,
      }),
    ]);
    final client = JsonBootstrapClient(executor: executor);
    final result = await client.refresh(
      Uri.parse('https://relay.example'),
      RefreshRequest(
        deviceId: 'device-1',
        identityPublicKey: Uint8List.fromList(List<int>.filled(32, 7)),
        timestamp: 1700000000,
        nonce: _encodedBytes(32, 3),
        signature: _encodedBytes(64, 5),
      ),
    );

    expect(result, isA<SdkFailure<DeviceEnrollment>>());
    final error = (result as SdkFailure<DeviceEnrollment>).error;
    expect(error.code, NetworkErrorCode.credentialExpired);
    expect(error.retryDisposition, RetryDisposition.refreshCredentialThenRetry);
    expect(error.retryAfterSeconds, 30);
  });

  test('CommunicationClass mirrors the five v2 business classes', () {
    expect(CommunicationClass.values, hasLength(5));
    expect(CommunicationClass.reliableStream, isA<CommunicationClass>());
    expect(CommunicationClass.reliableMessage, isA<CommunicationClass>());
    expect(CommunicationClass.bulkTransfer, isA<CommunicationClass>());
    expect(CommunicationClass.unreliableDatagram, isA<CommunicationClass>());
    expect(CommunicationClass.realtimeMedia, isA<CommunicationClass>());
    // wireValue 必须镜像 network-protocol `CommunicationClass` 枚举（§17）。
    expect(CommunicationClass.reliableStream.wireValue, 1);
    expect(CommunicationClass.reliableMessage.wireValue, 2);
    expect(CommunicationClass.bulkTransfer.wireValue, 3);
    expect(CommunicationClass.unreliableDatagram.wireValue, 4);
    expect(CommunicationClass.realtimeMedia.wireValue, 5);
  });

  test(
    'facade registerPeer registers identity without initiating connection',
    () async {
      final sessions = _RecordingSessionClient();
      final facade = NetworkFacadeImpl(sessions: sessions);
      final peer = SdkPeerConfig(
        peerId: 'peer-1',
        endpointAddress: '',
        identityPublicKey: _identityKey,
        e2ePublicKey: _identityKey,
      );

      final result = await facade.registerPeer(peer);

      expect(result, isA<SdkSuccess<void>>());
      expect(sessions.upsertedPeer, same(peer));
      expect(sessions.connectedPeers, isEmpty);
    },
  );

  test('facade connectPeer never implicitly registers a peer', () async {
    final sessions = _RecordingSessionClient();
    final facade = NetworkFacadeImpl(sessions: sessions);

    final result = await facade.connectPeer('peer-1');

    expect(result, isA<SdkSuccess<void>>());
    expect(sessions.upsertedPeer, isNull);
    expect(sessions.connectedPeers, <String>['peer-1']);
  });

  test('facade removePeer delegates explicit trust removal', () async {
    final sessions = _RecordingSessionClient();
    final facade = NetworkFacadeImpl(sessions: sessions);

    final result = await facade.removePeer('peer-1');

    expect(result, isA<SdkSuccess<void>>());
    expect(sessions.removedPeers, <String>['peer-1']);
  });

  test(
    'facade connectPeer forwards the requested CommunicationClass',
    () async {
      final sessions = _RecordingSessionClient();
      final facade = NetworkFacadeImpl(sessions: sessions);

      final result = await facade.connectPeer(
        'peer-1',
        communicationClass: CommunicationClass.bulkTransfer,
      );

      expect(result, isA<SdkSuccess<void>>());
      expect(sessions.connectedPeers, <String>['peer-1']);
      expect(sessions.connectClasses, <CommunicationClass>[
        CommunicationClass.bulkTransfer,
      ]);
    },
  );

  test('facade connectPeer defaults to reliableStream class', () async {
    final sessions = _RecordingSessionClient();
    final facade = NetworkFacadeImpl(sessions: sessions);

    final result = await facade.connectPeer('peer-1');

    expect(result, isA<SdkSuccess<void>>());
    expect(sessions.connectClasses, <CommunicationClass>[
      CommunicationClass.reliableStream,
    ]);
  });

  test('facade connectPeer rejects realtimeMedia class', () async {
    final sessions = _RecordingSessionClient();
    final facade = NetworkFacadeImpl(sessions: sessions);

    final result = await facade.connectPeer(
      'peer-1',
      communicationClass: CommunicationClass.realtimeMedia,
    );

    expect(result, isA<SdkFailure<void>>());
    expect(
      (result as SdkFailure<void>).error.code,
      NetworkErrorCode.invalidArgument,
    );
    expect(sessions.connectedPeers, isEmpty);
  });

  test('facade transferFile maps bulkTransfer onto native send', () async {
    final sessions = _RecordingSessionClient();
    final facade = NetworkFacadeImpl(sessions: sessions);

    final result = await facade.transferFile(
      transferId: 'transfer-1',
      peerId: 'peer-1',
      filePath: '/tmp/file.bin',
    );

    expect(result, isA<SdkSuccess<SdkTransferSession>>());
    expect(sessions.sentTransferId, 'transfer-1');
  });

  test('facade transferFile rejects non-bulk communication class', () async {
    final sessions = _RecordingSessionClient();
    final facade = NetworkFacadeImpl(sessions: sessions);

    final result = await facade.transferFile(
      transferId: 'transfer-1',
      peerId: 'peer-1',
      filePath: '/tmp/file.bin',
      communicationClass: CommunicationClass.reliableMessage,
    );

    expect(result, isA<SdkFailure<SdkTransferSession>>());
    expect(
      (result as SdkFailure<SdkTransferSession>).error.code,
      NetworkErrorCode.invalidArgument,
    );
    expect(sessions.sentTransferId, isNull);
  });

  test(
    'facade sendMessage surfaces unsupported reliable message failure',
    () async {
      final sessions = _RecordingSessionClient();
      final facade = NetworkFacadeImpl(sessions: sessions);

      final result = await facade.sendMessage(
        peerId: 'peer-1',
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      );

      expect(result, isA<SdkFailure<void>>());
      expect(
        (result as SdkFailure<void>).error.code,
        NetworkErrorCode.invalidArgument,
      );
    },
  );

  test(
    'facade realtime session delegates to the injected RealtimeClient',
    () async {
      final sessions = _RecordingSessionClient();
      final realtime = _FakeRealtimeClient();
      final facade = NetworkFacadeImpl(sessions: sessions, realtime: realtime);

      final session = facade.createRealtimeSession(
        realtimeId: 'a' * 32,
        peerId: 'peer-1',
      );

      expect(session, isA<RealtimeSession>());
      expect(session.peerId, 'peer-1');
      expect(realtime.createdPeerId, 'peer-1');
    },
  );

  test('facade realtime is unavailable without an injected RealtimeClient', () {
    final facade = NetworkFacadeImpl(sessions: _RecordingSessionClient());

    expect(
      () =>
          facade.createRealtimeSession(realtimeId: 'a' * 32, peerId: 'peer-1'),
      throwsUnsupportedError,
    );
  });

  test('facade dispose releases the owned session client', () async {
    final sessions = _RecordingSessionClient();
    final facade = NetworkFacadeImpl(sessions: sessions);
    await facade.dispose();

    expect(sessions.disposed, isTrue);
    expect(
      () => facade.connectPeer('peer-1'),
      throwsA(isA<SdkClientDisposedException>()),
    );
  });
}

/// 32 字节 Ed25519 密钥材料，仅用于测试 Facade 委托调用形状。
final Uint8List _identityKey = Uint8List.fromList(<int>[
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
]);

SdkResponse _response(int statusCode, [Map<String, dynamic>? body]) =>
    SdkResponse(
      statusCode: statusCode,
      body: Uint8List.fromList(
        body == null ? <int>[] : utf8.encode(jsonEncode(body)),
      ),
    );

final class _FakeExecutor implements SdkRequestExecutor {
  _FakeExecutor(Iterable<SdkResponse> responses)
    : _responses = List<SdkResponse>.from(responses);

  final List<SdkResponse> _responses;
  final List<SdkRequest> requests = <SdkRequest>[];

  @override
  Future<SdkResponse> execute(SdkRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('no fake response');
    return _responses.removeAt(0);
  }
}

final class _FakeAuthSession implements AuthSessionProvider {
  String? token = 'old-token';
  int refreshCount = 0;
  bool invalidated = false;
  Object? readTokenError;
  Object? refreshTokenError;
  Object? invalidateError;

  @override
  Future<String?> readAccessToken() async {
    if (readTokenError != null) throw readTokenError!;
    return token;
  }

  @override
  Future<String?> refreshAccessToken() async {
    refreshCount++;
    if (refreshTokenError != null) throw refreshTokenError!;
    token = 'new-token';
    return token;
  }

  @override
  Future<void> invalidate() async {
    if (invalidateError != null) throw invalidateError!;
    invalidated = true;
    token = null;
  }
}

final class _FakeBootstrapClient implements BootstrapClient {
  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async =>
      const SdkSuccess(BootstrapMetadata(protocolVersion: 2));

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  ) async => SdkSuccess(
    DeviceEnrollment(
      deviceId: request.deviceId,
      relayCredential: 'fake',
      expiresAt: DateTime.utc(2030),
      serverTime: DateTime.utc(2029),
      protocolVersion: 2,
    ),
  );

  @override
  Future<SdkResult<DeviceEnrollment>> refresh(
    Uri endpoint,
    RefreshRequest request,
  ) async => SdkSuccess(
    DeviceEnrollment(
      deviceId: request.deviceId,
      relayCredential: 'fake',
      expiresAt: DateTime.utc(2030),
      serverTime: DateTime.utc(2029),
      protocolVersion: 2,
    ),
  );
}

final class _FakeAuthenticatedApiClient implements AuthenticatedApiClient {
  @override
  Future<SdkResult<List<PeerDescriptor>>> listPeers() async =>
      const SdkSuccess(<PeerDescriptor>[]);

  @override
  Future<SdkResult<ConnectionTicket>> requestConnection(String peerId) async =>
      SdkSuccess(ConnectionTicket(peerId: peerId, value: 'fake'));
}

final class _FakeRealtimeClient implements RealtimeClient {
  String? createdPeerId;
  String? createdRealtimeId;

  @override
  RealtimeSession createSession({
    required String realtimeId,
    required String peerId,
  }) {
    createdRealtimeId = realtimeId;
    createdPeerId = peerId;
    return _FakeRealtimeSession(realtimeId: realtimeId, peerId: peerId);
  }

  @override
  Future<void> releaseSession(RealtimeSession session) async {}

  @override
  Stream<RealtimeIncomingSessionOffer> get incomingOffers =>
      const Stream<RealtimeIncomingSessionOffer>.empty();

  @override
  Future<SdkResult<RealtimeSession>> claimIncomingSession(
    RealtimeIncomingSessionOffer offer,
  ) async => SdkFailure(
    NetworkError(
      code: NetworkErrorCode.invalidArgument,
      message: 'Unsupported in fake.',
      operation: NetworkOperation.connect,
      peerId: offer.authenticatedPeerId,
    ),
  );

  @override
  Future<SdkResult<void>> rejectIncomingOffer(
    RealtimeIncomingSessionOffer offer,
  ) async => const SdkSuccess<void>(null);

  @override
  Future<void> discardIncomingOffer(RealtimeIncomingSessionOffer offer) async {}

  @override
  Future<void> dispose() async {}
}

String _encodedBytes(int length, int value) =>
    base64UrlEncode(List<int>.filled(length, value)).replaceAll('=', '');

final class _FakeRealtimeSession implements RealtimeSession {
  const _FakeRealtimeSession({required this.realtimeId, required this.peerId});

  @override
  final String realtimeId;

  @override
  final String peerId;

  @override
  RealtimeSessionState get state => RealtimeSessionState.idle;

  @override
  int get revision => 0;

  @override
  int? get generation => null;

  @override
  String? get sharedSessionInstanceId => null;

  @override
  RealtimeSessionToken? get mediaToken => null;

  @override
  RealtimeAudioState get audioState => RealtimeAudioState.unavailable;

  @override
  RealtimeSnapshot? get currentSnapshot => null;

  @override
  Stream<RealtimeSnapshot> get snapshots =>
      const Stream<RealtimeSnapshot>.empty();

  @override
  Stream<RealtimeConsent> get consentEvents =>
      const Stream<RealtimeConsent>.empty();

  @override
  Future<SdkResult<void>> sendConsent(RealtimeConsent consent) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> start() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess<void>(null);
}

/// 记录 Facade 委托调用的 SessionClient 替身。
final class _RecordingSessionClient implements SessionClient {
  final StreamController<SdkEvent> _events =
      StreamController<SdkEvent>.broadcast();
  SdkPeerConfig? upsertedPeer;
  final List<String> connectedPeers = <String>[];
  final List<String> removedPeers = <String>[];
  final List<CommunicationClass> connectClasses = <CommunicationClass>[];
  String? sentTransferId;
  bool disposed = false;

  @override
  Stream<SdkEvent> get events => _events.stream;

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer) async {
    upsertedPeer = peer;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> removePeer(String peerId) async {
    removedPeers.add(peerId);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> connect(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    connectedPeers.add(peerId);
    connectClasses.add(communicationClass);
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> disconnect(String peerId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> disconnectRelay() async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkTransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) async {
    sentTransferId = transferId;
    return SdkSuccess(
      SdkTransferSession(
        transferId: transferId,
        peerId: peerId,
        filePath: filePath,
        routeType: NetworkRouteType.unspecified,
      ),
    );
  }

  @override
  Future<SdkResult<void>> cancel(String transferId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkRouteSnapshot>> state(String peerId) async => SdkSuccess(
    SdkRouteSnapshot(peerId: peerId, routeType: NetworkRouteType.unspecified),
  );

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}

final class _FakeEvents implements EventStreamClient {
  const _FakeEvents(this.events);

  @override
  final Stream<SdkEvent> events;
}

final class _FakeSessionClient implements SessionClient {
  @override
  final Stream<SdkEvent> events = const Stream<SdkEvent>.empty();

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> stop() async => const SdkSuccess(null);

  @override
  Future<SdkResult<void>> upsertPeer(SdkPeerConfig peer) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> removePeer(String peerId) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> connect(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async => const SdkSuccess(null);

  @override
  Future<SdkResult<void>> disconnect(String peerId) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> disconnectRelay() async => const SdkSuccess(null);

  @override
  Future<SdkResult<SdkTransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  }) async => SdkSuccess(
    SdkTransferSession(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
      routeType: NetworkRouteType.unspecified,
    ),
  );

  @override
  Future<SdkResult<void>> cancel(String transferId) async =>
      const SdkSuccess(null);

  @override
  Future<SdkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  }) async => const SdkSuccess(null);

  @override
  Future<SdkResult<SdkRouteSnapshot>> state(String peerId) async => SdkSuccess(
    SdkRouteSnapshot(peerId: peerId, routeType: NetworkRouteType.unspecified),
  );

  @override
  Future<void> dispose() async {}
}
