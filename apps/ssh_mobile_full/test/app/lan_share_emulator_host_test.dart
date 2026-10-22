import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/lan_share_emulator_host.dart';

void main() {
  test(
    'SDK executable resolution supports configured and conventional SDKs',
    () {
      expect(
        resolveAdbExecutable({'ANDROID_SDK_ROOT': 'C:/sdk'}, (_) => true),
        'C:/sdk/platform-tools/adb.exe',
      );
      expect(
        resolveAdbExecutable({'ANDROID_HOME': 'C:/home'}, (_) => true),
        'C:/home/platform-tools/adb.exe',
      );
      expect(
        resolveAdbExecutable({'LOCALAPPDATA': 'C:/local'}, (_) => true),
        'C:/local/Android/Sdk/platform-tools/adb.exe',
      );
      expect(
        resolveAdbExecutable({'ANDROID_SDK_ROOT': ''}, (_) => false),
        'adb.exe',
      );
    },
  );

  test('command execution bounds output, failures and timeouts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'emulator-command-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final executable = Platform.resolvedExecutable.replaceAll('\\', '/');
    final root = executable.substring(0, executable.indexOf('/bin/cache/'));
    final dart =
        '$root/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
    final script = File('${directory.path}/command.dart');
    Future<String> run(
      String source, {
      Duration timeout = const Duration(seconds: 4),
    }) async {
      await script.writeAsString(source);
      return runEmulatorCommand(dart, [
        '--disable-dart-dev',
        script.path,
      ], timeout: timeout);
    }

    expect(await run("void main() { print('OK'); }"), contains('OK'));
    await expectLater(
      run("import 'dart:io'; void main() { exit(2); }"),
      throwsStateError,
    );
    await expectLater(
      run("void main() { print('x' * 17000); }"),
      throwsStateError,
    );
    await expectLater(
      run(
        " Future<void> main() async { await Future<void>.delayed(Duration(seconds: 20)); }",
        timeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
  test(
    'ADB adapter selects online local emulators and removes exact leases',
    () async {
      final calls = <List<String>>[];
      final host = AdbAndroidEmulatorHost(
        execute: (args) async {
          calls.add(args);
          if (args.singleOrNull == 'devices') {
            return 'List of devices attached\nemulator-5554\tdevice\nphone\tdevice\nemulator-5556\toffline\n';
          }
          return 'OK\n';
        },
      );
      expect(await host.listEmulators(), ['emulator-5554']);
      final port = await host.addRedirection('emulator-5554', 'tcp', 53317);
      expect(port, inInclusiveRange(1, 65535));
      await host.addRedirection('emulator-5554', 'udp', 53318, hostPort: port);
      await host.removeRedirection('emulator-5554', 'udp', port);
      expect(calls.last, [
        '-s',
        'emulator-5554',
        'emu',
        'redir',
        'del',
        'udp:$port',
      ]);
      expect(
        () => host.addRedirection('phone', 'tcp', 53317),
        throwsArgumentError,
      );
      expect(
        () => host.addRedirection('emulator-5554', 'bad', 53317),
        throwsArgumentError,
      );
      expect(
        () => host.addRedirection('emulator-5554', 'tcp', 0),
        throwsArgumentError,
      );
    },
  );

  test('console rejection does not return an apparently usable port', () async {
    final host = AdbAndroidEmulatorHost(
      execute: (_) async => 'KO: port occupied\n',
    );
    await expectLater(
      host.addRedirection('emulator-5554', 'tcp', 53317, hostPort: 55100),
      throwsStateError,
    );
    await expectLater(
      host.removeRedirection('emulator-5554', 'tcp', 55100),
      throwsStateError,
    );
  });
}
