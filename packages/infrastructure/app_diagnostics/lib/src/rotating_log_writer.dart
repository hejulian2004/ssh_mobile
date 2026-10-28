import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Observable local output health; diagnostic failure never throws into callers.
final class LogWriterHealth {
  int written = 0;
  int dropped = 0;
  int failed = 0;
  bool closed = false;

  Map<String, Object> toJson() => {
    'written': written,
    'dropped': dropped,
    'failed': failed,
    'closed': closed,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  };
}

/// Shared serial file writer for existing text logs and structured diagnostics.
/// The creator must await [close] before releasing its output directory.
final class RotatingLogWriter {
  RotatingLogWriter(
    this.file, {
    this.maxBytes = 5 * 1024 * 1024,
    this.rotations = 3,
    this.maxQueuedEntries = 2048,
    this.maxQueuedBytes = 4 * 1024 * 1024,
    this.onIdle,
  }) {
    if (maxBytes < 1 ||
        rotations < 0 ||
        maxQueuedEntries < 1 ||
        maxQueuedBytes < 1) {
      throw ArgumentError('Diagnostic writer limits must be positive');
    }
  }

  final File file;
  int maxBytes;
  final int rotations;
  final int maxQueuedEntries;
  final int maxQueuedBytes;
  final Future<void> Function(LogWriterHealth)? onIdle;
  final health = LogWriterHealth();
  final _queue = ListQueue<List<int>>();
  int _queuedBytes = 0;
  Future<void>? _draining;
  Future<void>? _closing;

  void write(String line) {
    if (health.closed) return;
    final bytes = utf8.encode('$line\n');
    if (_queue.length >= maxQueuedEntries ||
        bytes.length > 65536 ||
        _queuedBytes + bytes.length > maxQueuedBytes) {
      health.dropped++;
      return;
    }
    _queue.add(bytes);
    _queuedBytes += bytes.length;
    _draining ??= Future<void>.microtask(_drain);
  }

  Future<void> get pendingWrites async {
    while (_draining != null) {
      await _draining;
    }
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        final bytes = _queue.removeFirst();
        _queuedBytes -= bytes.length;
        try {
          await file.parent.create(recursive: true);
          if (await file.exists() &&
              await file.length() + bytes.length > maxBytes) {
            await _rotate();
          }
          await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
          health.written++;
        } on Object {
          health.failed++;
        }
      }
      try {
        await onIdle?.call(health);
      } on Object {
        health.failed++;
      }
    } finally {
      _draining = null;
      if (_queue.isNotEmpty) _draining = Future<void>.microtask(_drain);
    }
  }

  Future<void> _rotate() async {
    final oldest = File('${file.path}.$rotations');
    if (rotations == 0) {
      await file.delete();
      return;
    }
    if (await oldest.exists()) await oldest.delete();
    for (var index = rotations - 1; index >= 1; index--) {
      final source = File('${file.path}.$index');
      if (await source.exists())
        await source.rename('${file.path}.${index + 1}');
    }
    await file.rename('${file.path}.1');
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    health.closed = true;
    await pendingWrites;
    try {
      await onIdle?.call(health);
    } on Object {
      health.failed++;
    }
  }
}
