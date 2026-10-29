// 系统文档读取和写入契约。
//
// Feature 不导入 Android。App Shell 只在 Android 上注入这个端口；
// 其它平台继续使用现有的文件路径选择器。

import 'dart:typed_data';

/// 文档发送在进入现有常规文件发送之前允许复制的最大字节数。
abstract final class LanDocumentLimits {
  static const int maxSendBytes = 2 * 1024 * 1024 * 1024;
}

/// 文档操作文案不假定用户选择的是图库或 Downloads。
final class LanDocumentStrings {
  const LanDocumentStrings({required this.isEnglish});

  final bool isEnglish;

  String get saved => isEnglish ? 'File saved' : '文件已保存';
}

/// 用户取消时返回 null，不改变授权，也不开始发送。
abstract interface class LanDocumentAccessPort {
  bool get usesSystemDocuments;

  /// 打开一个已有文档，只授予该文档的读取权限。
  Future<LanDocumentSource?> openForRead({
    required String mimeType,
    required int maxBytes,
  });

  /// 创建一个保存目标，只授予该文档的写入权限。
  Future<LanDocumentSink?> createForWrite({
    required String suggestedName,
    required String mimeType,
  });
}

/// 以有界分块读取一个文档。
abstract interface class LanDocumentSource {
  String get displayName;
  int? get sizeBytes;
  Future<Uint8List?> readChunk();

  /// 幂等释放；可在 readChunk 等待期间调用，以中止底层文档 I/O。
  Future<void> close();
}

/// 以有界分块写入一个文档。
abstract interface class LanDocumentSink {
  Future<void> addChunk(Uint8List bytes);
  Future<void> close();

  /// 幂等中止；包括 addChunk 或 close 仍在等待的原生写入。
  Future<void> abort();
}
