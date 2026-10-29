import 'dart:io';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:feature_sftp/feature_sftp.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

part 'android_document_cache.dart';

/// Android SAF bridge shared by SFTP and LAN.
///
/// The native side owns the picker, the persistable grant, and the content
/// stream. This class only moves bounded chunks through an app-owned cache
/// file. Non-Android builds keep [usesSystemDocuments] false.
final class AndroidSystemDocuments {
  AndroidSystemDocuments({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('ssh_mobile/document_access');

  static const int chunkBytes = 16 * 1024;
  static int _copySequence = 0;

  static String _copyId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_copySequence++}';

  final MethodChannel _channel;
  late final SftpDocumentAccessPort sftp = _SftpDocuments(this);
  late final LanDocumentAccessPort lan = _LanDocuments(this);

  bool get usesSystemDocuments => !kIsWeb && Platform.isAndroid;

  Future<Map<String, Object?>?> pick({
    required String mode,
    required String mimeType,
    String? suggestedName,
  }) async {
    final raw = await _invoke('pick', {
      'mode': mode,
      'mimeType': mimeType,
      'suggestedName': ?suggestedName,
    });
    if (raw == null) return null;
    if (raw is! Map) {
      throw const AndroidDocumentException(AndroidDocumentException.missing);
    }
    final picked = raw.map((key, value) => MapEntry(key.toString(), value));
    final uri = picked['uri'];
    final parsed = uri is String ? Uri.tryParse(uri) : null;
    if (parsed == null ||
        parsed.scheme != 'content' ||
        parsed.authority.isEmpty ||
        picked['mode'] != mode) {
      if (parsed?.scheme == 'content' && parsed!.authority.isNotEmpty) {
        await _releaseGrant(this, uri as String, mode);
      }
      throw const AndroidDocumentException(AndroidDocumentException.denied);
    }
    return picked;
  }

  Future<void> release({required String uri, required String mode}) {
    return _invoke('release', {'uri': uri, 'mode': mode});
  }

  Future<({String path, int size})> copyToCache({
    required String uri,
    required int maxBytes,
    String? operationId,
  }) async {
    final raw = await _invoke('copyToCache', {
      'uri': uri,
      'maxBytes': maxBytes,
      'operationId': ?operationId,
    });
    if (raw is! Map) {
      throw const AndroidDocumentException(AndroidDocumentException.missing);
    }
    final path = raw['path'];
    final size = raw['size'];
    final parsed = size is int ? size : null;
    if (path is! String || path.isEmpty || parsed == null || parsed < 0) {
      throw const AndroidDocumentException(AndroidDocumentException.io);
    }
    return (path: path, size: parsed);
  }

  Future<String> reserveStaging() async {
    final raw = await _invoke('reserveStaging');
    if (raw is! Map ||
        raw['path'] is! String ||
        (raw['path'] as String).isEmpty) {
      throw const AndroidDocumentException(AndroidDocumentException.io);
    }
    return raw['path'] as String;
  }

  Future<void> copyFromCache({
    required String path,
    required String uri,
    String? operationId,
  }) {
    return _invoke('copyFromCache', {
      'path': path,
      'uri': uri,
      'operationId': ?operationId,
    });
  }

  Future<void> cancelCopy(String operationId) =>
      _invoke('cancelCopy', {'operationId': operationId});

  Future<Object?> _invoke(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw const AndroidDocumentException(AndroidDocumentException.io);
    } on PlatformException catch (error) {
      final code = switch (error.code) {
        AndroidDocumentException.missing ||
        AndroidDocumentException.denied ||
        AndroidDocumentException.tooLarge ||
        AndroidDocumentException.cancelled ||
        AndroidDocumentException.io => error.code,
        _ => AndroidDocumentException.io,
      };
      throw AndroidDocumentException(code);
    }
  }
}

final class AndroidDocumentException implements Exception {
  const AndroidDocumentException(this.code);

  static const String missing = 'DOCUMENT_MISSING';
  static const String denied = 'DOCUMENT_DENIED';
  static const String tooLarge = 'DOCUMENT_TOO_LARGE';
  static const String io = 'DOCUMENT_IO';
  static const String cancelled = 'DOCUMENT_CANCELLED';

  final String code;

  @override
  String toString() => 'AndroidDocumentException: $code';
}

final class _SftpDocuments implements SftpDocumentAccessPort {
  _SftpDocuments(this._owner);

  final AndroidSystemDocuments _owner;

  @override
  bool get usesSystemDocuments => _owner.usesSystemDocuments;

  @override
  Future<SftpDocumentSource?> openForRead({required int maxBytes}) async {
    try {
      final picked = await _owner.pick(mode: 'read', mimeType: '*/*');
      if (picked == null) return null;
      return _SftpSource(_owner, _picked(picked), maxBytes);
    } on AndroidDocumentException catch (error) {
      throw _sftpError(error, null);
    }
  }

  @override
  Future<SftpDocumentSink?> createForWrite({
    required String suggestedName,
  }) async {
    try {
      final picked = await _owner.pick(
        mode: 'write',
        mimeType: 'application/octet-stream',
        suggestedName: _safeName(suggestedName, 'download'),
      );
      if (picked == null) return null;
      return _SftpSink(_owner, _picked(picked).uri);
    } on AndroidDocumentException catch (error) {
      throw _sftpError(error, null);
    }
  }
}

final class _LanDocuments implements LanDocumentAccessPort {
  _LanDocuments(this._owner);

  final AndroidSystemDocuments _owner;

  @override
  bool get usesSystemDocuments => _owner.usesSystemDocuments;

  @override
  Future<LanDocumentSource?> openForRead({
    required String mimeType,
    required int maxBytes,
  }) async {
    try {
      final picked = await _owner.pick(mode: 'read', mimeType: mimeType);
      if (picked == null) return null;
      return _LanSource(_owner, _picked(picked), maxBytes);
    } on AndroidDocumentException catch (error) {
      throw _lanError(error);
    }
  }

  @override
  Future<LanDocumentSink?> createForWrite({
    required String suggestedName,
    required String mimeType,
  }) async {
    try {
      final picked = await _owner.pick(
        mode: 'write',
        mimeType: mimeType,
        suggestedName: _safeName(suggestedName, 'download'),
      );
      if (picked == null) return null;
      return _LanSink(_owner, _picked(picked).uri);
    } on AndroidDocumentException catch (error) {
      throw _lanError(error);
    }
  }
}

final class _PickedDocument {
  const _PickedDocument({
    required this.uri,
    required this.displayName,
    required this.sizeBytes,
  });

  final String uri;
  final String displayName;
  final int? sizeBytes;
}

_PickedDocument _picked(Map<String, Object?> raw) {
  final uri = raw['uri'];
  if (uri is! String || !uri.startsWith('content:')) {
    throw const AndroidDocumentException(AndroidDocumentException.denied);
  }
  final size = raw['size'];
  return _PickedDocument(
    uri: uri,
    displayName: _safeName(
      raw['displayName'] is String ? raw['displayName'] as String : null,
      'document',
    ),
    sizeBytes: size is int && size >= 0 ? size : null,
  );
}

String _safeName(String? raw, String fallback) {
  var name = (raw ?? '').trim();
  final split = name.split(RegExp(r'[\\/]'));
  name = split.isEmpty ? '' : split.last;
  name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F\x7F]'), '_');
  if (name.isEmpty || name == '.' || name == '..') return fallback;
  if (name.length > 200) name = name.substring(name.length - 200);
  return name;
}

final class _SftpSource implements SftpDocumentSource {
  _SftpSource(
    AndroidSystemDocuments owner,
    _PickedDocument document,
    int maxBytes,
  ) : _reader = _CacheReader(owner, document, maxBytes);

  final _CacheReader _reader;

  @override
  String get displayName => _reader.displayName;

  @override
  int? get sizeBytes => _reader.sizeBytes;

  @override
  Future<Uint8List?> readChunk() => _guard(_reader.readChunk);

  @override
  Future<void> close() => _reader.close();

  Future<Uint8List?> _guard(Future<Uint8List?> Function() read) async {
    try {
      return await read();
    } on AndroidDocumentException catch (error) {
      throw _sftpError(error, _reader.sizeBytes, _reader.maxBytes);
    }
  }
}

final class _SftpSink implements SftpDocumentSink {
  _SftpSink(AndroidSystemDocuments owner, String uri)
    : _writer = _CacheWriter(owner, uri);

  final _CacheWriter _writer;

  @override
  Future<void> addChunk(Uint8List bytes) async {
    try {
      await _writer.addChunk(bytes);
    } on AndroidDocumentException catch (error) {
      throw _sftpError(error, null);
    }
  }

  @override
  Future<void> close() async {
    try {
      await _writer.close();
    } on AndroidDocumentException catch (error) {
      throw _sftpError(error, null);
    }
  }

  @override
  Future<void> abort() => _writer.abort();
}

Object _sftpError(
  AndroidDocumentException error,
  int? observed, [
  int? maxBytes,
]) {
  if (error.code == AndroidDocumentException.cancelled) {
    return const SftpTransferCancelledException();
  }
  if (error.code == AndroidDocumentException.tooLarge) {
    final limit = maxBytes ?? 0;
    return SftpFileSizeLimitException(
      observedBytes: observed != null && observed > limit
          ? observed
          : limit + 1,
      maxBytes: limit,
    );
  }
  if (error.code == AndroidDocumentException.missing ||
      error.code == AndroidDocumentException.denied) {
    return const SftpDocumentMissingException();
  }
  return SftpDocumentIoException(error.code);
}

final class _LanSource implements LanDocumentSource {
  _LanSource(
    AndroidSystemDocuments owner,
    _PickedDocument document,
    int maxBytes,
  ) : _reader = _CacheReader(owner, document, maxBytes);

  final _CacheReader _reader;

  @override
  String get displayName => _reader.displayName;

  @override
  int? get sizeBytes => _reader.sizeBytes;

  @override
  Future<Uint8List?> readChunk() async {
    try {
      return await _reader.readChunk();
    } on AndroidDocumentException catch (error) {
      throw _lanError(error);
    }
  }

  @override
  Future<void> close() => _reader.close();
}

final class _LanSink implements LanDocumentSink {
  _LanSink(AndroidSystemDocuments owner, String uri)
    : _writer = _CacheWriter(owner, uri);

  final _CacheWriter _writer;

  @override
  Future<void> addChunk(Uint8List bytes) async {
    try {
      await _writer.addChunk(bytes);
    } on AndroidDocumentException catch (error) {
      throw _lanError(error);
    }
  }

  @override
  Future<void> close() async {
    try {
      await _writer.close();
    } on AndroidDocumentException catch (error) {
      throw _lanError(error);
    }
  }

  @override
  Future<void> abort() => _writer.abort();
}

LanDocumentTransferException _lanError(AndroidDocumentException error) {
  if (error.code == AndroidDocumentException.cancelled) {
    return const LanDocumentTransferException(
      NetworkErrorCode.cancelled,
      'Document transfer cancelled.',
    );
  }
  if (error.code == AndroidDocumentException.tooLarge) {
    return const LanDocumentTransferException(
      NetworkErrorCode.resourceLimit,
      'Document is larger than the send limit.',
    );
  }
  return const LanDocumentTransferException(
    NetworkErrorCode.ioError,
    'Document could not be read.',
  );
}
