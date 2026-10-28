import 'dart:async';

import 'package:flutter/widgets.dart';

import 'notification_policy.dart';
import 'system_notification_center.dart';

/// Presents redacted system notifications for one app composition root.
final class SystemNotificationPresenter {
  SystemNotificationPresenter(this._center);

  final AppNotificationCenter _center;

  Future<bool> present(AppNotificationRequest request) {
    return _center.present(request);
  }
}

/// Initializes one notification center and delivers at most one click at a time.
class SystemNotificationScope extends StatefulWidget {
  const SystemNotificationScope({
    super.key,
    required this.identity,
    required this.onActivate,
    required this.child,
    this.center,
    this.diagnostic,
  });

  final AppNotificationIdentity identity;
  final Future<void> Function(AppNotificationPayload payload) onActivate;
  final Widget child;
  final AppNotificationCenter? center;
  final AppNotificationDiagnostic? diagnostic;

  static SystemNotificationPresenter? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<_SystemNotificationPresenter>()
        ?.presenter;
  }

  @override
  State<SystemNotificationScope> createState() =>
      _SystemNotificationScopeState();
}

class _SystemNotificationScopeState extends State<SystemNotificationScope>
    with WidgetsBindingObserver {
  late final AppNotificationCenter _center =
      widget.center ?? AppNotificationCenter.shared;
  late final SystemNotificationPresenter _presenter =
      SystemNotificationPresenter(_center);
  late final void Function() _handleLaunch = _consumeLaunch;
  var _activating = false;

  @override
  void initState() {
    super.initState();
    if (widget.diagnostic != null) _center.onDiagnostic = widget.diagnostic;
    _center.onLaunchReady = _handleLaunch;
    final current = WidgetsBinding.instance.lifecycleState;
    if (current != null) {
      _center.visibility = visibilityForLifecycle(current);
    }
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    await _center.ensureInitialized(identity: widget.identity);
    if (!mounted) return;
    _center.markNavigationReady();
  }

  void _consumeLaunch() {
    if (_activating) return;
    final payload = _center.takeLaunch();
    if (payload == null) return;
    _activating = true;
    unawaited(_activate(payload));
  }

  Future<void> _activate(AppNotificationPayload payload) async {
    try {
      await widget.onActivate(payload);
    } catch (error) {
      _center.onDiagnostic?.call(
        'notification activation failed: ${error.runtimeType}',
      );
    } finally {
      _activating = false;
      if (mounted) _consumeLaunch();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _center.visibility = visibilityForLifecycle(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(_center.onLaunchReady, _handleLaunch)) {
      _center.onLaunchReady = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SystemNotificationPresenter(
      presenter: _presenter,
      child: widget.child,
    );
  }
}

class _SystemNotificationPresenter extends InheritedWidget {
  const _SystemNotificationPresenter({
    required this.presenter,
    required super.child,
  });

  final SystemNotificationPresenter presenter;

  @override
  bool updateShouldNotify(_SystemNotificationPresenter oldWidget) {
    return presenter != oldWidget.presenter;
  }
}
