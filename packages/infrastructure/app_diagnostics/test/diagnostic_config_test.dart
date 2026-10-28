import 'dart:io';
import 'package:app_diagnostics/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unconfigured output creates no sink or files', () {
    expect(DiagnosticConfig.fromEnvironment(environment: {}).enabled, false);
    expect(DiagnosticFileSink.fromEnvironment('flutter'), null);
    final defaultOutput = DiagnosticConfig.fromEnvironment(
      environment: {'SSH_MOBILE_LOG_RUN_ID': 'run'},
      android: false,
    );
    expect(
      defaultOutput.directory.path,
      contains('build/agent-observability/run'),
    );
    expect(
      DiagnosticConfig.fromEnvironment(
        environment: {'SSH_MOBILE_LOG_RUN_ID': 'run'},
        android: true,
        temporaryDirectory: Directory('fixture-cache'),
      ).directory.path,
      'fixture-cache/agent-observability/run',
    );
  });
}
