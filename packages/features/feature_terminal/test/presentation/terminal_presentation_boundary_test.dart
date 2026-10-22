import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('terminal presentation does not import ssh_core', () {
    final offenders = <String>[];
    for (final entity in Directory(
      'lib/src/presentation',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.readAsStringSync().contains('package:ssh_core/')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
