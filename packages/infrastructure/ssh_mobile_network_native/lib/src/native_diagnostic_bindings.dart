part of '../ssh_mobile_network_native.dart';

@Native<
  Int32 Function(
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Pointer<Void>>,
  )
>(symbol: 'ssh_net_runtime_create_with_diagnostics')
external int _sshNetRuntimeCreateWithDiagnosticsNative(
  Pointer<Uint8> directory,
  int directoryLength,
  Pointer<Uint8> run,
  int runLength,
  Pointer<Pointer<Void>> outHandle,
);

int _createRuntimeHandle(
  Pointer<Pointer<Void>> outHandle,
  NativeDiagnosticOptions? options,
) {
  if (options == null) return _sshNetRuntimeCreateNative(outHandle);
  final directoryBytes = utf8.encode(options.directory);
  final runBytes = utf8.encode(options.runId);
  final directory = calloc<Uint8>(directoryBytes.length);
  final run = calloc<Uint8>(runBytes.length);
  try {
    directory.asTypedList(directoryBytes.length).setAll(0, directoryBytes);
    run.asTypedList(runBytes.length).setAll(0, runBytes);
    return _sshNetRuntimeCreateWithDiagnosticsNative(
      directory,
      directoryBytes.length,
      run,
      runBytes.length,
      outHandle,
    );
  } finally {
    calloc.free(directory);
    calloc.free(run);
  }
}
