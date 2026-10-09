import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('network app hosts LAN share and stays outside SSH features', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final dependencies = _dependencyBlock(pubspec);
    for (final forbidden in _forbiddenPackages) {
      expect(dependencies.contains('$forbidden:'), isFalse, reason: forbidden);
    }
    for (final required in _requiredPackages) {
      expect(dependencies.contains('$required:'), isTrue, reason: required);
    }

    final sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    expect(sources, isNotEmpty);
    final joined = sources.map((file) => file.readAsStringSync()).join('\n');
    for (final forbidden in _forbiddenImports) {
      expect(joined.contains(forbidden), isFalse, reason: forbidden);
    }
    expect(
      joined.contains('package:feature_lan_share/feature_lan_share.dart'),
      isTrue,
    );
    expect(joined.contains('NativeNetworkService'), isFalse);
    expect(joined.contains('/src/'), isFalse);
  });
}

const _requiredPackages = <String>[
  'app_core',
  'app_ui',
  'feature_lan_share',
  'network_sdk',
  'network_transport',
];

const _forbiddenPackages = <String>[
  'ssh_core',
  'feature_terminal',
  'feature_connection',
  'feature_sftp',
  'feature_ai',
  'feature_screen_share',
  'dartssh2',
  'ssh_mobile_full',
];

const _forbiddenImports = <String>[
  'package:ssh_core/',
  'package:feature_terminal/',
  'package:feature_connection/',
  'package:feature_sftp/',
  'package:feature_ai/',
  'package:feature_screen_share/',
  'package:dartssh2/',
  'package:ssh_mobile_full/',
  'apps/ssh_mobile_full/',
];

String _dependencyBlock(String pubspec) {
  final start = pubspec.indexOf('\ndependencies:');
  final end = pubspec.indexOf('\ndev_dependencies:');
  return pubspec.substring(start, end);
}
