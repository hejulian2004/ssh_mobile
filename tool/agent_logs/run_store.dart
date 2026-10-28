import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_diagnostics/app_diagnostics.dart';

/// Owns only marked per-checkout diagnostic directories, never application data.
final class RunStore {
  RunStore(this.root, {required this.checkoutId});
  final Directory root;
  final String checkoutId;

  static String checkoutKey(String path) {
    var value = 0x811c9dc5;
    for (final byte in utf8.encode(
      Directory(path).absolute.path.replaceAll('\\', '/'),
    )) {
      value = ((value ^ byte) * 0x01000193) & 0xffffffff;
    }
    return value.toRadixString(16);
  }

  Directory directoryFor(String id) {
    if (!DiagnosticConfig.identifier.hasMatch(id))
      throw ArgumentError('Invalid run identifier');
    return Directory('${root.absolute.path}/$id');
  }

  Future<Map<String, dynamic>> create({required String revision}) async {
    final id =
        '${DateTime.now().toUtc().millisecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff).toRadixString(16)}';
    final directory = directoryFor(id);
    await directory.create(recursive: true);
    final manifest = <String, dynamic>{
      'schema_version': 1,
      'run_id': id,
      'checkout_id': checkoutId,
      'revision': revision,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'state': 'starting',
      'components': <String, dynamic>{},
    };
    await save(manifest);
    return manifest;
  }

  Map<String, dynamic> read(String id) {
    final dir = directoryFor(id);
    if (FileSystemEntity.isLinkSync(dir.path))
      throw StateError('Linked run directories are not accepted');
    final file = File('${dir.path}/run.json');
    if (FileSystemEntity.isLinkSync(file.path))
      throw StateError('Linked manifests are not accepted');
    final value = jsonDecode(_readSnapshot(file)) as Map<String, dynamic>;
    if (value['checkout_id'] != checkoutId || value['run_id'] != id) {
      throw StateError('Run does not belong to this checkout');
    }
    return value;
  }

  // Native Windows readers can briefly race replacement or antivirus file
  // handles. Retry only transient OS errors, never malformed/unowned manifests.
  static bool _transient(FileSystemException error) =>
      Platform.isWindows && {2, 5, 32, 33}.contains(error.osError?.errorCode);

  static String _readSnapshot(File file) {
    for (var attempt = 0; ; attempt++) {
      try {
        return file.readAsStringSync();
      } on FileSystemException catch (error) {
        if (!_transient(error) || attempt >= 20) rethrow;
        sleep(const Duration(milliseconds: 5));
      }
    }
  }

  Future<void> save(Map<String, dynamic> manifest) async {
    final dir = directoryFor(manifest['run_id'] as String);
    if (FileSystemEntity.isLinkSync(dir.path))
      throw StateError('Linked run directories are not accepted');
    final temporary = File('${dir.path}/run.json.tmp');
    await temporary.writeAsString('${jsonEncode(manifest)}\n', flush: true);
    for (var attempt = 0; ; attempt++) {
      try {
        await temporary.rename('${dir.path}/run.json');
        break;
      } on FileSystemException catch (error) {
        if (!_transient(error) || attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
  }

  Future<List<Map<String, dynamic>>> list() async {
    if (!root.existsSync()) return [];
    final runs = <Map<String, dynamic>>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      try {
        runs.add(read(id));
      } on Object {
        /* Ignore unowned/corrupt entries. */
      }
    }
    runs.sort(
      (a, b) =>
          (b['created_at'] as String).compareTo(a['created_at'] as String),
    );
    return runs;
  }

  Future<int> clean({Duration retention = const Duration(days: 7)}) async {
    var removed = 0;
    for (final run in await list()) {
      if (!{'stopped', 'failed'}.contains(run['state'])) continue;
      if (DateTime.now().toUtc().difference(
            DateTime.parse(run['created_at'] as String),
          ) <
          retention)
        continue;
      final directory = directoryFor(run['run_id'] as String);
      // read() above verifies the marker, checkout, and non-link target.
      String normalized(String value) =>
          value.replaceAll('\\', '/').toLowerCase();
      if (normalized(directory.resolveSymbolicLinksSync()) !=
          normalized(directory.absolute.path)) {
        throw StateError('Refusing cleanup through a linked directory');
      }
      await directory.delete(recursive: true);
      removed++;
    }
    return removed;
  }
}
