/// Local development output, owned by one native runtime. No wire fields change.
final class NativeDiagnosticOptions {
  NativeDiagnosticOptions({required this.directory, required this.runId}) {
    if (directory.isEmpty ||
        directory.length > 4096 ||
        directory.contains('\u0000') ||
        !RegExp(r'^[A-Za-z0-9_-]{1,96}$').hasMatch(runId)) {
      throw ArgumentError('Invalid local diagnostic configuration');
    }
  }
  final String directory;
  final String runId;
}
