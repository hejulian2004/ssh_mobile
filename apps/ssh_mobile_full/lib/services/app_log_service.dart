import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:app_core/app_core.dart' as app_core;
import 'package:app_diagnostics/app_diagnostics.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log_database.dart' as db;
import 'app_settings.dart';

part 'app_log_models.dart';
part 'app_log_store.dart';
part 'app_log_disk_sink.dart';

/// App Scope 的日志适配器，负责兼容现有 UI、数据库和平台错误入口。
///
/// Core 的 [app_core.AppLogger] 只规定日志契约和作用域；本类继续拥有
/// Flutter 错误拦截、脱敏、Drift 绑定、磁盘轮转和 ChangeNotifier 通知。
/// 旧的 [instance] 仅作为迁移期间的兼容入口，AppRuntime 是正式 Owner。
class AppLogService extends ChangeNotifier implements app_core.AppLogger {
  /// 迁移期间供旧调用点使用的兼容实例。
  static final AppLogService instance = AppLogService._();

  /// 兼容旧代码的构造入口；新的生产代码应通过 AppRuntime 注入。
  factory AppLogService() => instance;

  /// 保持现有日志页面和数据库的内存窗口大小不变。
  static const int _maxEntries = 1000;

  /// 默认磁盘日志大小上限。
  static const int defaultLogSizeLimit = 5 * 1024 * 1024;

  /// 磁盘日志文件名。
  static const String _logFileName = 'app.log';

  /// 保留的轮转文件数量。
  static const int _logRotationCount = 3;

  final app_core.LogBuffer<AppLogEntry> _entries =
      app_core.LogBuffer<AppLogEntry>(maxEntries: _maxEntries);
  db.AppLogDatabase? _database;
  db.AppLogDatabase? _bindingDatabase;
  ListQueue<_DatabaseLogMutation>? _databaseBindingMutations;
  Future<void>? _databaseBindingFuture;
  List<AppLogEntry>? _cachedNewestFirstEntries;
  Map<AppLogLevel, int>? _cachedLevelCounts;
  Map<AppLogLevel, List<AppLogEntry>>? _cachedEntriesByLevel;
  Set<int>? _cachedEntryIds;
  DebugPrintCallback? _previousDebugPrint;
  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousPlatformError;
  DebugPrintCallback? _installedDebugPrint;
  FlutterExceptionHandler? _installedFlutterError;
  bool Function(Object, StackTrace)? _installedPlatformError;
  final List<app_core.LogSink> _sinks = <app_core.LogSink>[];
  bool _installed = false;
  bool _notifyScheduled = false;
  Timer? _notifyTimer;
  int _nextEntryId = 1;
  RotatingLogWriter? _diskWriter;
  Future<void>? _diskInitialization;
  final List<app_core.LogSink> _localSinks = [];
  Future<void> _databaseOperationTail = Future<void>.value();
  int _activeDbWrites = 0;
  Completer<void>? _dbWriteCompleter;
  Object? _pendingDbWriteError;
  StackTrace? _pendingDbWriteStackTrace;

  /// 当前磁盘日志大小上限，可由测试或平台配置调整。
  int logSizeLimit = defaultLogSizeLimit;

  /// Release 模式是否允许写入磁盘日志。
  bool writeDiskLogsInRelease = false;

  /// App diagnostics share Core's public redaction boundary. Keeping this
  /// dependency in App Scope avoids importing a Feature security policy into
  /// the app log/database owner.
  final app_core.TelemetryRedactor _redactor =
      const app_core.TelemetryRedactor();

  /// 返回磁盘写入队列排空的 Future。
  @visibleForTesting
  Future<void> get pendingWrites {
    return _flushDiskWrites();
  }

  /// 返回数据库写入队列排空的 Future。
  @visibleForTesting
  Future<void> get pendingDbWrites {
    if (_activeDbWrites == 0) {
      final error = _pendingDbWriteError;
      if (error != null) {
        final stackTrace = _pendingDbWriteStackTrace ?? StackTrace.current;
        _pendingDbWriteError = null;
        _pendingDbWriteStackTrace = null;
        return Future<void>.error(error, stackTrace);
      }
      return Future.value();
    }
    return (_dbWriteCompleter ??= Completer<void>()).future;
  }

  /// 清除磁盘文件句柄，仅供测试在切换临时目录时使用。
  @visibleForTesting
  void resetLogFileForTesting() {
    _diskWriter = null;
    _diskInitialization = null;
  }

  /// 重置数据库绑定状态，仅供数据库测试隔离场景使用。
  @visibleForTesting
  void resetDatabaseForTesting() {
    assert(_activeDbWrites == 0);
    _database = null;
    _bindingDatabase = null;
    _databaseBindingMutations = null;
    _databaseBindingFuture = null;
    _databaseOperationTail = Future<void>.value();
    _pendingDbWriteError = null;
    _pendingDbWriteStackTrace = null;
    if (_entries.isEmpty) {
      _nextEntryId = 1;
    }
  }

  AppLogService._();

  /// 按最新到最旧的顺序返回不可变日志快照。
  List<AppLogEntry> get entries {
    return _cachedNewestFirstEntries ??= _entries.newestFirst;
  }

  /// 当前 App 日志数据库是否已经完成绑定。
  bool get databaseOpen => _database != null;

  /// 当前由日志通知合并器持有的活动 Timer 数量。
  int get activeTimerCount => _notifyTimer == null ? 0 : 1;

  /// 返回各级别的条数缓存。
  Map<AppLogLevel, int> get levelCounts {
    final cached = _cachedLevelCounts;
    if (cached != null) return cached;
    final counts = {for (final level in AppLogLevel.values) level: 0};
    counts[AppLogLevel.all] = _entries.length;
    for (final entry in _entries) {
      final level = entry.normalizedLevel;
      counts[level] = (counts[level] ?? 0) + 1;
    }
    return _cachedLevelCounts = Map.unmodifiable(counts);
  }

  /// 返回指定级别的不可变日志快照。
  List<AppLogEntry> entriesForLevel(AppLogLevel level) {
    if (level == AppLogLevel.all) return entries;
    final cached = _cachedEntriesByLevel;
    if (cached != null && cached.containsKey(level)) {
      return cached[level]!;
    }
    final map = Map<AppLogLevel, List<AppLogEntry>>.of(cached ?? const {});
    map[level] = List.unmodifiable(
      entries.where((entry) => entry.normalizedLevel == level),
    );
    _cachedEntriesByLevel = map;
    return map[level]!;
  }

  /// 返回当前内存日志的 ID 快照。
  Set<int> get entryIds {
    return _cachedEntryIds ??= Set.unmodifiable(
      entries.map((entry) => entry.id),
    );
  }

  /// 安装 Flutter 错误入口和 debugPrint 桥接。
  void install() {
    if (_installed) return;
    _installed = true;
    _previousDebugPrint ??= debugPrint;
    // ignore: prefer_function_declarations_over_variables
    final debugPrintHandler = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        add('debug', message, captureSource: false);
      }
      _previousDebugPrint?.call(message, wrapWidth: wrapWidth);
    };
    _installedDebugPrint = debugPrintHandler;
    debugPrint = debugPrintHandler;

    _previousFlutterError = FlutterError.onError;
    // ignore: prefer_function_declarations_over_variables
    final flutterErrorHandler = (FlutterErrorDetails details) {
      // 保留完整诊断树，避免 RenderFlex 等错误只显示简短摘要。
      add(
        'flutter',
        details.exceptionAsString(),
        stackTrace: details.stack,
        details: details.toString(),
      );
      _previousFlutterError?.call(details);
    };
    _installedFlutterError = flutterErrorHandler;
    FlutterError.onError = flutterErrorHandler;

    _previousPlatformError = PlatformDispatcher.instance.onError;
    // ignore: prefer_function_declarations_over_variables
    final platformErrorHandler = (Object error, StackTrace stack) {
      add('platform', error.toString(), stackTrace: stack);
      return _previousPlatformError?.call(error, stack) ?? false;
    };
    _installedPlatformError = platformErrorHandler;
    PlatformDispatcher.instance.onError = platformErrorHandler;

    add('app', 'Log service started');
  }

  /// Adds an independently-owned structured output sink.
  ///
  /// Sinks receive only Core [app_core.LogRecord] calls. Legacy [add] calls
  /// remain local, so attaching a telemetry sink can never turn all app logs
  /// into upload candidates.
  void addSink(app_core.LogSink sink) {
    if (_sinks.contains(sink)) return;
    _sinks.add(sink);
  }

  /// Removes a previously attached sink without closing it.
  ///
  /// The caller that created the sink remains its lifecycle owner.
  void removeSink(app_core.LogSink sink) {
    _sinks.remove(sink);
  }

  /// Transfers ownership of a local-only sink. Legacy logs never reach the
  /// separately registered telemetry sinks.
  void addLocalSink(app_core.LogSink sink) {
    if (!_localSinks.contains(sink)) _localSinks.add(sink);
  }

  /// Drains owned local sinks before App Scope releases the logger.
  Future<void> closeLocalSinks() async {
    final sinks = List<app_core.LogSink>.of(_localSinks);
    _localSinks.clear();
    Object? firstError;
    StackTrace? firstStack;
    for (final sink in sinks) {
      try {
        await sink.close();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    await pendingWrites;
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }

  /// 写入普通信息日志。
  void info(String message, {String? details}) {
    add('info', message, details: details);
  }

  /// 写入警告日志。
  void warning(String message, {String? details}) {
    add('warning', message, details: details);
  }

  /// 写入错误日志，并保留错误对象和堆栈。
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    add(
      'error',
      error == null ? message : '$message: $error',
      stackTrace: stackTrace,
      details: details,
    );
  }

  /// 将 Core 日志记录适配到现有 AppLogEntry 存储模型。
  @override
  void log(app_core.LogRecord record) {
    for (final sink in List<app_core.LogSink>.of(_sinks)) {
      try {
        sink.write(record);
      } catch (_) {
        // A diagnostic sink must not affect the business logger or operation.
      }
    }
    final source = record.source;
    final hasSource = source?.isNotEmpty == true;
    _add(
      _legacyLevelName(record.level),
      record.error == null
          ? record.message
          : '${record.message}: ${record.error}',
      stackTrace: record.stackTrace,
      details: record.details,
      captureSource: !hasSource,
      sourceLocation: hasSource ? source : null,
      structuredRecord: record,
    );
  }

  /// 创建不拥有底层 AppLogService 的作用域 Logger。
  @override
  app_core.AppLogger scope(String name) {
    return app_core.ScopedLogger(this, name);
  }

  /// 清除惰性查询缓存。
  void _invalidateCaches() {
    _cachedNewestFirstEntries = null;
    _cachedLevelCounts = null;
    _cachedEntriesByLevel = null;
    _cachedEntryIds = null;
  }

  /// 合并 160ms 内的通知，避免高频诊断日志触发逐条重建 UI。
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    _notifyTimer = Timer(const Duration(milliseconds: 160), () {
      _notifyTimer = null;
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  /// 将 Core 严重级别映射到现有日志数据库支持的名称。
  static String _legacyLevelName(app_core.LogLevel level) {
    switch (level) {
      case app_core.LogLevel.trace:
      case app_core.LogLevel.debug:
        return 'debug';
      case app_core.LogLevel.info:
        return 'info';
      case app_core.LogLevel.warning:
        return 'warning';
      case app_core.LogLevel.error:
        return 'error';
    }
  }

  /// 取消 UI 通知 Timer；数据库和磁盘资源由其各自队列完成释放。
  @override
  void dispose() {
    if (_installed) {
      if (identical(debugPrint, _installedDebugPrint)) {
        debugPrint = _previousDebugPrint ?? debugPrint;
      }
      if (identical(FlutterError.onError, _installedFlutterError)) {
        FlutterError.onError = _previousFlutterError;
      }
      if (identical(
        PlatformDispatcher.instance.onError,
        _installedPlatformError,
      )) {
        PlatformDispatcher.instance.onError = _previousPlatformError;
      }
      _installed = false;
      _installedDebugPrint = null;
      _installedFlutterError = null;
      _installedPlatformError = null;
      _previousDebugPrint = null;
      _previousFlutterError = null;
      _previousPlatformError = null;
    }
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _notifyScheduled = false;
    super.dispose();
  }
}
