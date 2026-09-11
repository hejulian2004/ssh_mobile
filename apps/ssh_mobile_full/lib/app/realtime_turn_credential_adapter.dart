import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:network_sdk/network_sdk.dart';

/// App-injected authenticated TURN issuer.
///
/// The HTTP/device-proof implementation stays in the App networking
/// composition. This adapter only forwards the native-authoritative session
/// token and keeps the resulting credential in the caller's session memory.
final class AppRealtimeTurnCredentialProvider
    implements TurnCredentialProvider {
  const AppRealtimeTurnCredentialProvider({required this.issueCredential});

  final Future<SdkResult<EphemeralTurnCredential>> Function(
    RealtimeSessionToken token,
  )
  issueCredential;

  @override
  Future<SdkResult<EphemeralTurnCredential>> issue(
    RealtimeSessionToken token,
  ) => issueCredential(token);
}

/// App-owned signer for the Relay V2 device-authenticated TURN endpoint.
///
/// The enrollment port is the only owner that may read the device signing
/// seed. This adapter borrows it for one fresh transcript and returns headers
/// only; no seed or TURN credential is copied into Feature state or logs.
final class AppTurnCredentialRequestSigner
    implements TurnCredentialRequestSigner {
  AppTurnCredentialRequestSigner({
    required this.relayEnrollment,
    required Uri relayEndpoint,
  }) : relayEndpoint = _validateRelayEndpoint(relayEndpoint);

  final lan.LanRelayEnrollmentPort relayEnrollment;
  final Uri relayEndpoint;

  @override
  Future<Map<String, String>> sign(SdkRequest request) async {
    if (request.method.toUpperCase() != 'POST' ||
        request.uri.path != RelayBootstrapRoutes.turnCredentialsV2 ||
        !_sameOrigin(request.uri, relayEndpoint) ||
        request.uri.query.isNotEmpty ||
        request.uri.fragment.isNotEmpty) {
      throw ArgumentError('TURN request target is invalid.');
    }
    final native = await relayEnrollment.nativeConfiguration(
      lan.RelaySettings(endpoint: relayEndpoint),
    );
    if (native == null ||
        native.endpoint != relayEndpoint ||
        native.credential.trim().isEmpty ||
        native.signingSeed.length != 32) {
      throw StateError('Relay device proof is unavailable.');
    }
    final timestamp =
        DateTime.now().toUtc().millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond;
    final nonceBytes = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final nonce = base64UrlEncode(nonceBytes).replaceAll('=', '');
    final transcript =
        '${request.method.toUpperCase()}\n${request.uri.path}\n$timestamp\n$nonce';
    final signing = Ed25519();
    final keyPair = await signing.newKeyPairFromSeed(native.signingSeed);
    final signature = await signing.sign(
      utf8.encode(transcript),
      keyPair: keyPair,
    );
    return <String, String>{
      'X-Relay-Timestamp': '$timestamp',
      'X-Relay-Nonce': nonce,
      'X-Relay-Signature': base64UrlEncode(signature.bytes).replaceAll('=', ''),
    };
  }
}

Uri _validateRelayEndpoint(Uri endpoint) {
  if ((endpoint.scheme != 'https' && endpoint.scheme != 'http') ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.path.isNotEmpty && endpoint.path != '/') {
    throw ArgumentError.value(endpoint, 'relayEndpoint');
  }
  return endpoint.replace(path: '');
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme == right.scheme &&
    left.host == right.host &&
    left.port == right.port;
