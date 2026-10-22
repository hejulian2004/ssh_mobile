import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class AppWindowPresentationPlatform {
  Future<void> setFullscreen({required int leaseId, required bool enabled});
}

final class MethodChannelAppWindowPresentation
    implements AppWindowPresentationPlatform {
  const MethodChannelAppWindowPresentation();
  static const _channel = MethodChannel('ssh_mobile/window_presentation');

  @override
  Future<void> setFullscreen({
    required int leaseId,
    required bool enabled,
  }) async {
    final applied = await _channel.invokeMethod<bool>('setFullscreen', {
      'lease_id': leaseId,
      'enabled': enabled,
    });
    if (applied != true) {
      throw StateError('Window presentation was not applied.');
    }
  }
}

enum AppFullscreenFailure { enter, restore }

/// Owns one native window snapshot; rapid intent changes never overlap calls.
final class AppWindowFullscreenController extends ChangeNotifier {
  AppWindowFullscreenController({required this.platform});

  static int _nextLease = DateTime.now().microsecondsSinceEpoch;
  final AppWindowPresentationPlatform platform;
  Future<void>? _work;
  int? _lease;
  bool _desired = false;
  bool _fullscreen = false;
  bool _disposed = false;
  AppFullscreenFailure? _failure;

  bool get fullscreen => _fullscreen;
  bool get busy => _work != null;
  bool get needsRestore => _lease != null;
  AppFullscreenFailure? get failure => _failure;

  Future<void> setFullscreen(bool enabled) {
    if (_disposed) return _work ?? Future<void>.value();
    _desired = enabled;
    _failure = null;
    return _schedule();
  }

  Future<void> _schedule() {
    final existing = _work;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _work = completion.future;
    _notify();
    unawaited(
      _apply().then((_) {
        _work = null;
        _notify();
        completion.complete();
      }),
    );
    return completion.future;
  }

  Future<void> _apply() async {
    while (true) {
      if (_desired) {
        if (_lease != null) return;
        final lease = _lease = ++_nextLease;
        try {
          await platform.setFullscreen(leaseId: lease, enabled: true);
          _fullscreen = true;
        } on MissingPluginException {
          // No handler ran, so there is no native snapshot to restore.
          _lease = null;
          _failure = AppFullscreenFailure.enter;
          _desired = false;
        } catch (_) {
          _failure = AppFullscreenFailure.enter;
          _desired = false;
        }
      } else {
        final lease = _lease;
        if (lease == null) return;
        try {
          await platform.setFullscreen(leaseId: lease, enabled: false);
          _lease = null;
          _fullscreen = false;
        } catch (_) {
          _failure = AppFullscreenFailure.restore;
          return;
        }
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close() {
    dispose();
    return _work ?? Future<void>.value();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _desired = false;
    unawaited(_schedule());
    super.dispose();
  }
}
