part of 'app_log_service.dart';

/// AppLogService 的磁盘输出适配层。
///
/// 磁盘写入使用串行队列和固定数量的轮转文件；写入或轮转失败会被
/// 吞掉，避免日志系统在异常路径中递归产生日志或阻塞业务操作。
extension AppLogServiceDiskSink on AppLogService {
  Future<void> _writeToDisk(String logLine) async {
    if (kReleaseMode && !writeDiskLogsInRelease) return;
    _diskInitialization ??= _initializeDiskWriter();
    await _diskInitialization;
    _diskWriter?.maxBytes = logSizeLimit;
    _diskWriter?.write(logLine);
  }

  Future<void> _initializeDiskWriter() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      _diskWriter = RotatingLogWriter(
        File(p.join(supportDir.path, AppLogService._logFileName)),
        maxBytes: logSizeLimit,
        rotations: AppLogService._logRotationCount,
      );
    } catch (_) {
      // Existing text output remains best effort; structured output has health.
    }
  }

  Future<void> _flushDiskWrites() async {
    await _diskInitialization;
    await _diskWriter?.pendingWrites;
  }

  /// 对日志正文进行统一脱敏。
  String _redact(String value) => _redactor.sanitizeText(value);

  /// 从错误堆栈或当前调用堆栈提取可读来源位置。
  String? _sourceLocation(StackTrace? errorStackTrace) {
    return _sourceFromStack(errorStackTrace) ??
        _sourceFromStack(StackTrace.current);
  }

  String? _sourceFromStack(StackTrace? stackTrace) {
    if (stackTrace == null) return null;
    final lines = stackTrace.toString().split('\n');
    for (final line in lines) {
      if (line.contains('app_log_service.dart')) continue;
      final packageMatch = RegExp(
        r'\((package:ssh_mobile/[^:]+\.dart):(\d+):(\d+)\)',
      ).firstMatch(line);
      if (packageMatch != null) {
        return '${packageMatch.group(1)}:${packageMatch.group(2)}';
      }
      final fileMatch = RegExp(
        r'\((file:///.*?/lib/[^:]+\.dart):(\d+):(\d+)\)',
      ).firstMatch(line.replaceAll('\\', '/'));
      if (fileMatch != null) {
        return '${fileMatch.group(1)}:${fileMatch.group(2)}';
      }
    }
    return null;
  }
}
