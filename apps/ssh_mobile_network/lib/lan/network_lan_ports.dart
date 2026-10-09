// LAN page ports owned by the network-transfer app.

import 'package:app_core/app_core.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:network_sdk/network_sdk.dart';

/// Writes LAN diagnostics without keeping secret material in the log buffer.
final class NetworkLanLogger implements LanShareLoggerPort {
  /// Creates a logger that does not own [logger].
  const NetworkLanLogger(this._logger);

  final AppLogger _logger;

  @override
  void info(String message, {String? details}) {
    _write(LogLevel.info, message, details: details);
  }

  @override
  void warning(String message, {String? details}) {
    _write(LogLevel.warning, message, details: details);
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    _write(
      LogLevel.error,
      message,
      details: details,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _write(
    LogLevel level,
    String message, {
    String? details,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final secret = _containsSecret('$message ${details ?? ''} ${error ?? ''}');
    _logger.log(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        source: 'network_lan',
        message: secret ? 'redacted' : message,
        details: secret ? null : details,
        error: secret ? null : error,
        stackTrace: secret ? null : stackTrace,
      ),
    );
  }

  static bool _containsSecret(String value) {
    final lower = value.toLowerCase();
    return lower.contains('password') ||
        lower.contains('passphrase') ||
        lower.contains('private key') ||
        lower.contains('privatekey') ||
        lower.contains('bearer ') ||
        lower.contains('authorization') ||
        RegExp(r'token\s*=').hasMatch(lower);
  }
}

/// The network-transfer app has no production SessionClient to adapt.
///
/// Native file transfer and the relay data plane stay on the Full App.
/// LAN discovery and control HTTP still start.
final class NetworkLanAccess implements LanShareNetworkAccessPort {
  /// Creates an access port that never invents a facade.
  const NetworkLanAccess();

  @override
  Future<NetworkFacade?> borrowFacade() async => null;
}

/// Screen share stays fail-closed. This app does not import that feature.
final class NetworkLanScreenShare implements LanShareScreenSharePort {
  /// Creates a port that rejects every screen-share request.
  const NetworkLanScreenShare();

  @override
  bool canShareWith(String peerId) => false;

  @override
  bool canReceiveScreenShareFrom(String peerId) => false;

  @override
  Future<void> startScreenShare(String peerId) {
    return Future<void>.error(
      StateError('Screen share is not available in this app.'),
    );
  }
}
