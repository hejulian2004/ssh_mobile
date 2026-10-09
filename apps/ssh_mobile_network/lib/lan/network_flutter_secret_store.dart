// Platform secure-storage boundary. Behavior lives in NetworkSecretStore callers.
// coverage:ignore-file

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'network_secret_store.dart';

/// Forwards secret reads and writes to Flutter secure storage.
final class FlutterNetworkSecretStore implements NetworkSecretStore {
  /// Creates a store. macOS avoids the extra data-protection keychain ACL.
  FlutterNetworkSecretStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}
