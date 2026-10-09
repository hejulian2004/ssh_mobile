/// Secure-storage key names owned by the network-transfer app.
///
/// These names are distinct from the Full App identity, device, and data
/// protection keys so the two apps do not overwrite each other.
abstract final class NetworkLanStorageKeys {
  /// Stable LAN device id.
  static const deviceId = 'network_app_lan_device_id_v1';

  /// Display alias broadcast during discovery.
  static const deviceAlias = 'network_app_lan_device_alias_v1';

  /// Relay HTTPS origin. Enrollment tokens are never stored here.
  static const relayEndpoint = 'network_app_relay_endpoint_v1';

  /// Ed25519 seed for this app's network identity.
  static const ed25519Seed = 'network_app_ed25519_seed_v1';

  /// X25519 seed for this app's network identity.
  static const x25519Seed = 'network_app_x25519_seed_v1';

  /// AES-256-GCM key for LAN history fields.
  static const dataProtectionKey = 'network_app_data_protection_key_v1';
}
