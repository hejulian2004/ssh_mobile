import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_media_android/realtime_media_android.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ssh_mobile/realtime_media/android');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('overlay denial stays false and does not throw', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'presentGuidanceOverlay');
      return false;
    });
    const overlay = MethodChannelAndroidGuidanceOverlay();
    final shown = await overlay.present(
      const AndroidGuidanceSnapshot(width: 1080, height: 2400, strokes: []),
    );
    expect(shown, isFalse);
  });

  test('a missing plugin hides without failing', () async {
    const overlay = MethodChannelAndroidGuidanceOverlay(
      channel: MethodChannel('ssh_mobile/realtime_media/android_missing'),
    );
    await overlay.hide();
  });
}
