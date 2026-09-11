import 'realtime.dart';
import 'turn_credential_models.dart';

const _defaultTurnStoreCapacity = 32;

/// In-memory credentials scoped by the native-authoritative Realtime token.
final class RealtimeTurnCredentialStore {
  RealtimeTurnCredentialStore({this.maxEntries = _defaultTurnStoreCapacity}) {
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
  }

  final int maxEntries;
  final Map<RealtimeSessionToken, EphemeralTurnCredential> _credentials =
      <RealtimeSessionToken, EphemeralTurnCredential>{};

  EphemeralTurnCredential? getValid(
    RealtimeSessionToken token, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    _sweep(current);
    final credential = _credentials[token];
    if (credential == null) return null;
    if (credential.isExpired(current)) {
      _credentials.remove(token);
      return null;
    }
    return credential;
  }

  void put(RealtimeSessionToken token, EphemeralTurnCredential credential) {
    if (credential.isExpired()) {
      throw ArgumentError('TURN credential is expired.');
    }
    final now = DateTime.now();
    _sweep(now);
    _credentials.removeWhere(
      (existing, _) =>
          existing.realtimeId == token.realtimeId &&
          existing.generation != token.generation,
    );
    if (!_credentials.containsKey(token) && _credentials.length >= maxEntries) {
      throw StateError('TURN credential store capacity exhausted.');
    }
    _credentials[token] = credential;
  }

  void clear(RealtimeSessionToken token) {
    _sweep(DateTime.now());
    _credentials.remove(token);
  }

  void clearAll() => _credentials.clear();

  int get length {
    _sweep(DateTime.now());
    return _credentials.length;
  }

  void _sweep(DateTime now) {
    _credentials.removeWhere((_, credential) => credential.isExpired(now));
  }
}
