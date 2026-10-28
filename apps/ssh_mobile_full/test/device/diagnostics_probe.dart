import 'package:app_core/app_core.dart';
import 'package:app_diagnostics/app_diagnostics.dart';
import 'package:flutter/material.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

// Device-only public fixture: no business databases, secure storage or network.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = DiagnosticConfig.fromEnvironment();
  final sink = DiagnosticFileSink.fromEnvironment('flutter');
  if (!config.enabled || sink == null) {
    throw StateError('Diagnostic run required');
  }
  final logger = AppLoggerImpl(sinks: [sink]);
  logger.log(
    LogRecord(
      timestamp: DateTime.now(),
      level: LogLevel.error,
      message: 'diagnostic_probe_error',
      eventName: 'diagnostic_probe_error',
      traceId: 'probe-trace',
      attributes: const {'duration_ms': 12},
    ),
  );
  final native = await const SshMobileNetworkNative().createRuntime(
    diagnostics: NativeDiagnosticOptions(
      directory: config.directory.path,
      runId: config.runId,
    ),
  );
  await native.dispose();
  await logger.dispose();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Diagnostics probe complete'))),
    ),
  );
}
