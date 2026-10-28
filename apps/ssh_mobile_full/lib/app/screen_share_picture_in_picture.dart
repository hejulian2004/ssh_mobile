import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Aspect of the remote frame. The platform clamps it to Android's PiP range.
final class AppPictureInPictureSession {
  const AppPictureInPictureSession({required this.width, required this.height});

  final double width;
  final double height;
}

/// Activity-scoped picture-in-picture control. One page binds it at a time.
abstract interface class AppPictureInPicturePlatform {
  Future<void> setSession(AppPictureInPictureSession? session);
  void bind(void Function(bool active) onModeChanged);
  void unbind();
}

final class MethodChannelAppPictureInPicture
    implements AppPictureInPicturePlatform {
  MethodChannelAppPictureInPicture({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('ssh_mobile/screen_share_pip');

  final MethodChannel _channel;
  void Function(bool active)? _listener;

  @override
  Future<void> setSession(AppPictureInPictureSession? session) {
    return _channel.invokeMethod<void>(
      'setSession',
      session == null
          ? null
          : <String, double>{'width': session.width, 'height': session.height},
    );
  }

  @override
  void bind(void Function(bool active) onModeChanged) {
    _listener = onModeChanged;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onModeChanged') {
        _listener?.call(call.arguments == true);
      }
    });
  }

  @override
  void unbind() {
    _listener = null;
    _channel.setMethodCallHandler(null);
  }
}

/// Publishes the latest eligible frame and mirrors the system PiP window.
final class AppScreenSharePictureInPicture extends ChangeNotifier {
  AppScreenSharePictureInPicture({required this.platform}) {
    platform.bind(_onMode);
  }

  final AppPictureInPicturePlatform platform;
  bool _active = false;
  bool _disposed = false;
  bool _unsupported = false;
  bool _hasApplied = false;
  AppPictureInPictureSession? _desired;
  AppPictureInPictureSession? _applied;
  AppPictureInPictureSession? _failed;
  Future<void>? _work;

  bool get active => _active;

  void update(AppPictureInPictureSession? session) {
    if (_disposed || _unsupported) return;
    _desired = session;
    if (_work == null && _matches(session)) return;
    _schedule();
  }

  void _onMode(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    notifyListeners();
  }

  bool _matches(AppPictureInPictureSession? session) =>
      _hasApplied && _same(session, _applied);

  Future<void> _schedule() {
    final existing = _work;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _work = completion.future;
    unawaited(
      _apply().whenComplete(() {
        _work = null;
        final pending =
            !_disposed &&
            !_unsupported &&
            !_matches(_desired) &&
            !_same(_desired, _failed);
        if (pending) unawaited(_schedule());
        completion.complete();
      }),
    );
    return completion.future;
  }

  Future<void> _apply() async {
    while (!_unsupported) {
      final target = _desired;
      try {
        await platform.setSession(target);
        _applied = target;
        _hasApplied = true;
        _failed = null;
      } on MissingPluginException {
        _unsupported = true;
        return;
      } catch (_) {
        _failed = target;
        return;
      }
      if (_same(target, _desired)) return;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _desired = null;
    final clear = _work != null || (_hasApplied && _applied != null);
    if (!_unsupported && clear) {
      unawaited(_schedule().whenComplete(platform.unbind));
    } else {
      platform.unbind();
    }
    super.dispose();
  }
}

bool _same(AppPictureInPictureSession? a, AppPictureInPictureSession? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.width == b.width && a.height == b.height;
}
