import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:realtime_media/realtime_media.dart';

/// A local codec choice, frozen when a source or incoming offer is accepted.
final class AppScreenShareCodecModePicker extends StatelessWidget {
  const AppScreenShareCodecModePicker({
    required this.mode,
    required this.onChanged,
    super.key,
  });
  final RealtimeMediaCodecMode mode;
  final ValueChanged<RealtimeMediaCodecMode>? onChanged;
  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return SwitchListTile(
      title: Text(chinese ? 'CPU 模式' : 'CPU mode'),
      subtitle: Text(
        chinese
            ? '使用软件 H.264 编解码，适用于无硬件编解码能力的设备，CPU 占用会增加。'
            : 'Use software H.264 for devices without hardware codecs. CPU usage will increase.',
      ),
      value: mode == RealtimeMediaCodecMode.cpu,
      onChanged: onChanged == null
          ? null
          : (enabled) => onChanged!(
              enabled
                  ? RealtimeMediaCodecMode.cpu
                  : RealtimeMediaCodecMode.hardware,
            ),
    );
  }
}

/// App owns codec selection; the Feature still owns source presentation.
final class AppScreenShareSourcePicker extends StatefulWidget {
  const AppScreenShareSourcePicker({
    required this.options,
    required this.onSelected,
    super.key,
  });
  final List<ScreenShareSourceOption> options;
  final void Function(ScreenShareSourceOption, RealtimeMediaCodecMode)
  onSelected;
  @override
  State<AppScreenShareSourcePicker> createState() => _SourcePickerState();
}

final class _SourcePickerState extends State<AppScreenShareSourcePicker> {
  RealtimeMediaCodecMode _mode = RealtimeMediaCodecMode.hardware;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      AppScreenShareCodecModePicker(
        mode: _mode,
        onChanged: (mode) => setState(() => _mode = mode),
      ),
      Flexible(
        child: ScreenShareSourcePicker(
          options: widget.options,
          onSelected: (source) => widget.onSelected(source, _mode),
        ),
      ),
    ],
  );
}
