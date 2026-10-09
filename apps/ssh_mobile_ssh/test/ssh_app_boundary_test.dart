import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SSH app sources and manifest stay outside the network platform', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final dependencies = _dependencyBlock(pubspec);
    for (final forbidden in _forbiddenPackages) {
      expect(dependencies.contains('$forbidden:'), isFalse, reason: forbidden);
    }
    expect(dependencies.contains('ssh_core:'), isTrue);
    expect(dependencies.contains('feature_terminal:'), isTrue);
    expect(dependencies.contains('feature_connection:'), isTrue);
    expect(dependencies.contains('dartssh2:'), isTrue);
    expect(dependencies.contains('network_transport:'), isFalse);

    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    expect(sources, isNotEmpty);
    for (final source in sources) {
      final text = source.readAsStringSync();
      for (final forbidden in _forbiddenImports) {
        expect(
          text.contains(forbidden),
          isFalse,
          reason: '${source.path} $forbidden',
        );
      }
    }
  });
}

const _forbiddenPackages = <String>[
  'network_transport',
  'network_sdk',
  'ssh_mobile_network_native',
  'feature_lan_share',
  'feature_sftp',
  'feature_ai',
  'feature_screen_share',
  'realtime_media',
];

const _forbiddenImports = <String>[
  'package:network_transport/',
  'package:network_sdk/',
  'package:ssh_mobile_network_native/',
  'package:feature_lan_share/',
  'package:feature_sftp/',
  'package:feature_ai/',
  'package:realtime_media/',
];

String _dependencyBlock(String pubspec) {
  final start = pubspec.indexOf('\ndependencies:');
  final end = pubspec.indexOf('\ndev_dependencies:');
  return pubspec.substring(start, end);
}
