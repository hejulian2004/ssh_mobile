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
    'source selection hides codec choices and uses automatic fallback',
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
      expect(selected.single.name, 'automatic');
      expect(find.text('CPU mode'), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
    },
  );
}
