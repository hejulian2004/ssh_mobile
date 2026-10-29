import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Aspect of the remote frame. The platform clamps it to Android's PiP range.
final class AppPictureInPictureSession {
  const AppPictureInPictureSession({required this.width, required this.height});

  final double width;
  final double height;
}

/// Activity-scoped picture-in-picture control.
///
/// The shared channel has one current owner. A later page replaces that owner;
/// an older page's clear or unbind cannot remove it.
abstract interface class AppPictureInPicturePlatform {
  /// False when this page is not the current owner and the call was not sent.
  Future<bool> setSession(AppPictureInPictureSession? session);

  /// Null when this page lost the channel before the activity answered.
  Future<bool?> currentMode();
  bool get holds;
  void bind(void Function(bool active) onModeChanged);

  /// Binds only when nobody owns the channel. A live newer owner stays in place.
  bool reclaimIfVacant(void Function(bool active) onModeChanged);
  void unbind();
}

final class MethodChannelAppPictureInPicture
    implements AppPictureInPicturePlatform {
  MethodChannelAppPictureInPicture({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('ssh_mobile/screen_share_pip');

  final MethodChannel _channel;
  int? _generation;

  static final Map<String, _PictureInPictureChannelLease> _leases =
      <String, _PictureInPictureChannelLease>{};

  _PictureInPictureChannelLease get _lease => _leases.putIfAbsent(
    _channel.name,
    () => _PictureInPictureChannelLease(_channel),
  );

  @override
  bool get holds {
    final generation = _generation;
    return generation != null && _lease.holds(generation);
  }

  @override
  Future<bool> setSession(AppPictureInPictureSession? session) {
    if (!holds) return Future<bool>.value(false);
    return _channel
        .invokeMethod<void>(
          'setSession',
          session == null
              ? null
              : <String, double>{
                  'width': session.width,
                  'height': session.height,
                },
        )
        .then((_) => true);
  }

  @override
  Future<bool?> currentMode() {
    final generation = _generation;
    if (generation == null || !_lease.holds(generation)) {
      return Future<bool?>.value(null);
    }
    return _channel.invokeMethod<bool>('currentMode').then((active) {
      if (_generation != generation || !_lease.holds(generation)) return null;
      return active == true;
    });
  }

  @override
  void bind(void Function(bool active) onModeChanged) {
    _generation = _lease.bind(onModeChanged);
  }

  @override
  bool reclaimIfVacant(void Function(bool active) onModeChanged) {
    if (holds) return true;
    if (!_lease.vacant) return false;
    bind(onModeChanged);
    return true;
  }

  @override
  void unbind() {
    final generation = _generation;
    _generation = null;
    if (generation != null) _lease.unbind(generation);
  }
}

/// One generation owns the platform channel. Stale owners cannot publish.
final class _PictureInPictureChannelLease {
  _PictureInPictureChannelLease(this._channel);

  final MethodChannel _channel;
  int _generation = 0;
  int? _owner;

  int bind(void Function(bool active) onModeChanged) {
    final generation = ++_generation;
    _owner = generation;
    _channel.setMethodCallHandler((call) async {
      if (_owner != generation) return;
      if (call.method == 'onModeChanged') {
        onModeChanged(call.arguments == true);
      }
    });
    return generation;
  }

  bool holds(int generation) => _owner == generation;

  bool get vacant => _owner == null;

  void unbind(int generation) {
    if (_owner != generation) return;
    _owner = null;
    _channel.setMethodCallHandler(null);
  }
}

/// Publishes the latest eligible frame and mirrors the system PiP window.
final class AppScreenSharePictureInPicture extends ChangeNotifier {
  AppScreenSharePictureInPicture({required this.platform}) {
    platform.bind(_onMode);
    _readMode();
  }

  final AppPictureInPicturePlatform platform;
  bool _active = false;
  int _modeEpoch = 0;
  int _readSerial = 0;
  int _publishEpoch = 0;
  bool _disposed = false;
  bool _unsupported = false;
  bool _hasApplied = false;
  AppPictureInPictureSession? _desired;
  AppPictureInPictureSession? _applied;
  AppPictureInPictureSession? _failed;
  AppPictureInPictureSession? _rejected;
  Future<void>? _work;

  bool get active => _active;

  /// Binds this page as the presented owner and publishes its frame again.
  void claim() {
    if (_disposed || _unsupported) return;
    platform.bind(_onMode);
    _dropPublication();
    _failed = null;
    _readMode();
  }

  void update(AppPictureInPictureSession? session) {
    if (_disposed || _unsupported) return;
    _desired = session;
    if (!platform.holds) {
      if (platform.reclaimIfVacant(_onMode)) {
        _dropPublication();
        _readMode();
      } else if (_work == null && _same(session, _rejected)) {
        return;
      }
    }
    if (_work == null && platform.holds && _matches(session)) return;
    _schedule();
  }

  void _readMode() {
    if (_disposed || _unsupported) return;
    final serial = ++_readSerial;
    final epoch = _modeEpoch;
    unawaited(_applyMode(serial, epoch));
  }

  Future<void> _applyMode(int serial, int epoch) async {
    final bool? active;
    try {
      active = await platform.currentMode();
    } on MissingPluginException {
      return;
    } catch (_) {
      return;
    }
    if (active == null ||
        _disposed ||
        _unsupported ||
        serial != _readSerial ||
        epoch != _modeEpoch) {
      return;
    }
    _setActive(active);
  }

  void _onMode(bool active) {
    _modeEpoch++;
    _setActive(active);
  }

  void _setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    notifyListeners();
  }

  /// Forgets a publish that started before this page became the owner again.
  void _dropPublication() {
    _publishEpoch++;
    _hasApplied = false;
    _applied = null;
    _rejected = null;
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
            platform.holds &&
            !_matches(_desired) &&
            !_same(_desired, _failed) &&
            !_same(_desired, _rejected);
        if (pending) unawaited(_schedule());
        completion.complete();
      }),
    );
    return completion.future;
  }

  Future<void> _apply() async {
    while (!_unsupported) {
      final target = _desired;
      final epoch = _publishEpoch;
      try {
        final delivered = await platform.setSession(target);
        if (epoch != _publishEpoch) {
          if (platform.holds) continue;
          return;
        }
        if (!platform.holds || !delivered) {
          _rejected = target;
          _hasApplied = false;
          return;
        }
        _applied = target;
        _hasApplied = true;
        _failed = null;
        _rejected = null;
      } on MissingPluginException {
        if (epoch != _publishEpoch) return;
        _unsupported = true;
        return;
      } catch (_) {
        if (epoch != _publishEpoch) {
          if (platform.holds) continue;
          return;
        }
        if (!platform.holds) return;
        _failed = target;
        return;
      }
      if (epoch != _publishEpoch) continue;
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
