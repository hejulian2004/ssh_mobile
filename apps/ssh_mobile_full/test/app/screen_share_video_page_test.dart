import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/screen_share_video_page.dart';

void main() {
  late ValueNotifier<Size?> size;
  setUp(() => size = ValueNotifier(const Size(1080, 2400)));
  tearDown(() => size.dispose());

  Widget page({VoidCallback? onStop, bool enabled = true, Locale? locale}) =>
      MaterialApp(
        locale: locale,
        home: AppScreenShareVideoPage(
          video: const _Video(),
          videoSize: size,
          controls: const Text('consent state'),
          enableViewerControls: enabled,
          onStop: onStop,
        ),
      );

  testWidgets('rotation keeps native aspect ratio and wraps after four turns', (
    tester,
  ) async {
    await tester.pumpWidget(page());
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      1080 / 2400,
    );
    await tester.tap(find.byTooltip('Rotate view'));
    await tester.pump();
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      2400 / 1080,
    );
    size.value = const Size(1920, 1080);
    await tester.pump();
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      1080 / 1920,
    );
    for (var turn = 0; turn < 3; turn++) {
      await tester.tap(find.byTooltip('Rotate view'));
      await tester.pump();
    }
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 0);
  });

  testWidgets(
    'fullscreen preserves video state and back exits it before navigation',
    (tester) async {
      var stopped = 0;
      await tester.pumpWidget(page(onStop: () => stopped++));
      final before = tester.state(find.byType(_Video));
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('consent state'), findsNothing);
      expect(tester.state(find.byType(_Video)), same(before));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('consent state'), findsOneWidget);
      expect(tester.state(find.byType(_Video)), same(before));
      expect(stopped, 0);
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop screen share'));
      expect(stopped, 1);
    },
  );

  testWidgets('escape exits fullscreen and terminal state restores controls', (
    tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.tap(find.byTooltip('Enter fullscreen'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    await tester.tap(find.byTooltip('Enter fullscreen'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(enabled: false));
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('Rotate view'), findsNothing);
    expect(find.text('consent state'), findsOneWidget);
  });

  testWidgets('missing or invalid dimensions remain renderable', (
    tester,
  ) async {
    size.value = null;
    await tester.pumpWidget(page());
    expect(find.byType(_Video), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
    size.value = const Size(double.infinity, -1);
    await tester.pump();
    expect(find.byType(AspectRatio), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Video extends StatefulWidget {
  const _Video();
  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
}
