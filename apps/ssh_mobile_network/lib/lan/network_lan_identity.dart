// Ed25519 and X25519 identity owned by the network-transfer app.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

import 'network_lan_keys.dart';
import 'network_secret_store.dart';

/// Loads or creates this app's network identity.
final class NetworkLanIdentity implements LanShareNetworkIdentityPort {
  /// Creates an identity loader backed by [secrets].
  NetworkLanIdentity(this._secrets);

  final NetworkSecretStore _secrets;
  LanShareNetworkIdentityMaterial? _cached;
  Future<LanShareNetworkIdentityMaterial>? _loadFuture;

  @override
  Future<LanShareNetworkIdentityMaterial> loadOrCreate() {
    final cached = _cached;
    if (cached != null) {
      return Future<LanShareNetworkIdentityMaterial>.value(cached);
    }
    final existing = _loadFuture;
    if (existing != null) {
      return existing;
    }
    final future = _load();
    _loadFuture = future;
    return future;
  }

  Future<LanShareNetworkIdentityMaterial> _load() async {
    try {
      final ed25519 = Ed25519();
      final edSeed = await _seed(
        storageKey: NetworkLanStorageKeys.ed25519Seed,
        create: ed25519.newKeyPair,
        fromSeed: ed25519.newKeyPairFromSeed,
      );
      final x25519 = X25519();
      final xSeed = await _seed(
        storageKey: NetworkLanStorageKeys.x25519Seed,
        create: x25519.newKeyPair,
        fromSeed: x25519.newKeyPairFromSeed,
      );
      final edPublic = await _publicKey(ed25519.newKeyPairFromSeed(edSeed));
      final xPublic = await _publicKey(x25519.newKeyPairFromSeed(xSeed));
      final material = LanShareNetworkIdentityMaterial(
        privateSeed: edSeed,
        publicKey: edPublic,
        x25519PrivateSeed: xSeed,
        x25519PublicKey: xPublic,
      );
      _cached = material;
      return material;
    } finally {
      _loadFuture = null;
    }
  }

  Future<Uint8List> _seed({
    required String storageKey,
    required Future<SimpleKeyPair> Function() create,
    required Future<SimpleKeyPair> Function(List<int> seed) fromSeed,
  }) async {
    final stored = await _secrets.read(storageKey);
    if (stored == null || stored.isEmpty) {
      final created = await create();
      final seed = Uint8List.fromList(await created.extractPrivateKeyBytes());
      if (seed.length != 32) {
        throw StateError('Generated network identity seed is invalid.');
      }
      await _secrets.write(
        storageKey,
        base64UrlEncode(seed).replaceAll('=', ''),
      );
      return seed;
    }
    final seed = _decode(stored);
    await fromSeed(seed);
    return seed;
  }

  Future<Uint8List> _publicKey(Future<SimpleKeyPair> pairFuture) async {
    final public = await (await pairFuture).extractPublicKey();
    if (public.bytes.length != 32) {
      throw StateError('Generated network identity public key is invalid.');
    }
    return Uint8List.fromList(public.bytes);
  }

  Uint8List _decode(String encoded) {
    try {
      final seed = base64Url.decode(base64Url.normalize(encoded));
      if (seed.length != 32) {
        throw StateError('Stored network identity seed is invalid.');
      }
      return Uint8List.fromList(seed);
    } on FormatException {
      throw StateError('Stored network identity seed is invalid.');
    }
  }
}
