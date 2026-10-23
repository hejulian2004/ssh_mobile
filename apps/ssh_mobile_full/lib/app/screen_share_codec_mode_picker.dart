import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:realtime_media/realtime_media.dart';

/// Codec policy is internal; the user selects only the capture source.
final class AppScreenShareSourcePicker extends StatelessWidget {
  const AppScreenShareSourcePicker({
    required this.options,
    required this.onSelected,
    super.key,
  });

  final List<ScreenShareSourceOption> options;
  final void Function(ScreenShareSourceOption, RealtimeMediaCodecMode)
  onSelected;

  @override
  Widget build(BuildContext context) => ScreenShareSourcePicker(
    options: options,
    onSelected: (source) =>
        onSelected(source, RealtimeMediaCodecMode.automatic),
  );
}
