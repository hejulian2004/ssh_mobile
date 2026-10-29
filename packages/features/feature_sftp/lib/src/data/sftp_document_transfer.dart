// 把文档分块复制到本应用临时文件，或从临时文件分块写入文档。
//
// 远程上传和下载仍使用现有的路径 API。这里的临时文件只服务这一次尝试。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../domain/sftp_document.dart';
import '../domain/sftp_models.dart';

/// SFTP 文档传输使用的分块复制。
abstract final class SftpDocumentTransfer {
  static const int chunkBytes = 16 * 1024;

  /// 在 [directory] 中保留一个空的临时文件。
  static Future<File> reserve(Directory directory) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final spill = File(
      p.join(directory.path, 'sftp-doc-${const Uuid().v4()}.part'),
    );
    return spill.create(exclusive: true);
  }

  /// 把 [source] 完整写入一个临时文件。
  ///
  /// 声明长度或累计长度超过 [maxBytes] 时抛出 [SftpFileSizeLimitException]，
  /// 并且不留下临时文件。取消和读取失败同样删除已写出的部分。
  static Future<File> copySource({
    required SftpDocumentSource source,
    required Directory directory,
    required int maxBytes,
    required bool Function() isCancelled,
    void Function(int bytes)? onProgress,
  }) async {
    final declared = source.sizeBytes;
    if (declared != null && declared > maxBytes) {
      throw SftpFileSizeLimitException(
        observedBytes: declared,
        maxBytes: maxBytes,
      );
    }
    final spill = await reserve(directory);
    RandomAccessFile? handle;
    var committed = false;
    try {
      handle = await spill.open(mode: FileMode.write);
      var total = 0;
      while (true) {
        if (isCancelled()) throw const SftpTransferCancelledException();
        final chunk = await source.readChunk();
        if (isCancelled()) throw const SftpTransferCancelledException();
        if (chunk == null) break;
        if (chunk.isEmpty) continue;
        total += chunk.length;
        if (total > maxBytes) {
          throw SftpFileSizeLimitException(
            observedBytes: total,
            maxBytes: maxBytes,
          );
        }
        await handle.writeFrom(chunk);
        onProgress?.call(total);
      }
      await handle.flush();
      committed = true;
      return spill;
    } finally {
      try {
        await handle?.close();
      } finally {
        if (!committed && await spill.exists()) await spill.delete();
      }
    }
  }

  /// 按固定块大小把 [file] 写入 [sink]，不把整个文件读进一个字节数组。
  static Future<void> copyFileToSink({
    required File file,
    required SftpDocumentSink sink,
    required bool Function() isCancelled,
    void Function(int bytes)? onProgress,
  }) async {
    final handle = await file.open();
    try {
      final buffer = Uint8List(chunkBytes);
      var total = 0;
      while (true) {
        if (isCancelled()) throw const SftpTransferCancelledException();
        final count = await handle.readInto(buffer);
        if (count == 0) break;
        await sink.addChunk(Uint8List.fromList(buffer.sublist(0, count)));
        total += count;
        onProgress?.call(total);
        if (isCancelled()) throw const SftpTransferCancelledException();
      }
    } finally {
      await handle.close();
    }
  }
}
