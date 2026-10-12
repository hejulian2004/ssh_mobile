import 'dart:async';

import 'dart:convert';
import 'dart:io';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/lan_share_emulator_discovery.dart';

void main() {
  _edgeCases();
  test(
    'simultaneous emulators have independent reply channels even with one NAT source port',
    () async {
      final guests = <String, RawDatagramSocket>{};
      for (final serial in ['emulator-5554', 'emulator-5556']) {
        guests[serial] = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
      }
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final bridge = AppLanEmulatorDiscovery(
        host: _MultiHost(guests),
        logger: _Logger(),
      );
      final destinations = <int>{};
      final subscriptions = <StreamSubscription<RawSocketEvent>>[];
      addTearDown(() async {
        await bridge.close();
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        for (final guest in guests.values) {
          guest.close();
        }
        sender.close();
      });
      for (final entry in guests.entries) {
        subscriptions.add(
          entry.value.listen((event) {
            if (event != RawSocketEvent.read) return;
            final packet = entry.value.receive();
            if (packet == null) return;
            destinations.add(packet.port);
            sender.send(
              utf8.encode(
                jsonEncode({
                  'type': 'PONG',
                  'id': entry.key,
                  'alias': 'Emulator',
                  'os': 'android',
                  'port': 53317,
                  'nativePort': 45000,
                }),
              ),
              packet.address,
              packet.port,
            );
          }),
        );
      }
      final found = bridge.peers.firstWhere((peers) => peers.length == 2);
      await bridge.start({
        'type': 'PING',
        'id': 'windows',
        'alias': 'Windows',
        'os': 'windows',
        'port': 53317,
      });
      final peers = await found.timeout(const Duration(seconds: 3));
      expect(destinations.length, 2);
      expect(peers.map((peer) => peer.deviceId).toSet(), guests.keys.toSet());
      expect(peers[0].controlPort, isNot(peers[1].controlPort));
      expect(
        bridge.nativePortFor(
          peers[0].copyWith(controlPort: peers[1].controlPort),
          45000,
        ),
        isNull,
      );
    },
  );
  test('emulator PONG can return from a rewritten NAT source port', () async {
    final fixture = await _Harness.create(autoReply: false);
    addTearDown(fixture.close);
    await fixture.probed.future;
    final reply = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(reply.close);
    expect(reply.port, isNot(fixture.guest.port));
    final found = fixture.bridge.peers.firstWhere((peers) => peers.isNotEmpty);
    reply.send(
      utf8.encode(jsonEncode(fixture.body)),
      fixture.probe!.address,
      fixture.probe!.port,
    );
    final peer = (await found.timeout(const Duration(seconds: 2))).single;
    expect(peer.deviceId, 'android');
    expect(peer.controlPort, 55001);
    expect(peer.advertisedNativePort, 55002);
  });
  test(
    'emulator discovery maps separate control and TCP/UDP native ports',
    () async {
      final guest = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(guest.close);
      final host = _Host(guest.port);
      final bridge = AppLanEmulatorDiscovery(host: host, logger: _Logger());
      addTearDown(bridge.close);
      final subscription = guest.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = guest.receive();
        if (packet == null) return;
        final ping =
            jsonDecode(utf8.decode(packet.data)) as Map<String, dynamic>;
        expect(ping['id'], 'windows');
        guest.send(
          utf8.encode(
            jsonEncode({
              'type': 'PONG',
              'id': 'android',
              'alias': 'Emulator',
              'os': 'android',
              'port': 53317,
              'nativePort': 45000,
            }),
          ),
          packet.address,
          packet.port,
        );
      });
      addTearDown(subscription.cancel);
      final found = bridge.peers.firstWhere((peers) => peers.isNotEmpty);
      await bridge.start(
        LanDiscoveryService.createUdpPingPayload(
          deviceId: 'windows',
          alias: 'Windows',
          os: 'windows',
          port: 53317,
          nativePort: 44000,
        ),
      );
      final peer = (await found.timeout(const Duration(seconds: 3))).single;
      expect(peer.ip, '127.0.0.1');
      expect(peer.controlPort, 55001);
      expect(peer.advertisedNativePort, 55002);
      expect(host.added, [
        'udp:53318',
        'tcp:53317',
        'tcp:45000',
        'udp:45000@55002',
      ]);
      expect(
        bridge.routePeer(peer.copyWith(controlPort: 53317)).controlPort,
        55001,
      );
      expect(bridge.nativePortFor(peer, 45000), 55002);
      expect(bridge.nativePortFor(peer, 45001), isNull);
      expect(
        bridge.nativePortFor(peer.copyWith(deviceId: 'other'), 45000),
        isNull,
      );
      await bridge.stop();
      expect(host.removed.toSet(), {
        'udp:${guest.port}',
        'tcp:55001',
        'tcp:55002',
        'udp:55002',
      });
      expect(bridge.nativePortFor(peer, 45000), isNull);
      await bridge.stop();
      expect(host.removed.length, 4);
    },
  );
}

class _Host implements AndroidEmulatorHost {
  _Host(this.discoveryPort);
  final int discoveryPort;
  final added = <String>[];
  final removed = <String>[];
  bool online = true;
  bool failLookup = false;
  bool failNativeUdp = false;
  Future<void>? pause;
  final mappingStarted = Completer<void>();
  int _allocated = 55000;

  @override
  Future<List<String>> listEmulators() async {
    if (failLookup) throw StateError('Unavailable');
    return online ? ['emulator-5554'] : [];
  }

  @override
  Future<int> addRedirection(
    String serial,
    String protocol,
    int guestPort, {
    int? hostPort,
  }) async {
    added.add('$protocol:$guestPort${hostPort == null ? '' : '@$hostPort'}');
    if (guestPort != 53318 && pause != null) {
      if (!mappingStarted.isCompleted) mappingStarted.complete();
      await pause;
    }
    if (protocol == 'udp' && guestPort != 53318 && failNativeUdp) {
      throw StateError('Unavailable');
    }
    return hostPort ?? (guestPort == 53318 ? discoveryPort : ++_allocated);
  }

  @override
  Future<void> removeRedirection(
    String serial,
    String protocol,
    int hostPort,
  ) async {
    removed.add('$protocol:$hostPort');
  }
}

class _MultiHost extends _Host {
  _MultiHost(this.guests) : super(guests.values.first.port);
  final Map<String, RawDatagramSocket> guests;
  @override
  Future<List<String>> listEmulators() async => guests.keys.toList();
  @override
  Future<int> addRedirection(
    String serial,
    String protocol,
    int guestPort, {
    int? hostPort,
  }) async {
    final result = await super.addRedirection(
      serial,
      protocol,
      guestPort,
      hostPort: hostPort,
    );
    return guestPort == LanDiscoveryService.udpDiscoveryPort
        ? guests[serial]!.port
        : result;
  }
}

class _Logger implements LanShareLoggerPort {
  int warnings = 0;
  @override
  void info(String message, {String? details}) {}
  @override
  void warning(String message, {String? details}) {
    warnings++;
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

void _edgeCases() {
  test(
    'invalid advertisements cannot create routes; refreshed routes replace old leases',
    () async {
      final fixture = await _Harness.create();
      addTearDown(fixture.close);
      final peer = await fixture.firstPeer;
      for (final invalid in <Object>[
        [],
        {'type': 'PING', 'os': 'android'},
        {...fixture.body, 'os': 'windows'},
        {...fixture.body, 'id': ''},
        {...fixture.body, 'id': 'windows'},
        {...fixture.body, 'id': 'x' * 129},
        {...fixture.body, 'alias': ''},
        {...fixture.body, 'alias': 'x' * 129},
        {...fixture.body, 'port': 0},
        {...fixture.body, 'port': 65536},
        {...fixture.body, 'nativePort': 0},
      ]) {
        fixture.send(invalid);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(fixture.host.added.length, 4);
      final next = fixture.bridge.peers.firstWhere(
        (peers) => peers.isNotEmpty && peers.single.alias == 'Changed',
      );
      fixture.send({
        ...fixture.body,
        'alias': 'Changed',
        'port': 53319,
        'nativePort': 45001,
      });
      final refreshed = (await next.timeout(const Duration(seconds: 2))).single;
      expect(refreshed.controlPort, isNot(peer.controlPort));
      expect(fixture.bridge.nativePortFor(peer, 45000), isNull);
      expect(fixture.host.removed.length, 3);
      final direct = refreshed.copyWith(ip: '192.168.1.20');
      expect(fixture.bridge.routePeer(direct), direct);
      expect(
        fixture.bridge.nativePortFor(
          refreshed.copyWith(ip: 'example.invalid'),
          45001,
        ),
        45001,
      );
      final noNative = fixture.bridge.peers.firstWhere(
        (peers) =>
            peers.isNotEmpty && peers.single.advertisedNativePort == null,
      );
      fixture.send({...fixture.body, 'nativePort': null});
      expect(
        (await noNative.timeout(
          const Duration(seconds: 2),
        )).single.advertisedNativePort,
        isNull,
      );
      fixture.guest.send([255], fixture.probe!.address, fixture.probe!.port);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fixture.logger.warnings, 1);
      await fixture.bridge.close();
      await expectLater(fixture.bridge.start({}), throwsStateError);
    },
  );

  test(
    'partial native mapping failure releases endpoints and permits a retry',
    () async {
      final fixture = await _Harness.create(autoReply: false);
      addTearDown(fixture.close);
      await fixture.probed.future;
      fixture.host.failNativeUdp = true;
      fixture.send(fixture.body);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fixture.host.removed.length, 2);
      expect(fixture.logger.warnings, 1);
      fixture.host.failNativeUdp = false;
      final recovered = fixture.bridge.peers.firstWhere(
        (peers) => peers.isNotEmpty,
      );
      fixture.send(fixture.body);
      expect(
        (await recovered.timeout(const Duration(seconds: 2))).single.deviceId,
        'android',
      );
      fixture.host.online = false;
      final gone = fixture.bridge.peers.firstWhere((peers) => peers.isEmpty);
      await gone.timeout(const Duration(seconds: 7));
      expect(fixture.host.removed, contains('udp:${fixture.guest.port}'));
    },
  );

  test(
    'stop drains an in-flight mapping and does not publish a late peer',
    () async {
      final fixture = await _Harness.create(autoReply: false);
      addTearDown(fixture.close);
      await fixture.probed.future;
      final release = Completer<void>();
      fixture.host.pause = release.future;
      fixture.send(fixture.body);
      await fixture.host.mappingStarted.future;
      final stopped = fixture.bridge.stop();
      release.complete();
      await stopped;
      expect(fixture.host.removed.length, 4);
    },
  );

  test(
    'host lookup failure closes without removing unrelated forwards',
    () async {
      final host = _Host(54000)..failLookup = true;
      final logger = _Logger();
      final bridge = AppLanEmulatorDiscovery(host: host, logger: logger);
      await bridge.start({'id': 'windows'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(logger.warnings, 1);
      await Future.wait([bridge.stop(), bridge.stop()]);
      await Future.wait([bridge.close(), bridge.close()]);
      expect(host.removed, isEmpty);
    },
  );
}

class _Harness {
  _Harness(this.guest, this.host, this.bridge, this.logger);
  final RawDatagramSocket guest;
  final _Host host;
  final AppLanEmulatorDiscovery bridge;
  final _Logger logger;
  final probed = Completer<void>();
  final body = <String, Object?>{
    'type': 'PONG',
    'id': 'android',
    'alias': 'Emulator',
    'os': 'android',
    'port': 53317,
    'nativePort': 45000,
  };
  late final Future<LanDiscoveredPeer> firstPeer;
  late final StreamSubscription<RawSocketEvent> subscription;
  Datagram? probe;

  static Future<_Harness> create({bool autoReply = true}) async {
    final guest = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final host = _Host(guest.port);
    final logger = _Logger();
    final bridge = AppLanEmulatorDiscovery(host: host, logger: logger);
    final fixture = _Harness(guest, host, bridge, logger);
    if (autoReply) {
      fixture.firstPeer = bridge.peers
          .firstWhere((peers) => peers.isNotEmpty)
          .then((peers) => peers.single);
    }
    fixture.subscription = guest.listen((event) {
      if (event != RawSocketEvent.read) return;
      fixture.probe = guest.receive();
      if (!fixture.probed.isCompleted) fixture.probed.complete();
      if (autoReply) fixture.send(fixture.body);
    });
    await bridge.start(
      LanDiscoveryService.createUdpPingPayload(
        deviceId: 'windows',
        alias: 'Windows',
        os: 'windows',
        port: 53317,
      ),
    );
    return fixture;
  }

  void send(Object body) {
    guest.send(utf8.encode(jsonEncode(body)), probe!.address, probe!.port);
  }

  Future<void> close() async {
    await bridge.close();
    await subscription.cancel();
    guest.close();
  }
}
