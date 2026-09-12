import 'dart:convert';

const _maxTurnUrls = 8;
const _maxTurnUrlBytes = 2048;
const _maxTurnUsernameBytes = 256;
const _maxTurnPasswordBytes = 512;

/// Short-lived credential returned by the authenticated TURN issuer.
final class EphemeralTurnCredential {
  EphemeralTurnCredential({
    required List<String> urls,
    required this.username,
    required this.password,
    required this.expiresAt,
  }) : urls = List.unmodifiable(urls) {
    if (this.urls.isEmpty ||
        this.urls.length > _maxTurnUrls ||
        this.urls.any((url) => url.trim().isEmpty)) {
      throw ArgumentError('TURN server URLs are invalid.');
    }
    for (final url in this.urls) {
      _validateTurnUrl(url);
    }
    if (username.trim().isEmpty ||
        utf8.encode(username).length > _maxTurnUsernameBytes) {
      throw ArgumentError('TURN username is invalid.');
    }
    if (password.isEmpty ||
        utf8.encode(password).length > _maxTurnPasswordBytes) {
      throw ArgumentError('TURN password is invalid.');
    }
    if (!expiresAt.isAfter(DateTime.now())) {
      throw ArgumentError.value(expiresAt, 'expiresAt');
    }
  }

  final List<String> urls;
  final String username;
  final String password;
  final DateTime expiresAt;

  bool isExpired([DateTime? now]) => !expiresAt.isAfter(now ?? DateTime.now());

  /// Deliberately omits credential material from diagnostics and logs.
  @override
  String toString() =>
      'EphemeralTurnCredential(urls: ${urls.length}, expiresAt: $expiresAt)';
}

void _validateTurnUrl(String value) {
  if (utf8.encode(value).length > _maxTurnUrlBytes ||
      value != value.trim() ||
      RegExp(r'[\u0000-\u0020\u007f]').hasMatch(value)) {
    throw ArgumentError('TURN server URL is invalid.');
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'turn' && uri.scheme != 'turns') ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw ArgumentError('TURN server URL is invalid.');
  }

  final authority = uri.host.isNotEmpty
      ? (uri.path.isEmpty ? (uri.host, uri.hasPort ? uri.port : null) : null)
      : _parseOpaqueTurnAuthority(uri.path);
  if (authority == null ||
      !_isValidTurnHost(authority.$1) ||
      (authority.$2 != null &&
          (authority.$2! <= 0 || authority.$2! > 65_535))) {
    throw ArgumentError('TURN server URL is invalid.');
  }
}

(String, int?)? _parseOpaqueTurnAuthority(String value) {
  if (value.isEmpty) return null;
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close <= 1) return null;
    final host = value.substring(1, close);
    final suffix = value.substring(close + 1);
    if (suffix.isEmpty) return (host, null);
    if (!suffix.startsWith(':')) return null;
    return (host, int.tryParse(suffix.substring(1)));
  }
  if (value.contains('[') ||
      value.contains(']') ||
      value.contains('/') ||
      value.contains('\\')) {
    return null;
  }
  final firstColon = value.indexOf(':');
  if (firstColon < 0) return (value, null);
  if (firstColon == 0 || firstColon != value.lastIndexOf(':')) return null;
  final port = int.tryParse(value.substring(firstColon + 1));
  if (port == null) return null;
  return (value.substring(0, firstColon), port);
}

bool _isValidTurnHost(String host) {
  if (host.isEmpty ||
      host.contains('@') ||
      host.contains('/') ||
      host.contains('\\') ||
      host.contains('[') ||
      host.contains(']')) {
    return false;
  }
  return !RegExp(r'[\u0000-\u0020\u007f]').hasMatch(host);
}
