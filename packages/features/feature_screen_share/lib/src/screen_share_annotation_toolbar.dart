import 'package:flutter/material.dart';

import 'screen_share_annotation_codec.dart';
import 'screen_share_annotation_session.dart';

/// Receiver controls for one annotation session. The bar sits outside the video.
final class ScreenShareAnnotationToolbar extends StatelessWidget {
  const ScreenShareAnnotationToolbar({
    required this.session,
    required this.painting,
    required this.tool,
    required this.color,
    required this.onPainting,
    required this.onTool,
    required this.onColor,
    super.key,
  });

  final ScreenShareAnnotationSession session;
  final bool painting;
  final ScreenShareAnnotationTool tool;
  final ScreenShareAnnotationColor color;
  final ValueChanged<bool> onPainting;
  final ValueChanged<ScreenShareAnnotationTool> onTool;
  final ValueChanged<ScreenShareAnnotationColor> onColor;

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final ready = session.canPaint;
        return Material(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: chinese ? '标注' : 'Annotate',
                      color: painting ? Colors.amber : Colors.white,
                      onPressed: ready ? () => onPainting(!painting) : null,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: chinese ? '画笔' : 'Pen',
                      color: tool == ScreenShareAnnotationTool.pen
                          ? Colors.amber
                          : Colors.white,
                      onPressed: ready && painting
                          ? () => onTool(ScreenShareAnnotationTool.pen)
                          : null,
                      icon: const Icon(Icons.gesture),
                    ),
                    IconButton(
                      tooltip: chinese ? '激光笔' : 'Laser',
                      color: tool == ScreenShareAnnotationTool.laser
                          ? Colors.amber
                          : Colors.white,
                      onPressed: ready && painting
                          ? () => onTool(ScreenShareAnnotationTool.laser)
                          : null,
                      icon: const Icon(Icons.highlight_alt),
                    ),
                    IconButton(
                      tooltip: chinese ? '撤销' : 'Undo',
                      color: Colors.white,
                      onPressed: ready && painting ? session.undo : null,
                      icon: const Icon(Icons.undo),
                    ),
                    IconButton(
                      tooltip: chinese ? '清空' : 'Clear',
                      color: Colors.white,
                      onPressed: ready && painting ? session.clear : null,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
                if (painting)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final entry in ScreenShareAnnotationColor.values)
                        IconButton(
                          tooltip: _colorLabel(entry, chinese),
                          onPressed: ready ? () => onColor(entry) : null,
                          icon: Icon(
                            entry == color
                                ? Icons.circle
                                : Icons.circle_outlined,
                            color: _swatch(entry),
                          ),
                        ),
                    ],
                  ),
                if (!ready)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    child: Text(
                      chinese ? '标注通道未就绪' : 'Annotation channel is not ready',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  )
                else if (session.remoteDisplayReady == false)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    child: Text(
                      chinese
                          ? '对方看不见标记'
                          : 'The other device cannot show marks',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _colorLabel(ScreenShareAnnotationColor color, bool chinese) =>
    switch (color) {
      ScreenShareAnnotationColor.red => chinese ? '红色' : 'Red',
      ScreenShareAnnotationColor.amber => chinese ? '黄色' : 'Amber',
      ScreenShareAnnotationColor.green => chinese ? '绿色' : 'Green',
      ScreenShareAnnotationColor.blue => chinese ? '蓝色' : 'Blue',
    };

Color _swatch(ScreenShareAnnotationColor color) => switch (color) {
  ScreenShareAnnotationColor.red => const Color(0xFFE53935),
  ScreenShareAnnotationColor.amber => const Color(0xFFFFB300),
  ScreenShareAnnotationColor.green => const Color(0xFF43A047),
  ScreenShareAnnotationColor.blue => const Color(0xFF1E88E5),
};
