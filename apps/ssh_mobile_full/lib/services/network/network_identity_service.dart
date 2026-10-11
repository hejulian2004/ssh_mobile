import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class NetworkIdentityBundle {
  const NetworkIdentityBundle({
    required this.ed25519PrivateSeed,
    required this.ed25519PublicKey,
    required this.x25519PrivateSeed,
    required this.x25519PublicKey,
  });

  final Uint8List ed25519PrivateSeed;
  final Uint8List ed25519PublicKey;
  final Uint8List x25519PrivateSeed;
  final Uint8List x25519PublicKey;
}

/// Owns the App Scope Network V2 Ed25519 and X25519 identity bundle.
///
/// Relay signing credentials remain a separate control-plane concern; this
/// service is the only owner of the native data-plane identity material.
class NetworkIdentityService {
  NetworkIdentityService({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _identitySeedKey = 'network_quic_ed25519_seed_v1';
  static const _x25519SeedKey = 'network_x25519_seed_v1';
  final FlutterSecureStorage _secureStorage;
  NetworkIdentityBundle? _cached;
  Future<NetworkIdentityBundle>? _loadFuture;

  Future<NetworkIdentityBundle> loadOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;
    final inFlight = _loadFuture;
    if (inFlight != null) return inFlight;

    final future = _loadAndCreate();
    _loadFuture = future;
    // Clear only this generation. A failed read/write must be retryable, while
    // concurrent callers continue sharing the same in-flight operation.
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_loadFuture, future)) _loadFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_loadFuture, future)) _loadFuture = null;
        },
      ),
    );
    return future;
  }

  Future<NetworkIdentityBundle> _loadAndCreate() async {
    // These independent secure-store reads are both on the startup path.
    // Join them before deriving or persisting keys, retaining single-flight
    // identity creation and settling both reads before a failure is retried.
    final storedSeeds = await Future.wait<String?>([
      _secureStorage.read(key: _identitySeedKey),
      _secureStorage.read(key: _x25519SeedKey),
    ]);
    final ed25519 = Ed25519();
    final ed25519Pair = await _loadOrCreateKeyPair(
      newKeyPair: ed25519.newKeyPair,
      newKeyPairFromSeed: ed25519.newKeyPairFromSeed,
      storageKey: _identitySeedKey,
      description: 'QUIC Ed25519',
      stored: storedSeeds[0],
    );
    final ed25519Private = await ed25519Pair.extractPrivateKeyBytes();
    final ed25519Public = await ed25519Pair.extractPublicKey();

    final x25519 = X25519();
    final x25519Pair = await _loadOrCreateKeyPair(
      newKeyPair: x25519.newKeyPair,
      newKeyPairFromSeed: x25519.newKeyPairFromSeed,
      storageKey: _x25519SeedKey,
      description: 'Network X25519',
      stored: storedSeeds[1],
    );
    final x25519Private = await x25519Pair.extractPrivateKeyBytes();
    final x25519Public = await x25519Pair.extractPublicKey();

    if (ed25519Private.length != 32 || ed25519Public.bytes.length != 32) {
      throw StateError('Generated QUIC Ed25519 identity is invalid.');
    }
    if (x25519Private.length != 32 || x25519Public.bytes.length != 32) {
      throw StateError('Generated Network X25519 identity is invalid.');
    }

    final material = NetworkIdentityBundle(
      ed25519PrivateSeed: Uint8List.fromList(ed25519Private),
      ed25519PublicKey: Uint8List.fromList(ed25519Public.bytes),
      x25519PrivateSeed: Uint8List.fromList(x25519Private),
      x25519PublicKey: Uint8List.fromList(x25519Public.bytes),
    );
    _cached = material;
    return material;
  }

  Future<SimpleKeyPair> _loadOrCreateKeyPair({
    required Future<SimpleKeyPair> Function() newKeyPair,
    required Future<SimpleKeyPair> Function(List<int>) newKeyPairFromSeed,
    required String storageKey,
    required String description,
    required String? stored,
  }) async {
    if (stored == null) {
      final pair = await newKeyPair();
      final seed = await pair.extractPrivateKeyBytes();
      if (seed.length != 32) {
        throw StateError('Generated $description identity seed is invalid.');
      }
      await _secureStorage.write(
        key: storageKey,
        value: base64UrlEncode(seed).replaceAll('=', ''),
      );
      return pair;
    }

    final seed = _decodeSeed(stored, description);
    return newKeyPairFromSeed(seed);
  }

  Uint8List _decodeSeed(String encoded, String description) {
    try {
      final seed = base64Url.decode(base64Url.normalize(encoded));
      if (seed.length != 32) {
        throw StateError('Stored $description identity seed is invalid.');
      }
      return Uint8List.fromList(seed);
    } on FormatException {
      throw StateError('Stored $description identity seed is invalid.');
    }
  }
}
