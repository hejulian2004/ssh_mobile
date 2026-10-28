import 'package:flutter/services.dart';

/// Normalized capture-frame marks. Coordinates stay out of logs.
final class AndroidGuidanceStroke {
  const AndroidGuidanceStroke({
    required this.color,
    required this.width,
    required this.points,
  });

  final int color;
  final int width;
  final List<int> points;
}

/// A path snapshot for the Android guidance window.
final class AndroidGuidanceSnapshot {
  const AndroidGuidanceSnapshot({
    required this.width,
    required this.height,
    required this.strokes,
    this.pointerX,
    this.pointerY,
  });

  final int width;
  final int height;
  final List<AndroidGuidanceStroke> strokes;
  final int? pointerX;
  final int? pointerY;
}

/// Full-screen guidance window. `false` means the other device cannot show marks.
abstract interface class AndroidGuidanceOverlay {
  Future<bool> present(AndroidGuidanceSnapshot snapshot);
  Future<void> hide();
}

/// Method-channel owner for the Android guidance window.
final class MethodChannelAndroidGuidanceOverlay
    implements AndroidGuidanceOverlay {
  const MethodChannelAndroidGuidanceOverlay({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'ssh_mobile/realtime_media/android';
  final MethodChannel _channel;

  @override
  Future<bool> present(AndroidGuidanceSnapshot snapshot) async {
    try {
      final shown = await _channel.invokeMethod<bool>(
        'presentGuidanceOverlay',
        <String, Object?>{
          'width': snapshot.width,
          'height': snapshot.height,
          'pointer_x': snapshot.pointerX,
          'pointer_y': snapshot.pointerY,
          'strokes': [
            for (final stroke in snapshot.strokes)
              <String, Object?>{
                'color': stroke.color,
                'width': stroke.width,
                'points': stroke.points,
              },
          ],
        },
      );
      return shown ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> hide() async {
    try {
      await _channel.invokeMethod<void>('hideGuidanceOverlay');
    } on PlatformException {
      // A missing window must not end the share.
    } on MissingPluginException {
      // The Windows test host has no Android plugin.
    }
  }
}
