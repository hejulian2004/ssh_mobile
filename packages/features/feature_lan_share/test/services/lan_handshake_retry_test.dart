import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('a failed challenge is retried before confirm is sent', () async {
    final posts = <String>[];
    final result = await _send(posts, (body) async {
      return _ScriptedResponse(
        HttpStatus.internalServerError,
        '{"message":"down"}',
      );
    });

    expect(result, isA<NetworkFailure<LanPairingHandshakeProgress>>());
    expect(posts, ['begin', 'begin', 'begin']);
  });

  test('a confirm response is not followed by another handshake', () async {
    final posts = <String>[];
    final result = await _send(posts, (raw) async {
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final phase = body['phase'];
      if (phase == 'begin') {
        return _ScriptedResponse(HttpStatus.ok, jsonEncode(_challenge(body)));
      }
      return _ScriptedResponse(
        HttpStatus.unauthorized,
        jsonEncode({
          'message': 'LAN pairing confirmation is invalid or expired.',
        }),
      );
    });

    expect(result, isA<NetworkFailure<LanPairingHandshakeProgress>>());
    expect(posts, ['begin', 'confirm']);
  });
}

Future<NetworkResult<LanPairingHandshakeProgress>> _send(
  List<String> posts,
  Future<HttpClientResponse> Function(String body) respond,
) {
  final security = LanSecurityService(appOwnedX25519PrivateSeed: Uint8List(32));
  final service = LanTransferService(
    currentDeviceId: 'device-a',
    securityService: security,
    storageService: LanStorageService(),
    networkIdentityPublicKeyProvider: () async => Uint8List(32),
  );
  addTearDown(service.close);
  final device = LanDiscoveredPeer(
    deviceId: 'peer-b',
    alias: 'Peer',
    ip: '192.168.1.20',
    controlPort: 53317,
    os: 'windows',
    lastSeen: DateTime.utc(2026, 9, 29),
  );

  return HttpOverrides.runZoned(
    () => service.sendHandshake(device, '123456', 'Local'),
    createHttpClient: (SecurityContext? context) {
      return _ScriptedClient((raw) async {
        final body = jsonDecode(raw) as Map<String, dynamic>;
        posts.add(body['phase'] as String);
        return respond(raw);
      });
    },
  );
}

Map<String, Object?> _challenge(Map<String, dynamic> begin) {
  const fingerprint =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  final serverX25519 = Uint8List.fromList(List<int>.filled(32, 3));
  final serverNetworkIdentity = Uint8List.fromList(List<int>.filled(32, 4));
  final clientContext = LanPairingCrypto.clientContext(
    senderDeviceId: begin['deviceId'] as String,
    targetDeviceId: begin['targetDeviceId'] as String,
    nonce: begin['nonce'] as String,
    alias: begin['alias'] as String,
    os: begin['os'] as String,
    port: (begin['port'] as num).toInt(),
    isInitiator: begin['isInitiator'] == true,
    senderCertFingerprint: begin['certFingerprint'] as String,
    senderX25519PublicKey: _decodeKey(begin['x25519PubKey'] as String),
    senderNetworkIdentityPublicKey: _decodeKey(
      begin['networkIdentityPubKey'] as String,
    ),
    senderInboundAccessTokenHash: begin['inboundAccessTokenHash'] as String,
  );
  final clientPublicValue = base64.decode(
    (begin['clientPublicValues'] as List<dynamic>).first as String,
  );
  final serverKeys = LanPairingCrypto.generateServerKeyPair(
    pin: '123456',
    clientContext: clientContext,
    slot: 0,
    clientPublicValue: Uint8List.fromList(clientPublicValue),
  );
  const handshakeId = 'handshake-confirm-once';
  final associatedData = LanPairingCrypto.sessionAssociatedData(
    clientContext: clientContext,
    handshakeId: handshakeId,
    slot: 0,
    salt: serverKeys.salt,
    clientPublicValue: Uint8List.fromList(clientPublicValue),
    serverPublicValue: serverKeys.publicValue,
    serverCertFingerprint: fingerprint,
    serverX25519PublicKey: serverX25519,
    serverNetworkIdentityPublicKey: serverNetworkIdentity,
  );
  final secrets = LanPairingCrypto.deriveSessionSecrets(
    localKeyPair: serverKeys,
    remotePublicValue: Uint8List.fromList(clientPublicValue),
    associatedData: associatedData,
  );
  return <String, Object?>{
    'protocolVersion': LanPairingCrypto.protocolVersion,
    'status': 'challenge',
    'certFingerprint': fingerprint,
    'x25519PubKey': base64UrlEncode(serverX25519),
    'networkIdentityPubKey': base64UrlEncode(serverNetworkIdentity),
    'validForMs': LanPairingCrypto.credentialTtlMillis,
    'offers': <Map<String, Object?>>[
      <String, Object?>{
        'handshakeId': handshakeId,
        'slot': 0,
        'salt': base64.encode(serverKeys.salt),
        'serverPublicValue': base64.encode(serverKeys.publicValue),
        'serverProof': LanPairingCrypto.createServerProof(secrets),
      },
    ],
  };
}

Uint8List _decodeKey(String encoded) {
  return Uint8List.fromList(base64Url.decode(base64Url.normalize(encoded)));
}

final class _ScriptedClient extends Fake implements HttpClient {
  _ScriptedClient(this._respond);

  final Future<HttpClientResponse> Function(String body) _respond;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  String Function(Uri url)? findProxy;

  @override
  bool Function(X509Certificate cert, String host, int port)?
  badCertificateCallback;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async =>
      _ScriptedRequest(_respond);

  @override
  void close({bool force = false}) {}
}

final class _ScriptedRequest extends Fake implements HttpClientRequest {
  _ScriptedRequest(this._respond);

  final Future<HttpClientResponse> Function(String body) _respond;
  final StringBuffer _body = StringBuffer();

  @override
  bool followRedirects = false;

  @override
  HttpHeaders get headers => _ScriptedHeaders();

  @override
  void write(Object? object) {
    _body.write(object);
  }

  @override
  Future<HttpClientResponse> close() => _respond(_body.toString());
}

final class _ScriptedHeaders extends Fake implements HttpHeaders {
  @override
  set contentType(ContentType? value) {}
}

final class _ScriptedResponse extends Fake implements HttpClientResponse {
  _ScriptedResponse(this.statusCode, this._body);

  @override
  final int statusCode;
  final String _body;

  @override
  Future<void> forEach(void Function(List<int> element) action) async {
    action(utf8.encode(_body));
  }
}
