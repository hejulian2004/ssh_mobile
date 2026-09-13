import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'renders bounded source metadata and returns the selected token',
    (tester) async {
      const display = ScreenShareSourceOption(
        opaqueId: 'route-token-display',
        kind: ScreenShareSourceKind.display,
        label: 'Display 1',
        width: 1920,
        height: 1080,
      );
      const window = ScreenShareSourceOption(
        opaqueId: 'route-token-window',
        kind: ScreenShareSourceKind.window,
        label: 'Terminal',
        width: 800,
        height: 600,
      );
      ScreenShareSourceOption? selected;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScreenShareSourcePicker(
              options: const <ScreenShareSourceOption>[display, window],
              onSelected: (option) => selected = option,
            ),
          ),
        ),
      );

      expect(find.text('Display 1'), findsOneWidget);
      expect(find.text('1920 × 1080'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('800 × 600'), findsOneWidget);

      await tester.tap(find.text('Terminal'));
      expect(selected?.opaqueId, window.opaqueId);
    },
  );
}
