import 'package:realtime_media_android/realtime_media_android.dart';

import 'screen_share_annotation_binding.dart';

/// Android sender adapter. A denied overlay does not fail the share.
final class AndroidScreenShareGuidanceDisplay
    implements ScreenShareGuidanceDisplay {
  const AndroidScreenShareGuidanceDisplay(this._overlay);

  final AndroidGuidanceOverlay _overlay;

  @override
  Future<bool> present(ScreenShareGuidanceFrame frame) => _overlay.present(
    AndroidGuidanceSnapshot(
      width: frame.width,
      height: frame.height,
      pointerX: frame.pointer?.x,
      pointerY: frame.pointer?.y,
      strokes: [
        for (final stroke in frame.strokes)
          AndroidGuidanceStroke(
            color: stroke.color.index + 1,
            width: stroke.width,
            points: [
              for (final point in stroke.points) ...<int>[point.x, point.y],
            ],
          ),
      ],
    ),
  );

  @override
  Future<void> hide() => _overlay.hide();
}
