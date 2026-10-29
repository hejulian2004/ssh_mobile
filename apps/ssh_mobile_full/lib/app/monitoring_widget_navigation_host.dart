import 'dart:async';

import 'package:android_server_widgets/android_server_widgets.dart';
import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'navigation/app_route_contributions.dart';

/// App route owner for cold/warm widget clicks. Intent data is only a hint;
/// navigation waits for startup and resolves the current public directory.
class MonitoringWidgetNavigationHost extends StatefulWidget {
  const MonitoringWidgetNavigationHost({
    super.key,
    required this.repository,
    required this.navigatorKey,
    required this.ready,
    required this.child,
    this.navigation,
    this.diagnostic,
  });

  final ConnectionRepository repository;
  final GlobalKey<NavigatorState> navigatorKey;
  final ValueListenable<bool> ready;
  final Widget child;
  final MonitoringWidgetNavigationPort? navigation;
  final VoidCallback? diagnostic;

  @override
  State<MonitoringWidgetNavigationHost> createState() =>
      _MonitoringWidgetNavigationHostState();
}

class _MonitoringWidgetNavigationHostState
    extends State<MonitoringWidgetNavigationHost> {
  MonitoringWidgetNavigationPort? _port;
  final Set<String> _seen = {};
  MonitoringWidgetOpenRequest? _pending;
  bool _scheduled = false;
  bool _active = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    widget.ready.addListener(_schedule);
    final port = widget.navigation ?? MonitoringWidgetNavigationChannel();
    _port = port;
    unawaited(
      port.start(_receive).catchError((Object _) {
        if (mounted) widget.diagnostic?.call();
      }),
    );
  }

  void _receive(MonitoringWidgetOpenRequest request) {
    if (!mounted || !_seen.add(request.requestId)) return;
    if (_seen.length > 32) _seen.remove(_seen.first);
    _generation++;
    _pending = request;
    _schedule();
  }

  void _schedule() {
    if (!mounted ||
        !widget.ready.value ||
        _scheduled ||
        _active ||
        _pending == null) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_openPending());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _openPending() async {
    if (_active || !widget.ready.value) return;
    _active = true;
    try {
      while (mounted && widget.ready.value && _pending != null) {
        final request = _pending!;
        _pending = null;
        final generation = _generation;
        try {
          await widget.repository.initialize();
          if (!mounted || generation != _generation) continue;
          final navigator = widget.navigatorKey.currentState;
          final target = widget.repository.getConnection(request.connectionId);
          if (target == null) {
            navigator?.popUntil((route) => route.isFirst);
          } else if (navigator != null) {
            unawaited(
              navigator.pushNamed(
                AppShellRouteNames.monitoringDetails,
                arguments: target.id,
              ),
            );
          }
        } catch (_) {
          if (mounted && generation == _generation) widget.diagnostic?.call();
        }
      }
    } finally {
      _active = false;
      _schedule();
    }
  }

  @override
  void dispose() {
    _generation++;
    _pending = null;
    widget.ready.removeListener(_schedule);
    final port = _port;
    _port = null;
    if (port != null) unawaited(port.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
