// Explicit hardware harness: flutter test test/manual/lan_emulator_mapping_smoke.dart.
// Requires exactly one online local Android Emulator. Uses only temporary sockets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/lan_share_emulator_discovery.dart';
import 'package:ssh_mobile/app/lan_share_emulator_host.dart';

void main() {
  test('real console UDP replies can use a rewritten source port', () async {
    final host = AdbAndroidEmulatorHost();
    final serials = await host.listEmulators();
    expect(serials.length, 1);
    final serial = serials.single;
    final adb = resolveAdbExecutable(
      Platform.environment,
      (path) => File(path).existsSync(),
    );
    final process = await Process.start(adb, [
      '-s',
      serial,
      'shell',
      "toybox timeout 15 toybox nc -4 -u -l -p 62059 -W 10 -w 10 sh -c 'printf UDP_PROBE_OK'",
    ]);
    final errors = <String>[];
    void record(String value) {
      if (errors.length < 4) {
        errors.add(value.substring(0, value.length > 256 ? 256 : value.length));
      }
    }

    final stdout = process.stdout.transform(utf8.decoder).listen(record);
    final stderr = process.stderr.transform(utf8.decoder).listen(record);
    final port = await host.addRedirection(serial, 'udp', 62059);
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final reply = Completer<Datagram>();
    final subscription = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final data = socket.receive();
        if (data != null && !reply.isCompleted) reply.complete(data);
      }
    });
    addTearDown(() async {
      socket.close();
      await subscription.cancel();
      await host.removeRedirection(serial, 'udp', port);
      process.kill();
      await process.exitCode;
      await stdout.cancel();
      await stderr.cancel();
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    socket.send([1], InternetAddress.loopbackIPv4, port);
    final packet = await reply.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        throw StateError('UDP probe timeout: $errors');
      },
    );
    expect(utf8.decode(packet.data), 'UDP_PROBE_OK');
    expect(packet.address.isLoopback, isTrue);
    expect(packet.port, isNot(port));
  });
  test('real emulator console maps discovery, control and native TCP/UDP', () async {
    final server = Platform.environment['ADB_SERVER_SOCKET'];
    if (server != null &&
        !RegExp(r'^tcp:(localhost|127\.0\.0\.1):\d+$').hasMatch(server)) {
      throw StateError('A local ADB server is required.');
    }
    final baseHost = AdbAndroidEmulatorHost();
    final serials = await baseHost.listEmulators();
    expect(serials.length, 1);
    final adb = resolveAdbExecutable(
      Platform.environment,
      (path) => File(path).existsSync(),
    );
    final serial = serials.single;
    final responders = <Process>[];
    final outputSubscriptions = <StreamSubscription<String>>[];
    final stderrDrains = <Future<void>>[];
    final guestErrors = <String>[];
    final fixtureHost = _FixtureHost(baseHost);
    final logger = _Logger();
    final bridge = AppLanEmulatorDiscovery(host: fixtureHost, logger: logger);
    final udpSockets = <RawDatagramSocket>[];
    final tcpSockets = <Socket>[];
    addTearDown(() async {
      await bridge.close();
      for (final socket in udpSockets) {
        socket.close();
      }
      for (final socket in tcpSockets) {
        socket.destroy();
      }
      for (final process in responders) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 3));
      }
      for (final subscription in outputSubscriptions) {
        await subscription.cancel();
      }
      await Future.wait(stderrDrains);
    });
    Future<void> respond(int port, String payload, {bool udp = false}) async {
      // Only constants and synthetic fixture data enter this bounded guest command.
      final command = "printf '%s' '$payload'";
      final quoted = "'${command.replaceAll("'", "'\"'\"'")}'";
      final process = await Process.start(adb, [
        '-s',
        serial,
        'shell',
        'toybox timeout 25 toybox nc -4 ${udp ? '-u' : ''} -l -p $port -W 15 -w 15 sh -c $quoted',
      ]);
      responders.add(process);
      outputSubscriptions.add(
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((_) {}),
      );
      stderrDrains.add(
        process.stderr.transform(utf8.decoder).forEach((value) {
          if (guestErrors.length < 8) {
            guestErrors.add(
              value
                  .substring(0, value.length > 512 ? 512 : value.length)
                  .replaceAll(RegExp(r'emulator-\d+'), 'emulator'),
            );
          }
        }),
      );
    }

    await respond(
      62055,
      jsonEncode({
        'type': 'PONG',
        'id': 'fixture-emulator',
        'alias': 'Fixture emulator',
        'os': 'android',
        'port': 62056,
        'nativePort': 62057,
      }),
      udp: true,
    );
    await respond(62056, 'CONTROL_OK');
    await respond(62057, 'NATIVE_TCP_OK');
    await respond(62057, 'NATIVE_UDP_OK', udp: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final discovered = bridge.peers.firstWhere(
      (peers) => peers.any((peer) => peer.deviceId == 'fixture-emulator'),
    );
    await bridge.start({
      'type': 'PING',
      'id': 'fixture-windows',
      'alias': 'Fixture Windows',
      'os': 'windows',
      'port': 62054,
    });
    final peer = (await discovered.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        throw StateError(
          'Discovery timeout: calls=${fixtureHost.calls}, warnings=${logger.warnings}, guest errors=$guestErrors',
        );
      },
    )).single;
    expect(peer.ip, '127.0.0.1');
    expect(peer.controlPort, isNot(62056));
    expect(peer.advertisedNativePort, isNotNull);
    Future<String> readTcp(int port) async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 3),
      );
      tcpSockets.add(socket);
      return utf8.decode(
        await socket.first.timeout(const Duration(seconds: 3)),
      );
    }

    expect(await readTcp(peer.controlPort), 'CONTROL_OK');
    expect(await readTcp(peer.advertisedNativePort!), 'NATIVE_TCP_OK');
    expect(bridge.nativePortFor(peer, 62057), peer.advertisedNativePort);
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    udpSockets.add(socket);
    final received = Completer<Datagram>();
    final subscription = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final packet = socket.receive();
        if (packet != null && !received.isCompleted) received.complete(packet);
      }
    });
    addTearDown(subscription.cancel);
    socket.send([1], InternetAddress.loopbackIPv4, peer.advertisedNativePort!);
    final packet = await received.future.timeout(const Duration(seconds: 3));
    expect(utf8.decode(packet.data), 'NATIVE_UDP_OK');
    expect(packet.port, inInclusiveRange(1, 65535));
    await bridge.stop();
    expect(bridge.nativePortFor(peer, 62057), isNull);
  }, timeout: const Timeout(Duration(seconds: 50)));
}

final class _FixtureHost implements AndroidEmulatorHost {
  _FixtureHost(this.delegate);
  final AndroidEmulatorHost delegate;
  final List<String> calls = [];
  @override
  Future<List<String>> listEmulators() => delegate.listEmulators();
  @override
  Future<int> addRedirection(
    String serial,
    String protocol,
    int guestPort, {
    int? hostPort,
  }) {
    calls.add('$protocol:$guestPort');
    return delegate.addRedirection(
      serial,
      protocol,
      guestPort == LanDiscoveryService.udpDiscoveryPort ? 62055 : guestPort,
      hostPort: hostPort,
    );
  }

  @override
  Future<void> removeRedirection(
    String serial,
    String protocol,
    int hostPort,
  ) => delegate.removeRedirection(serial, protocol, hostPort);
}

final class _Logger implements LanShareLoggerPort {
  final List<String> warnings = [];
  @override
  void info(String message, {String? details}) {}
  @override
  void warning(String message, {String? details}) {
    warnings.add(details ?? message);
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}
