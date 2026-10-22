import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lan views do not import network_sdk or the discovery service', () {
    final offenders = <String>[];
    for (final entity in Directory(
      'lib/src/features/lan_share/views',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      if (text.contains('package:network_sdk/') ||
          text.contains('lan_discovery_service.dart')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
