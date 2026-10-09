import 'package:ssh_mobile_network/lan/network_secret_store.dart';

/// In-memory secret store for network-app tests.
final class MemorySecretStore implements NetworkSecretStore {
  /// Values written by the test or the app.
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
