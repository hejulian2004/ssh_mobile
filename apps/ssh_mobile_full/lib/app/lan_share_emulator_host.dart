import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lan_share_emulator_discovery.dart';

typedef EmulatorCommandExecutor =
    Future<String> Function(List<String> arguments);

/// Uses the installed Android SDK's ADB console, never a shell command string.
final class AdbAndroidEmulatorHost implements AndroidEmulatorHost {
  AdbAndroidEmulatorHost({EmulatorCommandExecutor? execute})
    : _execute =
          execute ??
          ((args) => runEmulatorCommand(
            resolveAdbExecutable(
              Platform.environment,
              FileSystemEntity.isFileSync,
            ),
            args,
          ));

  final EmulatorCommandExecutor _execute;

  @override
  Future<List<String>> listEmulators() async {
    final output = await _execute(['devices']);
    return output
        .split(RegExp(r'\r?\n'))
        .map(
          (line) => RegExp(
            r'^(emulator-\d+)\s+device\s*$',
          ).firstMatch(line)?.group(1),
        )
        .whereType<String>()
        .take(8)
        .toList();
  }

  void _validate(String serial, String protocol, int port) {
    if (!RegExp(r'^emulator-\d+$').hasMatch(serial) ||
        (protocol != 'tcp' && protocol != 'udp') ||
        port < 1 ||
        port > 65535) {
      throw ArgumentError('Invalid local emulator redirection.');
    }
  }

  Future<void> _console(String serial, List<String> arguments) async {
    final output = await _execute(['-s', serial, 'emu', 'redir', ...arguments]);
    if (!output.split(RegExp(r'[\r\n]+')).any((line) => line.trim() == 'OK') ||
        output.contains('KO:')) {
      throw StateError('Emulator console rejected redirection.');
    }
  }

  @override
  Future<int> addRedirection(
    String serial,
    String protocol,
    int guestPort, {
    int? hostPort,
  }) async {
    _validate(serial, protocol, guestPort);
    if (hostPort != null) _validate(serial, protocol, hostPort);
    final port = hostPort ?? await _availablePort();
    await _console(serial, ['add', '$protocol:$port:$guestPort']);
    return port;
  }

  Future<int> _availablePort() async {
    final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    RawDatagramSocket? udp;
    try {
      udp = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        tcp.port,
      );
      return tcp.port;
    } finally {
      udp?.close();
      await tcp.close();
    }
  }

  @override
  Future<void> removeRedirection(
    String serial,
    String protocol,
    int hostPort,
  ) async {
    _validate(serial, protocol, hostPort);
    await _console(serial, ['del', '$protocol:$hostPort']);
  }
}

/// Explicit SDK configuration, conventional Android Studio location, then PATH.
String resolveAdbExecutable(
  Map<String, String> environment,
  bool Function(String) isFile,
) {
  for (final root in [
    environment['ANDROID_SDK_ROOT'],
    environment['ANDROID_HOME'],
    if (environment['LOCALAPPDATA'] != null)
      '${environment['LOCALAPPDATA']}/Android/Sdk',
  ]) {
    if (root == null || root.isEmpty) {
      continue;
    }
    final path = '$root/platform-tools/adb.exe';
    if (isFile(path)) {
      return path;
    }
  }
  return 'adb.exe';
}

/// Bounded command output and deadline; only the launched process is terminated.
Future<String> runEmulatorCommand(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final process = await Process.start(executable, arguments, runInShell: false);
  Future<List<int>> read(Stream<List<int>> stream) async {
    final result = <int>[];
    await for (final chunk in stream) {
      if (result.length + chunk.length > 16384) {
        throw StateError('Emulator command output exceeded limit.');
      }
      result.addAll(chunk);
    }
    return result;
  }

  try {
    final output = await Future.wait<Object>([
      read(process.stdout),
      read(process.stderr),
      process.exitCode,
    ], eagerError: true).timeout(timeout);
    if (output[2] != 0) {
      throw StateError('Emulator command failed.');
    }
    return utf8.decode(output[0] as List<int>);
  } finally {
    process.kill();
    await process.exitCode;
  }
}
