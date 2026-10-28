import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'lan_system_notification.dart';

/// Subscribes to the current LAN view model and forwards notification events.
class LanNotificationBinder extends StatefulWidget {
  const LanNotificationBinder({
    super.key,
    required this.listenable,
    required this.events,
    required this.child,
  });

  final Listenable listenable;
  final Stream<LanNotificationEvent>? Function() events;
  final Widget child;

  @override
  State<LanNotificationBinder> createState() => _LanNotificationBinderState();
}

class _LanNotificationBinderState extends State<LanNotificationBinder> {
  StreamSubscription<LanNotificationEvent>? _subscription;
  Stream<LanNotificationEvent>? _current;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_bind);
    _bind();
  }

  @override
  void didUpdateWidget(LanNotificationBinder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_bind);
      widget.listenable.addListener(_bind);
      _bind();
    }
  }

  void _bind() {
    Stream<LanNotificationEvent>? stream;
    try {
      stream = widget.events();
    } on TypeError {
      stream = null;
    }
    if (identical(stream, _current)) return;
    _subscription?.cancel();
    _current = stream;
    if (stream == null) {
      _subscription = null;
      return;
    }
    _subscription = stream.listen((event) {
      if (!mounted) return;
      final port = _readNotificationPort(context);
      if (port == null) return;
      unawaited(port.present(event));
    });
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_bind);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

LanSystemNotificationPort? _readNotificationPort(BuildContext context) {
  try {
    return Provider.of<LanSystemNotificationPort>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}
