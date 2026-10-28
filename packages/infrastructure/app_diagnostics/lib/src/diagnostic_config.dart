import 'dart:io';

/// Opt-in development configuration, independent of Flutter or native runtime.
final class DiagnosticConfig {
  DiagnosticConfig._(this.runId, this.directory);

  final String runId;
  final Directory directory;
  bool get enabled => runId.isNotEmpty;

  static final identifier = RegExp(r'^[A-Za-z0-9_-]{1,96}$');

  /// Dart defines reach Android; process environment reaches desktop/tool runs.
  /// Android always writes into its own cache, never a host-provided path.
  factory DiagnosticConfig.fromEnvironment({
    Map<String, String>? environment,
    bool? android,
    Directory? temporaryDirectory,
  }) {
    final env = environment ?? Platform.environment;
    const definedRun = String.fromEnvironment('SSH_MOBILE_LOG_RUN_ID');
    const definedDirectory = String.fromEnvironment('SSH_MOBILE_LOG_DIR');
    final run = environment == null && definedRun.isNotEmpty
        ? definedRun
        : (env['SSH_MOBILE_LOG_RUN_ID'] ?? '');
    if (run.isNotEmpty && !identifier.hasMatch(run)) {
      throw ArgumentError('Invalid diagnostic run identifier');
    }
    final output = environment == null && definedDirectory.isNotEmpty
        ? definedDirectory
        : (env['SSH_MOBILE_LOG_DIR'] ?? '');
    final isAndroid = android ?? Platform.isAndroid;
    final path = isAndroid
        ? '${(temporaryDirectory ?? Directory.systemTemp).path}/agent-observability/$run'
        : output.isNotEmpty
        ? output
        : '${Directory.current.path}/build/agent-observability/$run';
    const product = bool.fromEnvironment('dart.vm.product');
    return DiagnosticConfig._(product ? '' : run, Directory(path));
  }
}
