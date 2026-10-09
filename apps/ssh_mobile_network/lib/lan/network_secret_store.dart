/// App-owned secret storage used by the network-transfer composition root.
///
/// Production uses platform secure storage. Tests inject an in-memory store.
/// Keys belong to this app and must not reuse Full App key names.
abstract interface class NetworkSecretStore {
  /// Reads one stored value. Missing keys return null.
  Future<String?> read(String key);

  /// Writes one stored value.
  Future<void> write(String key, String value);
}
