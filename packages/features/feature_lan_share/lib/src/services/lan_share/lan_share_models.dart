import 'dart:convert';

import 'package:network_sdk/network_sdk.dart';

export 'lan_peer_presentation.dart';

class LanRecallRequest {
  final String senderDeviceId;
  final String messageId;

  const LanRecallRequest({
    required this.senderDeviceId,
    required this.messageId,
  });
}

/// Payload type for LAN transfers
enum LanPayloadType {
  text,
  image,
  video,
  audio,
  file,
  directory,
  clipboard,
  sftpRelay;

  String toJson() => name;

  static LanPayloadType fromJson(String value) {
    return LanPayloadType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => LanPayloadType.file,
    );
  }
}

/// Classifies an attachment into a stable [LanPayloadType] (image, video, audio, or file).
LanPayloadType classifyAttachment({
  required String fileName,
  String? mimeType,
}) {
  if (mimeType != null && mimeType.isNotEmpty) {
    final lower = mimeType.toLowerCase();
    if (lower.startsWith('image/')) return LanPayloadType.image;
    if (lower.startsWith('video/')) return LanPayloadType.video;
    if (lower.startsWith('audio/')) return LanPayloadType.audio;
  }
  final dotIndex = fileName.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex == fileName.length - 1) {
    return LanPayloadType.file;
  }
  final ext = fileName.substring(dotIndex + 1).toLowerCase();
  const imageExts = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'svg',
    'ico',
  };
  const videoExts = {
    'mp4',
    'mkv',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    '3gp',
  };
  const audioExts = {'mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a', 'wma', 'opus'};

  if (imageExts.contains(ext)) return LanPayloadType.image;
  if (videoExts.contains(ext)) return LanPayloadType.video;
  if (audioExts.contains(ext)) return LanPayloadType.audio;
  return LanPayloadType.file;
}

/// Predicate determining whether a network error during transfer/approval is retryable.
bool isRetryableNetworkError(NetworkErrorCode code) => switch (code) {
  NetworkErrorCode.ioError ||
  NetworkErrorCode.timeout ||
  NetworkErrorCode.quicError ||
  NetworkErrorCode.pathLost ||
  NetworkErrorCode.peerOffline ||
  NetworkErrorCode.noRoute => true,
  _ => false,
};

/// 本机发出的图片、视频、音频或文件已经失败或取消。
bool showsOutgoingFileFailure(LanMessage message) {
  if (message.isIncoming || message.isRecalled) return false;
  if (message.status != LanTransferStatus.failed &&
      message.status != LanTransferStatus.cancelled) {
    return false;
  }
  return switch (message.payloadType) {
    LanPayloadType.image ||
    LanPayloadType.video ||
    LanPayloadType.audio ||
    LanPayloadType.file => true,
    _ => false,
  };
}

/// 失败原因可重试，或历史里没有可识别的原因，并且源文件仍在。
bool canRetryOutgoingLanFile(LanMessage message, {required bool sourceExists}) {
  if (!showsOutgoingFileFailure(message) || !sourceExists) return false;
  final reason = message.failureReason;
  if (reason == null || reason.isEmpty) return true;
  for (final code in NetworkErrorCode.values) {
    if (code.name == reason) return isRetryableNetworkError(code);
  }
  return true;
}

/// Transfer status state
enum LanTransferStatus {
  pending,
  connecting,
  transferring,
  completed,
  failed,
  cancelled,
  recalled;

  String toJson() => name;

  static LanTransferStatus fromJson(String value) {
    return LanTransferStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => LanTransferStatus.pending,
    );
  }
}

/// Entry item within a multi-file or directory manifest
class FileManifestEntry {
  final String relativePath;
  final int size;
  final String? sha256;

  const FileManifestEntry({
    required this.relativePath,
    required this.size,
    this.sha256,
  });

  Map<String, dynamic> toJson() => {
    'relativePath': relativePath,
    'size': size,
    'sha256': sha256,
  };

  factory FileManifestEntry.fromJson(Map<String, dynamic> json) {
    return FileManifestEntry(
      relativePath: json['relativePath'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: json['sha256'] as String?,
    );
  }
}

/// Directory or multi-file payload manifest
class FileManifest {
  final int totalFiles;
  final int totalSize;
  final List<FileManifestEntry> entries;

  const FileManifest({
    required this.totalFiles,
    required this.totalSize,
    required this.entries,
  });

  Map<String, dynamic> toJson() => {
    'totalFiles': totalFiles,
    'totalSize': totalSize,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  factory FileManifest.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'] as List<dynamic>? ?? [];
    return FileManifest(
      totalFiles: (json['totalFiles'] as num?)?.toInt() ?? 0,
      totalSize: (json['totalSize'] as num?)?.toInt() ?? 0,
      entries: rawEntries
          .map((e) => FileManifestEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  String encodeJson() => jsonEncode(toJson());

  factory FileManifest.decodeJson(String source) {
    return FileManifest.fromJson(jsonDecode(source) as Map<String, dynamic>);
  }
}

/// Transfer record / message model
class LanMessage {
  final String id;
  final String senderId;
  final String senderAlias;
  final String receiverId;
  final LanPayloadType payloadType;
  final String? textContent;
  final String? fileName;
  final int fileSize;
  final String? localPath;
  final FileManifest? manifest;
  final LanTransferStatus status;
  final NetworkRouteType? routeType;
  final int bytesTransferred;
  final DateTime createdAt;
  final bool isIncoming;
  final bool isRecalled;
  final String? sftpServerId;
  final String? sftpRemotePath;
  final String? failureReason;

  const LanMessage({
    required this.id,
    required this.senderId,
    required this.senderAlias,
    required this.receiverId,
    required this.payloadType,
    this.textContent,
    this.fileName,
    this.fileSize = 0,
    this.localPath,
    this.manifest,
    this.status = LanTransferStatus.pending,
    this.routeType,
    this.bytesTransferred = 0,
    required this.createdAt,
    required this.isIncoming,
    this.isRecalled = false,
    this.sftpServerId,
    this.sftpRemotePath,
    this.failureReason,
  });

  double get progress =>
      fileSize > 0 ? (bytesTransferred / fileSize).clamp(0.0, 1.0) : 0.0;

  /// 页面是否展示这条消息的传输路径。
  bool get showsTransportRoute =>
      routeType == NetworkRouteType.quicDirect ||
      routeType == NetworkRouteType.relay;

  /// 这条消息是否走中继。
  bool get usesRelayRoute => routeType == NetworkRouteType.relay;

  /// 历史列表使用的路径后缀；没有可展示路径时为空。
  String transportRouteSuffix({
    required String directLabel,
    required String relayLabel,
  }) {
    final label = switch (routeType) {
      NetworkRouteType.quicDirect => directLabel,
      NetworkRouteType.relay => relayLabel,
      _ => null,
    };
    return label == null ? '' : ' · $label';
  }

  LanMessage copyWith({
    String? id,
    String? senderId,
    String? senderAlias,
    String? receiverId,
    LanPayloadType? payloadType,
    String? textContent,
    String? fileName,
    int? fileSize,
    String? localPath,
    FileManifest? manifest,
    LanTransferStatus? status,
    NetworkRouteType? routeType,
    int? bytesTransferred,
    DateTime? createdAt,
    bool? isIncoming,
    bool? isRecalled,
    String? sftpServerId,
    String? sftpRemotePath,
    String? failureReason,
  }) {
    return LanMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderAlias: senderAlias ?? this.senderAlias,
      receiverId: receiverId ?? this.receiverId,
      payloadType: payloadType ?? this.payloadType,
      textContent: textContent ?? this.textContent,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      localPath: localPath ?? this.localPath,
      manifest: manifest ?? this.manifest,
      status: status ?? this.status,
      routeType: routeType ?? this.routeType,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      createdAt: createdAt ?? this.createdAt,
      isIncoming: isIncoming ?? this.isIncoming,
      isRecalled: isRecalled ?? this.isRecalled,
      sftpServerId: sftpServerId ?? this.sftpServerId,
      sftpRemotePath: sftpRemotePath ?? this.sftpRemotePath,
      failureReason: failureReason ?? this.failureReason,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'senderAlias': senderAlias,
    'receiverId': receiverId,
    'payloadType': payloadType.toJson(),
    'textContent': textContent,
    'fileName': fileName,
    'fileSize': fileSize,
    'localPath': localPath,
    'manifest': manifest?.toJson(),
    'status': status.toJson(),
    'routeType': routeType?.name,
    'bytesTransferred': bytesTransferred,
    'createdAt': createdAt.toIso8601String(),
    'isIncoming': isIncoming,
    'isRecalled': isRecalled,
    'sftpServerId': sftpServerId,
    'sftpRemotePath': sftpRemotePath,
    'failureReason': failureReason,
  };

  factory LanMessage.fromJson(Map<String, dynamic> json) {
    return LanMessage(
      id: json['id'] as String? ?? '',
      senderId: json['senderId'] as String? ?? '',
      senderAlias: json['senderAlias'] as String? ?? '',
      receiverId: json['receiverId'] as String? ?? '',
      payloadType: LanPayloadType.fromJson(
        json['payloadType'] as String? ?? '',
      ),
      textContent: json['textContent'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      localPath: json['localPath'] as String?,
      manifest: json['manifest'] != null
          ? FileManifest.fromJson(json['manifest'] as Map<String, dynamic>)
          : null,
      status: LanTransferStatus.fromJson(json['status'] as String? ?? ''),
      routeType: networkRouteTypeFromJson(json['routeType'] as String?),
      bytesTransferred: (json['bytesTransferred'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      isIncoming: json['isIncoming'] as bool? ?? false,
      isRecalled: json['isRecalled'] as bool? ?? false,
      sftpServerId: json['sftpServerId'] as String?,
      sftpRemotePath: json['sftpRemotePath'] as String?,
      failureReason: json['failureReason'] as String?,
    );
  }
}

NetworkRouteType? networkRouteTypeFromJson(String? value) {
  if (value == null || value.isEmpty) return null;
  for (final route in NetworkRouteType.values) {
    if (route.name == value) return route;
  }
  return null;
}
