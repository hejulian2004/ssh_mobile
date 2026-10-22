import 'package:flutter/material.dart';
import 'navigation/app_route_contributions.dart';
import 'screen_share_sessions.dart';

/// Presentation-only entry back into the App-owned operation.
final class AppScreenShareBackgroundHost extends StatefulWidget {
  const AppScreenShareBackgroundHost({
    required this.sessions,
    required this.navigatorKey,
    required this.child,
    super.key,
  });
  final AppScreenShareSessions sessions;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<AppScreenShareBackgroundHost> createState() => _BackgroundHostState();
}

final class _BackgroundHostState extends State<AppScreenShareBackgroundHost> {
  bool _opening = false;
  Future<void> _open() async {
    final operation = widget.sessions.current;
    final navigator = widget.navigatorKey.currentState;
    if (_opening ||
        operation == null ||
        operation.finished ||
        navigator == null) {
      return;
    }
    setState(() => _opening = true);
    try {
      await navigator.pushNamed(
        AppShellRouteNames.screenShare,
        arguments: operation.arguments,
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.sessions,
    builder: (context, _) {
      final operation = widget.sessions.current;
      final chinese = Localizations.localeOf(context).languageCode == 'zh';
      return Stack(
        children: [
          widget.child,
          if (operation != null &&
              !operation.finished &&
              !widget.sessions.pageVisible)
            Positioned(
              left: 16,
              right: 16,
              top: 16,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          const Icon(Icons.screen_share_outlined),
                          Text(
                            chinese ? '屏幕共享仍在进行' : 'Screen sharing is running',
                          ),
                          TextButton(
                            onPressed: _opening ? null : _open,
                            child: Text(chinese ? '打开' : 'Open screen share'),
                          ),
                          TextButton(
                            onPressed: operation.stopping
                                ? null
                                : operation.stop,
                            child: Text(chinese ? '停止' : 'Stop screen share'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
