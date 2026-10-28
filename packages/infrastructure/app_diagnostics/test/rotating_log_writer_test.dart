import 'dart:io';
import 'package:app_diagnostics/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'zero rotations discard the previous bounded file and report health failures',
    () async {
      final dir = Directory.systemTemp.createTempSync('writer_');
      try {
        expect(
          () => RotatingLogWriter(File('${dir.path}/bad'), maxBytes: 0),
          throwsArgumentError,
        );
        final writer = RotatingLogWriter(
          File('${dir.path}/current'),
          rotations: 0,
          maxBytes: 5,
          onIdle: (_) async => throw StateError('unavailable health output'),
        );
        writer.write('first');
        await writer.pendingWrites;
        writer.write('second');
        await writer.close();
        expect(await writer.file.readAsString(), 'second\n');
        expect(writer.health.failed, greaterThan(0));
        expect(writer.health.written, 2);
        expect(writer.health.toJson()['closed'], true);
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
}
