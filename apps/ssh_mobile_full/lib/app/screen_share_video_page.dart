import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'window_fullscreen_controller.dart';

/// Presentation-only state; the caller keeps its media and session leases.
final class AppScreenShareVideoPage extends StatefulWidget {
  const AppScreenShareVideoPage({
    required this.video,
    required this.videoSize,
    required this.controls,
    this.enableViewerControls = true,
    this.onStop,
    this.windowPlatform = const MethodChannelAppWindowPresentation(),
    super.key,
  });

  final Widget video;
  final ValueListenable<Size?> videoSize;
  final Widget controls;
  final bool enableViewerControls;
  final VoidCallback? onStop;
  final AppWindowPresentationPlatform windowPlatform;

  @override
  State<AppScreenShareVideoPage> createState() => _VideoPageState();
}

final class _VideoPageState extends State<AppScreenShareVideoPage> {
  late final _window = AppWindowFullscreenController(
    platform: widget.windowPlatform,
  );
  bool get _fullscreen => _window.fullscreen;
  int _quarterTurns = 0;

  @override
  void initState() {
    super.initState();
    _window.addListener(_windowChanged);
  }

  void _windowChanged() => setState(() {});

  @override
  void dispose() {
    _window.removeListener(_windowChanged);
    _window.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppScreenShareVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enableViewerControls && !widget.enableViewerControls) {
      unawaited(_window.setFullscreen(false));
    }
  }

  void _exitFullscreen() {
    if (_window.needsRestore || _window.busy) {
      unawaited(_window.setFullscreen(false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return PopScope(
      canPop: !_window.needsRestore && !_window.busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitFullscreen();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _exitFullscreen,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: _fullscreen ? Colors.black : Colors.transparent,
            appBar: _fullscreen
                ? null
                : AppBar(title: Text(chinese ? '屏幕共享' : 'Screen sharing')),
            body: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.all(_fullscreen ? 0 : 16),
                        child: ValueListenableBuilder<Size?>(
                          valueListenable: widget.videoSize,
                          builder: (context, size, _) {
                            final rotated = RotatedBox(
                              quarterTurns: _quarterTurns,
                              child: widget.video,
                            );
                            final validSize =
                                size != null &&
                                size.width.isFinite &&
                                size.height.isFinite &&
                                size.width > 0 &&
                                size.height > 0;
                            return ColoredBox(
                              color: Colors.black,
                              child: Center(
                                child: validSize
                                    ? AspectRatio(
                                        aspectRatio: _quarterTurns.isOdd
                                            ? size.height / size.width
                                            : size.width / size.height,
                                        child: rotated,
                                      )
                                    : rotated,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    if (!_fullscreen)
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: widget.controls,
                        ),
                      ),
                  ],
                ),
                if (_window.failure != null)
                  Positioned(
                    bottom: 16,
                    left: 16,
                    right: 16,
                    child: SafeArea(
                      child: Material(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  chinese
                                      ? '无法切换或恢复系统全屏。'
                                      : 'Unable to change or restore fullscreen.',
                                ),
                              ),
                              if (_window.needsRestore)
                                TextButton(
                                  onPressed: _window.busy
                                      ? null
                                      : _exitFullscreen,
                                  child: Text(
                                    chinese ? '重试恢复' : 'Retry restore',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.enableViewerControls)
                  Positioned(
                    top: 16,
                    right: 16,
                    child: SafeArea(
                      child: Material(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: chinese ? '旋转画面' : 'Rotate view',
                              color: Colors.white,
                              icon: const Icon(Icons.rotate_right),
                              onPressed: () => setState(
                                () => _quarterTurns = (_quarterTurns + 1) % 4,
                              ),
                            ),
                            IconButton(
                              tooltip: _fullscreen
                                  ? (chinese ? '退出全屏' : 'Exit fullscreen')
                                  : (chinese ? '全屏查看' : 'Enter fullscreen'),
                              color: Colors.white,
                              icon: Icon(
                                _fullscreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                              ),
                              onPressed: _window.busy
                                  ? null
                                  : () => unawaited(
                                      _window.setFullscreen(
                                        !_window.needsRestore,
                                      ),
                                    ),
                            ),
                            if (_fullscreen && widget.onStop != null)
                              IconButton(
                                tooltip: chinese
                                    ? '停止屏幕共享'
                                    : 'Stop screen share',
                                color: Colors.white,
                                icon: const Icon(Icons.stop_circle_outlined),
                                onPressed: widget.onStop,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
