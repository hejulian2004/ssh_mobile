import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/startup_branding.dart';

void main() {
  final profiles = <String, (Size, double, double)>{
    'small-phone': (const Size(320, 568), 1, 1),
    'dense-phone': (const Size(428, 952), 3, 1),
    'landscape-large-text': (const Size(568, 240), 2, 2),
    'small-window': (const Size(240, 180), 1.25, 2),
    'desktop': (const Size(1920, 1080), 2, 1),
  };
  for (final profile in profiles.entries) {
    testWidgets('startup branding fits ${profile.key}', (tester) async {
      final (size, density, textScale) = profile.value;
      tester.view.devicePixelRatio = density;
      tester.view.physicalSize = size * density;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const previewFont = String.fromEnvironment('STARTUP_PREVIEW_FONT');
      if (previewFont.isNotEmpty) {
        await tester.runAsync(() async {
          final loader = FontLoader('StartupPreview');
          loader.addFont(
            File(previewFont).readAsBytes().then(ByteData.sublistView),
          );
          await loader.load();
        });
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: previewFont.isNotEmpty ? 'StartupPreview' : null,
          ),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              devicePixelRatio: density,
              textScaler: TextScaler.linear(textScale),
              padding: const EdgeInsets.only(top: 24, bottom: 16),
            ),
            child: const RepaintBoundary(
              key: ValueKey('preview'),
              child: Scaffold(
                backgroundColor: Colors.white,
                body: StartupBranding(),
              ),
            ),
          ),
        ),
      );
      // SVG decoding is asynchronous, while the spinner is intentionally live.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('SSH Mobile'), findsOneWidget);
      final logoBounds = tester.getRect(find.byType(SvgPicture));
      expect(logoBounds.width, inInclusiveRange(64, 128));
      expect(logoBounds.width, logoBounds.height);
      expect(logoBounds.center.dx, closeTo(size.width / 2, .1));
      expect(logoBounds.left, greaterThanOrEqualTo(24));
      expect(logoBounds.right, lessThanOrEqualTo(size.width - 24));

      const previewDir = String.fromEnvironment('STARTUP_PREVIEW_DIR');
      if (previewDir.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('preview')),
        );
        await tester.runAsync(() async {
          final screenshot = await boundary.toImage(pixelRatio: density);
          final bytes = await screenshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory(previewDir).create(recursive: true);
          await File(
            '$previewDir/${profile.key}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          screenshot.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
