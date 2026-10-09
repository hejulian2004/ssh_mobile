// LAN device identity and relay origin for the network-transfer app.

import 'dart:math';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/foundation.dart';

import 'network_lan_keys.dart';
import 'network_lan_strings.dart';
import 'network_secret_store.dart';

/// App-owned LAN settings. The receiver stays enabled for this page.
final class NetworkLanSettings extends ChangeNotifier
    implements LanShareSettingsPort {
  /// Creates settings that read and write [secrets].
  NetworkLanSettings({
    required this.secrets,
    this.language = LanShareLanguage.zh,
  }) : strings = NetworkLanStrings(language);

  /// Secret store that persists device identity and the relay origin.
  final NetworkSecretStore secrets;

  @override
  final LanShareLanguage language;

  @override
  final NetworkLanStrings strings;

  String _deviceId = '';
  String _alias = '';
  String _relayEndpoint = '';
  Future<void>? _ensureFuture;
  bool _disposed = false;

  @override
  bool get isEnglish => language == LanShareLanguage.en;

  @override
  String get lanDeviceId => _deviceId;

  @override
  String get lanDeviceAlias => _alias;

  @override
  String get relayEndpoint => _relayEndpoint;

  @override
  String get relayHost => Uri.tryParse(_relayEndpoint)?.host ?? '';

  @override
  int get relayPort {
    final endpoint = Uri.tryParse(_relayEndpoint);
    if (endpoint == null || endpoint.host.isEmpty) return 443;
    return endpoint.hasPort ? endpoint.port : 443;
  }

  @override
  bool get receiverEnabled => true;

  @override
  Future<void> ensureLanIdentity() {
    final existing = _ensureFuture;
    if (existing != null) return existing;
    final future = _loadIdentity();
    _ensureFuture = future;
    return future.whenComplete(() {
      if (identical(_ensureFuture, future)) _ensureFuture = null;
    });
  }

  Future<void> _loadIdentity() async {
    if (_deviceId.isNotEmpty && _alias.isNotEmpty) return;
    final storedId = await secrets.read(NetworkLanStorageKeys.deviceId) ?? '';
    final storedAlias =
        await secrets.read(NetworkLanStorageKeys.deviceAlias) ?? '';
    final storedRelay =
        await secrets.read(NetworkLanStorageKeys.relayEndpoint) ?? '';
    final deviceId = storedId.isEmpty ? _newDeviceId() : storedId;
    final alias = storedAlias.isEmpty ? '本机' : storedAlias;
    if (storedId.isEmpty) {
      await secrets.write(NetworkLanStorageKeys.deviceId, deviceId);
    }
    if (storedAlias.isEmpty) {
      await secrets.write(NetworkLanStorageKeys.deviceAlias, alias);
    }
    _deviceId = deviceId;
    _alias = alias;
    final relay = _normalizeRelayEndpoint(storedRelay);
    if (relay != null) _relayEndpoint = relay;
    notifyListeners();
  }

  @override
  Future<void> setLanDeviceAlias(String alias) async {
    if (_alias == alias) return;
    await secrets.write(NetworkLanStorageKeys.deviceAlias, alias);
    _alias = alias;
    notifyListeners();
  }

  @override
  Future<void> setRelayEndpoint(String endpoint) async {
    final normalized = _requireRelayEndpoint(endpoint);
    if (_relayEndpoint == normalized) return;
    await secrets.write(NetworkLanStorageKeys.relayEndpoint, normalized);
    _relayEndpoint = normalized;
    notifyListeners();
  }

  @override
  Future<void> setRelayServer({required String host, required int port}) async {
    final normalizedHost = host.trim();
    if (normalizedHost.isEmpty ||
        normalizedHost.contains('://') ||
        normalizedHost.contains('/') ||
        port < 1 ||
        port > 65535) {
      throw ArgumentError('A host and a port from 1 to 65535 are required.');
    }
    await setRelayEndpoint(
      Uri(scheme: 'https', host: normalizedHost, port: port).toString(),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }

  static String? _normalizeRelayEndpoint(String endpoint) {
    try {
      return _requireRelayEndpoint(endpoint);
    } on ArgumentError {
      return null;
    }
  }

  static String _requireRelayEndpoint(String endpoint) {
    final normalized = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty) return '';
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'must be an HTTPS relay origin',
      );
    }
    return normalized;
  }

  static String _newDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
