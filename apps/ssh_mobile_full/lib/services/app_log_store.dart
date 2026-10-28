part of 'app_log_service.dart';

/// AppLogService 的数据库和内存变更适配层。
///
/// 该扩展与 AppLogService 处于同一 library，可以访问其私有状态；把
/// 数据库绑定、顺序写入和临时 ID 映射从主 facade 拆出，但不改变原有
/// 事务顺序或错误传播行为。
extension AppLogServiceDatabaseStore on AppLogService {
  /// 将当前内存日志绑定到 [database]，并按顺序回放待处理变更。
  Future<void> setDatabase(
    db.AppLogDatabase database, {
    @visibleForTesting Future<void> Function()? bindingCheckpoint,
  }) {
    if (identical(_database, database) && _bindingDatabase == null) {
      return pendingDbWrites;
    }

    final activeBinding = _databaseBindingFuture;
    if (activeBinding != null) {
      if (identical(_bindingDatabase, database)) {
        return activeBinding;
      }
      return Future<void>.error(
        StateError('AppLogService is already binding another database'),
      );
    }

    if (_database != null) {
      return Future<void>.error(
        StateError('AppLogService is already bound to another database'),
      );
    }

    final pendingMutations = ListQueue<_DatabaseLogMutation>.from(
      _entries.map(_AddDatabaseLogMutation.new),
    );
    _bindingDatabase = database;
    _databaseBindingMutations = pendingMutations;

    late final Future<void> bindingFuture;
    bindingFuture =
        _runDatabaseBinding(
          database,
          pendingMutations,
          bindingCheckpoint: bindingCheckpoint,
        ).whenComplete(() {
          if (identical(_databaseBindingFuture, bindingFuture)) {
            _databaseBindingFuture = null;
          }
        });
    _databaseBindingFuture = bindingFuture;
    return bindingFuture;
  }

  /// 停止向 [database] 写入，并等待已经排队的变更完成。
  ///
  /// 解绑先同步切断新日志与旧数据库的联系，再等待队列排空，避免
  /// 关闭数据库时仍有异步写入持有连接。
  Future<void> detachDatabase(db.AppLogDatabase database) async {
    final activeBinding = _databaseBindingFuture;
    if (activeBinding != null && identical(_bindingDatabase, database)) {
      await activeBinding;
    }

    if (!identical(_database, database)) {
      return;
    }

    final persistedEntries = Set<AppLogEntry>.identity()..addAll(_entries);

    // 解绑必须发生在第一次 await 之前，解绑期间产生的日志只能进入内存
    // 和磁盘，不能再追加到正在排空的旧数据库队列。
    _database = null;
    await _queueDatabaseOperation(() async {}, operation: 'detach database');
    await pendingDbWrites;

    _entries.removeWhere(persistedEntries.contains);
    _invalidateCaches();
    _scheduleNotify();
  }

  Future<void> _runDatabaseBinding(
    db.AppLogDatabase database,
    ListQueue<_DatabaseLogMutation> pendingMutations, {
    Future<void> Function()? bindingCheckpoint,
  }) async {
    try {
      await _queueDatabaseOperation(
        () => _completeDatabaseBinding(
          database,
          pendingMutations,
          bindingCheckpoint: bindingCheckpoint,
        ),
        operation: 'bind database',
      );
    } catch (_) {
      if (identical(_bindingDatabase, database)) {
        _bindingDatabase = null;
        _databaseBindingMutations = null;
      }
      rethrow;
    }
  }

  Future<void> _completeDatabaseBinding(
    db.AppLogDatabase database,
    ListQueue<_DatabaseLogMutation> pendingMutations, {
    Future<void> Function()? bindingCheckpoint,
  }) async {
    var records = await database.appLogDao.getAllLogs();
    var maxId = records.isEmpty ? 0 : records.last.id;

    await bindingCheckpoint?.call();
    await database.appLogDao.pruneOldLogs();

    final assignedIdsByTemporaryId = <int, List<int>>{};
    while (true) {
      while (pendingMutations.isNotEmpty) {
        final mutation = pendingMutations.removeFirst();
        switch (mutation) {
          case _AddDatabaseLogMutation(:final entry):
            final storedEntry = _copyEntryWithId(entry, ++maxId);
            await database.appLogDao.insertLog(_toDatabaseRecord(storedEntry));
            await database.appLogDao.pruneOldLogs();
            assignedIdsByTemporaryId
                .putIfAbsent(entry.id, () => <int>[])
                .add(storedEntry.id);
          case _DeleteDatabaseLogMutation(
            :final databaseIds,
            :final temporaryIds,
          ):
            final resolvedDatabaseIds = <int>{...databaseIds};
            for (final id in temporaryIds) {
              final assignedIds = assignedIdsByTemporaryId.remove(id);
              if (assignedIds != null) {
                resolvedDatabaseIds.addAll(assignedIds);
              }
            }
            if (resolvedDatabaseIds.isNotEmpty) {
              await database.appLogDao.deleteLogs(resolvedDatabaseIds);
            }
          case _ClearDatabaseLogMutation():
            await database.appLogDao.clearAllLogs();
            assignedIdsByTemporaryId.clear();
        }
      }

      records = await database.appLogDao.getAllLogs();
      if (pendingMutations.isNotEmpty) {
        continue;
      }

      _entries
        ..clear()
        ..addAll(records.map(_fromDatabaseRecord));

      _nextEntryId = records.isEmpty ? 1 : records.last.id + 1;
      _database = database;
      _bindingDatabase = null;
      _databaseBindingMutations = null;
      _invalidateCaches();
      _scheduleNotify();
      return;
    }
  }

  Future<void> _writeEntryToDb(
    db.AppLogDatabase database,
    AppLogEntry entry,
  ) async {
    await database.appLogDao.insertLog(_toDatabaseRecord(entry));
    await database.appLogDao.pruneOldLogs();
  }

  Future<T> _queueDatabaseOperation<T>(
    Future<T> Function() action, {
    required String operation,
  }) {
    _activeDbWrites++;
    final result = _databaseOperationTail.then((_) => action());
    _databaseOperationTail = result
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            _pendingDbWriteError ??= error;
            _pendingDbWriteStackTrace ??= stackTrace;
            _reportDatabaseFailure(operation, error, stackTrace);
          },
        )
        .whenComplete(_finishDatabaseOperation);
    return result;
  }

  void _finishDatabaseOperation() {
    _activeDbWrites--;
    if (_activeDbWrites != 0) {
      return;
    }

    final completer = _dbWriteCompleter;
    if (completer == null) {
      return;
    }
    _dbWriteCompleter = null;

    final error = _pendingDbWriteError;
    if (error == null) {
      completer.complete();
      return;
    }

    final stackTrace = _pendingDbWriteStackTrace ?? StackTrace.current;
    _pendingDbWriteError = null;
    _pendingDbWriteStackTrace = null;
    completer.completeError(error, stackTrace);
  }

  void _reportDatabaseFailure(
    String operation,
    Object error,
    StackTrace stackTrace,
  ) {
    final safeError = _redact(error.toString());
    final safeStackTrace =
        _redactor.sanitizeStackTrace(stackTrace.toString()) ??
        app_core.TelemetryRedactor.redacted;
    final printer = _previousDebugPrint ?? debugPrint;
    printer('App log database $operation failed: $safeError\n$safeStackTrace');
  }

  db.AppLogRecordsCompanion _toDatabaseRecord(AppLogEntry entry) {
    return db.AppLogRecordsCompanion(
      id: drift.Value(entry.id),
      time: drift.Value(entry.time.millisecondsSinceEpoch),
      level: drift.Value(entry.level),
      message: drift.Value(entry.message),
      sourceLocation: drift.Value(entry.sourceLocation),
      stackTrace: drift.Value(entry.stackTrace),
      details: drift.Value(entry.details),
    );
  }

  AppLogEntry _fromDatabaseRecord(db.AppLogRecord record) {
    return AppLogEntry(
      id: record.id,
      time: DateTime.fromMillisecondsSinceEpoch(
        record.time,
        isUtc: true,
      ).toLocal(),
      level: record.level,
      message: record.message,
      sourceLocation: record.sourceLocation,
      stackTrace: record.stackTrace,
      details: record.details,
    );
  }

  AppLogEntry _copyEntryWithId(AppLogEntry entry, int id) {
    return AppLogEntry(
      id: id,
      time: entry.time,
      level: entry.level,
      message: entry.message,
      sourceLocation: entry.sourceLocation,
      stackTrace: entry.stackTrace,
      details: entry.details,
    );
  }

  /// 添加日志到有界内存缓冲，并异步转发到磁盘和数据库。
  void add(
    String level,
    String message, {
    StackTrace? stackTrace,
    String? details,
    bool captureSource = true,
    String? sourceLocation,
  }) => _add(
    level,
    message,
    stackTrace: stackTrace,
    details: details,
    captureSource: captureSource,
    sourceLocation: sourceLocation,
  );

  void _add(
    String level,
    String message, {
    StackTrace? stackTrace,
    String? details,
    bool captureSource = true,
    String? sourceLocation,
    app_core.LogRecord? structuredRecord,
  }) {
    final safeMessage = _redact(message);
    final safeDetails = details == null ? null : _redact(details);
    final safeStackTrace = stackTrace == null
        ? null
        : _redact(stackTrace.toString());
    final entry = AppLogEntry(
      id: _nextEntryId++,
      time: DateTime.now(),
      level: level,
      message: safeMessage,
      sourceLocation:
          sourceLocation ??
          (captureSource ? _sourceLocation(stackTrace) : null),
      stackTrace: safeStackTrace,
      details: safeDetails,
    );
    _entries.add(entry);
    _invalidateCaches();
    _scheduleNotify();

    // Only the local stream receives legacy records. Structured records retain
    // their timestamp/correlation and are emitted once, before legacy projection.
    final diagnostic =
        structuredRecord ??
        app_core.LogRecord(
          timestamp: entry.time,
          level: switch (AppLogLevel.fromName(level)) {
            AppLogLevel.error ||
            AppLogLevel.flutter ||
            AppLogLevel.platform => app_core.LogLevel.error,
            AppLogLevel.warning => app_core.LogLevel.warning,
            AppLogLevel.debug => app_core.LogLevel.debug,
            _ => app_core.LogLevel.info,
          },
          message: safeMessage,
          source: sourceLocation,
          details: safeDetails,
          stackTrace: safeStackTrace == null
              ? null
              : StackTrace.fromString(safeStackTrace),
        );
    for (final sink in List<app_core.LogSink>.of(_localSinks)) {
      try {
        sink.write(diagnostic);
      } catch (_) {
        /* Local output is best effort. */
      }
    }

    // 磁盘写入保持异步，避免日志路径阻塞 SSH、UI 或启动流程。
    unawaited(_writeToDisk(entry.text));

    // 数据库绑定期间保留严格的变更顺序，最终 ID 在绑定阶段统一分配。
    final bindingMutations = _databaseBindingMutations;
    if (bindingMutations != null) {
      bindingMutations.addLast(_AddDatabaseLogMutation(entry));
      return;
    }

    final database = _database;
    if (database != null) {
      unawaited(
        _queueDatabaseOperation(
          () => _writeEntryToDb(database, entry),
          operation: 'write log entry',
        ),
      );
    }
  }

  /// 删除内存日志，并把删除变更按当前数据库状态排队。
  void deleteEntriesById(Set<int> ids) {
    if (ids.isEmpty) return;
    final bindingMutations = _databaseBindingMutations;
    final temporaryIds = bindingMutations == null
        ? const <int>{}
        : _entries
              .where((entry) => ids.contains(entry.id))
              .map((entry) => entry.id)
              .toSet();
    _entries.removeWhere((entry) => ids.contains(entry.id));
    _invalidateCaches();
    _scheduleNotify();

    if (bindingMutations != null) {
      bindingMutations.addLast(
        _DeleteDatabaseLogMutation(
          databaseIds: ids.difference(temporaryIds),
          temporaryIds: temporaryIds,
        ),
      );
      return;
    }

    final database = _database;
    if (database != null) {
      unawaited(
        _queueDatabaseOperation(
          () => database.appLogDao.deleteLogs(ids),
          operation: 'delete log entries',
        ),
      );
    }
  }

  /// 清空内存日志，并把清空操作写入当前数据库队列。
  void clear() {
    _entries.clear();
    _invalidateCaches();
    _scheduleNotify();

    final bindingMutations = _databaseBindingMutations;
    if (bindingMutations != null) {
      bindingMutations.addLast(const _ClearDatabaseLogMutation());
      return;
    }

    final database = _database;
    if (database != null) {
      unawaited(
        _queueDatabaseOperation(
          database.appLogDao.clearAllLogs,
          operation: 'clear log entries',
        ),
      );
    }
  }
}
