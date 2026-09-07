import 'dart:io';

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
}
