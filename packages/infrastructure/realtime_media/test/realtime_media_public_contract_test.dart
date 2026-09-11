import 'dart:io';

import 'package:realtime_media/realtime_media.dart';
import 'package:test/test.dart';

void main() {
  test('public media contract does not expose per-frame or native handles', () {
    final lib = Directory('lib');
    final source = lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    for (final forbidden in <String>[
      'Uint8List',
      'Stream<',
      'pushFrame',
      'sendFrame',
      'receiveFrame',
      'Pointer<',
      'Socket',
      'PeerConnection',
      'SDP',
      'ICE',
      'RTP',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('source metadata remains bounded and payload-free', () {
    final source = ScreenCaptureSource(
      id: ScreenCaptureSourceId('display:0'),
      kind: ScreenCaptureSourceKind.display,
      label: 'Display 1',
      width: 1920,
      height: 1080,
    );

    expect(source.label, 'Display 1');
    expect(source.width, 1920);
    expect(source.height, 1080);
    expect(
      () => ScreenCaptureSource(
        id: ScreenCaptureSourceId('display:1'),
        kind: ScreenCaptureSourceKind.display,
        label: 'x' * 129,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
