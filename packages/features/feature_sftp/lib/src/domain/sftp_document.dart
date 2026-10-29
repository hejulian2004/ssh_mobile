// 系统文档的读取和写入契约。
//
// Feature 不导入 Android。App Shell 在 Android 上注入 [SftpDocumentAccessPort]，
// 把用户选中的单个文档交给上传和下载；其它平台继续使用文件路径选择器。

import 'dart:typed_data';

/// Destination approved before opening the system picker.
/// Rebinding a connection or navigating during the picker/copy invalidates it.
typedef SftpDocumentUploadTarget = ({
  String connectionId,
  String targetFingerprint,
  String directory,
});

/// 用户取消选择时端口返回 null，不改变授权，也不开始传输。
abstract interface class SftpDocumentAccessPort {
  /// Android 系统文档界面为 true。其它平台保持路径选择器。
  bool get usesSystemDocuments;

  /// 打开一个已有文档。只授予该文档的读取权限。
  Future<SftpDocumentSource?> openForRead({required int maxBytes});

  /// 创建一个保存目标。只授予该文档的写入权限。
  Future<SftpDocumentSink?> createForWrite({required String suggestedName});
}

/// 以有界分块读取一个文档，不把整个文件装进一个字节数组。
abstract interface class SftpDocumentSource {
  String get displayName;

  /// 文档声明的长度。未知时为 null，调用方必须在读取过程中继续计数字节。
  int? get sizeBytes;

  /// 下一块字节。null 表示已经读完。
  Future<Uint8List?> readChunk();

  Future<void> close();
}

/// 以有界分块写入一个文档。
abstract interface class SftpDocumentSink {
  Future<void> addChunk(Uint8List bytes);

  /// 全部分块都写入之后才提交。
  Future<void> close();

  /// 放弃本次写入，不把部分内容当成成功。
  Future<void> abort();
}

/// 文档不存在、授权缺失或已被收回。
final class SftpDocumentMissingException implements Exception {
  const SftpDocumentMissingException();
}

/// 读取或写入文档时发生 I/O 错误。
final class SftpDocumentIoException implements Exception {
  const SftpDocumentIoException(this.cause);

  final Object cause;

  @override
  String toString() => 'SftpDocumentIoException: document_io';
}
