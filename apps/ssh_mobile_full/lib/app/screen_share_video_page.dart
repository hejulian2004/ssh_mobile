import 'dart:async';

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screen_share_picture_in_picture.dart';
import 'window_fullscreen_controller.dart';

/// Presentation-only state; the caller keeps its media and session leases.
final class AppScreenShareVideoPage extends StatefulWidget {
  const AppScreenShareVideoPage({
    required this.video,
    required this.videoSize,
    required this.controls,
    this.enableViewerControls = true,
    this.autoEnterFullscreen = false,
    this.onStop,
    this.annotation,
    this.allowPictureInPicture = false,
    this.pictureInPicturePlatform,
    this.windowPlatform = const MethodChannelAppWindowPresentation(),
    super.key,
  });

  final Widget video;
  final ValueListenable<Size?> videoSize;
  final Widget controls;
  final bool enableViewerControls;
  final bool autoEnterFullscreen;
  final VoidCallback? onStop;
  final ScreenShareAnnotationSession? annotation;
  final bool allowPictureInPicture;
  final AppPictureInPicturePlatform? pictureInPicturePlatform;
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
  bool _defaultFullscreenRequested = false;
  bool _presented = true;
  bool _painting = false;
  ScreenShareAnnotationTool _tool = ScreenShareAnnotationTool.pen;
  ScreenShareAnnotationColor _color = ScreenShareAnnotationColor.red;
  late final AppScreenSharePictureInPicture _pip;

  @override
  void initState() {
    super.initState();
    _window.addListener(_windowChanged);
    _pip = AppScreenSharePictureInPicture(
      platform:
          widget.pictureInPicturePlatform ?? MethodChannelAppPictureInPicture(),
    );
    _pip.addListener(_pipChanged);
    widget.videoSize.addListener(_onVideoSize);
    _syncPictureInPicture();
    _enterDefaultFullscreen();
  }

  void _windowChanged() => setState(() {});

  void _pipChanged() => setState(() {});

  void _onVideoSize() => _syncPictureInPicture();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final presented = ModalRoute.isCurrentOf(context) != false;
    if (presented == _presented) return;
    _presented = presented;
    if (_presented) _pip.claim();
    _syncPictureInPicture();
  }

  @override
  void dispose() {
    widget.videoSize.removeListener(_onVideoSize);
    _pip.removeListener(_pipChanged);
    _pip.dispose();
    _window.removeListener(_windowChanged);
    _window.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppScreenShareVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoSize != widget.videoSize) {
      oldWidget.videoSize.removeListener(_onVideoSize);
      widget.videoSize.addListener(_onVideoSize);
    }
    if (oldWidget.enableViewerControls && !widget.enableViewerControls) {
      unawaited(_window.setFullscreen(false));
    }
    _enterDefaultFullscreen();
    _syncPictureInPicture();
  }

  void _enterDefaultFullscreen() {
    if (_defaultFullscreenRequested ||
        !widget.autoEnterFullscreen ||
        !widget.enableViewerControls) {
      return;
    }
    _defaultFullscreenRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.autoEnterFullscreen &&
          widget.enableViewerControls) {
        unawaited(_window.setFullscreen(true));
      }
    });
  }

  void _exitFullscreen() {
    if (_window.needsRestore || _window.busy) {
      unawaited(_window.setFullscreen(false));
    }
  }

  void _syncPictureInPicture() {
    if (!_presented) {
      _pip.update(null);
      return;
    }
    final size = widget.videoSize.value;
    final valid =
        widget.allowPictureInPicture &&
        size != null &&
        size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0;
    if (!valid) {
      _pip.update(null);
      return;
    }
    final odd = _quarterTurns.isOdd;
    _pip.update(
      AppPictureInPictureSession(
        width: odd ? size.height : size.width,
        height: odd ? size.width : size.height,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final compact = _pip.active;
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
            backgroundColor: _fullscreen || compact
                ? Colors.black
                : Colors.transparent,
            appBar: _fullscreen || compact
                ? null
                : AppBar(title: Text(chinese ? '屏幕共享' : 'Screen sharing')),
            body: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.all(
                          _fullscreen || compact ? 0 : 16,
                        ),
                        child: ValueListenableBuilder<Size?>(
                          valueListenable: widget.videoSize,
                          builder: (context, size, _) {
                            final annotation = widget.annotation;
                            final rotated = RotatedBox(
                              quarterTurns: _quarterTurns,
                              child: annotation == null
                                  ? widget.video
                                  : Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        widget.video,
                                        if (!compact)
                                          ScreenShareAnnotationCanvas(
                                            session: annotation,
                                            painting: _painting,
                                            tool: _tool,
                                            color: _color,
                                          ),
                                      ],
                                    ),
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
                    if (!_fullscreen && !compact)
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: widget.controls,
                        ),
                      ),
                  ],
                ),
                if (!compact && _window.failure != null)
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
                if (!compact &&
                    widget.annotation != null &&
                    widget.enableViewerControls)
                  Positioned(
                    top: 16,
                    left: 16,
                    child: SafeArea(
                      child: ScreenShareAnnotationToolbar(
                        session: widget.annotation!,
                        painting: _painting,
                        tool: _tool,
                        color: _color,
                        onPainting: (value) =>
                            setState(() => _painting = value),
                        onTool: (value) => setState(() => _tool = value),
                        onColor: (value) => setState(() => _color = value),
                      ),
                    ),
                  ),
                if (!compact && widget.enableViewerControls)
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
                              onPressed: () => setState(() {
                                _quarterTurns = (_quarterTurns + 1) % 4;
                                _syncPictureInPicture();
                              }),
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
