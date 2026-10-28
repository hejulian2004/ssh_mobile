import 'package:test/test.dart';
import 'dart:io';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

void main() {
  test('diagnostic options validate identity and bounded local path', () {
    expect(
      NativeDiagnosticOptions(directory: 'fixture', runId: 'test-run').runId,
      'test-run',
    );
    expect(
      () => NativeDiagnosticOptions(directory: '', runId: 'run'),
      throwsArgumentError,
    );
    expect(
      () => NativeDiagnosticOptions(directory: 'fixture', runId: '../bad'),
      throwsArgumentError,
    );
  });
  test('optional output follows the real cold runtime lifecycle', () async {
    final directory = Directory.systemTemp.createTempSync('native_log_');
    try {
      final runtime = await const SshMobileNetworkNative().createRuntime(
        diagnostics: NativeDiagnosticOptions(
          directory: directory.path,
          runId: 'test-run',
        ),
      );
      await runtime.dispose();
      final health = directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('health.json'))
          .single;
      expect(await health.readAsString(), contains('"closed":true'));
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
