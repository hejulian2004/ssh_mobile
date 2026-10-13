import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_media/realtime_media.dart';
import 'package:ssh_mobile/app/screen_share_codec_mode_picker.dart';

void main() {
  const option = ScreenShareSourceOption(
    opaqueId: 'fixture-display',
    kind: ScreenShareSourceKind.display,
    label: 'Fixture display',
    width: 640,
    height: 480,
  );
  testWidgets(
    'source selection defaults to hardware and carries explicit CPU choice',
    (tester) async {
      final selected = <RealtimeMediaCodecMode>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppScreenShareSourcePicker(
              options: const [option],
              onSelected: (source, mode) {
                expect(source, option);
                selected.add(mode);
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Fixture display'));
      expect(selected, [RealtimeMediaCodecMode.hardware]);
      await tester.tap(find.text('CPU mode'));
      await tester.pump();
      await tester.tap(find.text('Fixture display'));
      expect(selected.last, RealtimeMediaCodecMode.cpu);
      await tester.tap(find.text('CPU mode'));
      await tester.pump();
      await tester.tap(find.text('Fixture display'));
      expect(selected.last, RealtimeMediaCodecMode.hardware);
    },
  );
  testWidgets(
    'busy incoming selection is disabled and Chinese text is localized',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Localizations.override(
              context: context,
              locale: const Locale('zh'),
              child: Scaffold(
                body: AppScreenShareCodecModePicker(
                  mode: RealtimeMediaCodecMode.cpu,
                  onChanged: null,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('CPU 模式'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
    },
  );
}
