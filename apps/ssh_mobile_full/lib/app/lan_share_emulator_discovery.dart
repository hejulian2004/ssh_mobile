import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:feature_lan_share/feature_lan_share.dart';

/// Host operations are injected independently of the discovery protocol.
abstract interface class AndroidEmulatorHost {
  Future<List<String>> listEmulators();
  Future<int> addRedirection(
    String serial,
    String protocol,
    int guestPort, {
    int? hostPort,
  });
  Future<void> removeRedirection(String serial, String protocol, int hostPort);
}

/// Bridges local Android Emulator UDP discovery using owned console redirects.
/// TCP control and TCP/UDP native ports remain separate. No credentials are read.
final class AppLanEmulatorDiscovery implements LanShareDiscoveryBridgePort {
  AppLanEmulatorDiscovery({required this.host, required this.logger});

  final AndroidEmulatorHost host;
  final LanShareLoggerPort logger;
  final _peers = StreamController<List<LanDiscoveredPeer>>.broadcast();
  final _routes = <String, _EmulatorRoute>{};
  final _operations = <Future<void>>{};
  Timer? _timer;
  Future<void>? _polling;
  Future<void>? _stopping;
  Future<void>? _closing;
  Map<String, Object>? _advertisement;
  bool _active = false;
  bool _closed = false;
  bool _warned = false;

  @override
  Stream<List<LanDiscoveredPeer>> get peers => _peers.stream;

  @override
  Future<void> start(Map<String, Object> advertisement) async {
    if (_closed) {
      throw StateError('Emulator discovery is closed.');
    }
    await stop();
    _advertisement = Map.unmodifiable(advertisement);
    _active = true;
    unawaited(_poll());
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_poll()),
    );
  }

  Future<void> _poll() =>
      _polling ??= _performPoll().whenComplete(() => _polling = null);

  Future<_EmulatorRoute> _createRoute(String serial, int port) async {
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    } catch (_) {
      await host.removeRedirection(serial, 'udp', port);
      rethrow;
    }
    final route = _EmulatorRoute(serial, port, socket);
    _routes[serial] = route;
    // Emulator NAT rewrites reply source ports. The owned per-emulator request
    // socket, rather than the reply's source port, identifies the observation.
    route.subscription = socket.listen((event) {
      if (!_active ||
          !identical(_routes[serial], route) ||
          event != RawSocketEvent.read) {
        return;
      }
      Datagram? packet;
      while ((packet = socket.receive()) != null) {
        final datagram = packet!;
        if (!datagram.address.isLoopback ||
            datagram.data.length > 4096 ||
            route.updating) {
          continue;
        }
        route.updating = true;
        late final Future<void> operation;
        operation = _observe(route, datagram.data).whenComplete(() {
          route.updating = false;
          _operations.remove(operation);
        });
        _operations.add(operation);
      }
    });
    return route;
  }

  Future<void> _performPoll() async {
    try {
      final serials = (await host.listEmulators()).take(8).toSet();
      if (!_active) {
        return;
      }
      for (final serial in _routes.keys.toList()) {
        if (!serials.contains(serial)) {
          final route = _routes.remove(serial)!;
          await Future.wait(_operations.toList());
          await _release(route);
        }
      }
      for (final serial in serials) {
        if (!_active) {
          return;
        }
        var route = _routes[serial];
        if (route == null) {
          final port = await host.addRedirection(
            serial,
            'udp',
            LanDiscoveryService.udpDiscoveryPort,
          );
          route = await _createRoute(serial, port);
        }
        if (!_active) {
          return;
        }
        route.socket.send(
          utf8.encode(jsonEncode(_advertisement)),
          InternetAddress.loopbackIPv4,
          route.discoveryPort,
        );
      }
      _warned = false;
      _publish();
    } on Object catch (error) {
      _warning(error);
    }
  }

  Future<void> _observe(_EmulatorRoute route, List<int> bytes) async {
    try {
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic> ||
          body['type'] != 'PONG' ||
          body['os'] != 'android') {
        return;
      }
      final id = body['id'];
      final alias = body['alias'];
      final control = body['port'];
      final native = body['nativePort'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 128 ||
          id == _advertisement?['id'] ||
          alias is! String ||
          alias.isEmpty ||
          alias.length > 128 ||
          control is! int ||
          control < 1 ||
          control > 65535 ||
          (native != null &&
              (native is! int || native < 1 || native > 65535))) {
        return;
      }
      if (!_active || !identical(_routes[route.serial], route)) {
        return;
      }
      if (route.peer?.deviceId != id ||
          route.guestControl != control ||
          route.guestNative != native) {
        route.peer = null;
        _publish();
        await _releaseEndpoints(route);
        route.guestControl = control;
        route.guestNative = native as int?;
        route.controlPort = await host.addRedirection(
          route.serial,
          'tcp',
          control,
        );
        if (native != null) {
          route.nativePort = await host.addRedirection(
            route.serial,
            'tcp',
            native,
          );
          await host.addRedirection(
            route.serial,
            'udp',
            native,
            hostPort: route.nativePort,
          );
          route.nativeUdp = true;
        }
      }
      if (!_active || !identical(_routes[route.serial], route)) {
        return;
      }
      route.peer = LanDiscoveredPeer(
        deviceId: id,
        alias: alias,
        ip: '127.0.0.1',
        controlPort: route.controlPort!,
        advertisedNativePort: route.nativePort,
        os: 'android',
        deviceType: LanDeviceType.mobile,
        lastSeen: DateTime.now(),
      );
      _publish();
    } on Object catch (error) {
      route.peer = null;
      await _releaseEndpoints(route);
      _publish();
      _warning(error);
    }
  }

  void _publish() {
    if (_closed) {
      return;
    }
    final cutoff = DateTime.now().subtract(
      LanDiscoveryService.devicePresenceTtl,
    );
    _peers.add(
      _active
          ? _routes.values
                .map((r) => r.peer)
                .whereType<LanDiscoveredPeer>()
                .where((peer) => peer.lastSeen.isAfter(cutoff))
                .toList()
          : [],
    );
  }

  _EmulatorRoute? _routeFor(LanDiscoveredPeer peer) {
    if (!_active || InternetAddress.tryParse(peer.ip)?.isLoopback != true) {
      return null;
    }
    for (final route in _routes.values) {
      if (route.peer?.deviceId == peer.deviceId &&
          (peer.controlPort == route.controlPort ||
              peer.controlPort == route.guestControl)) {
        return route;
      }
    }
    return null;
  }

  @override
  LanDiscoveredPeer routePeer(LanDiscoveredPeer peer) =>
      _routeFor(
        peer,
      )?.peer?.copyWith(alias: peer.alias, lastSeen: peer.lastSeen) ??
      peer;

  @override
  int? nativePortFor(LanDiscoveredPeer peer, int advertisedPort) {
    if (InternetAddress.tryParse(peer.ip)?.isLoopback != true) {
      return advertisedPort;
    }
    final route = _routeFor(peer);
    return route != null && route.guestNative == advertisedPort
        ? route.nativePort
        : null;
  }

  void _warning(Object error) {
    if (_warned || !_active) {
      return;
    }
    _warned = true;
    logger.warning(
      'Local emulator discovery unavailable',
      details: 'errorType=${error.runtimeType}',
    );
  }

  Future<void> _remove(_EmulatorRoute route, String protocol, int? port) async {
    if (port == null) {
      return;
    }
    try {
      await host.removeRedirection(route.serial, protocol, port);
    } on Object catch (error) {
      _warning(error);
    }
  }

  Future<void> _releaseEndpoints(_EmulatorRoute route) async {
    if (route.nativeUdp) await _remove(route, 'udp', route.nativePort);
    await _remove(route, 'tcp', route.nativePort);
    await _remove(route, 'tcp', route.controlPort);
    route.nativeUdp = false;
    route.nativePort = null;
    route.controlPort = null;
  }

  Future<void> _release(_EmulatorRoute route) async {
    await route.subscription?.cancel();
    route.socket.close();
    await _releaseEndpoints(route);
    await _remove(route, 'udp', route.discoveryPort);
  }

  @override
  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    _active = false;
    _timer?.cancel();
    _timer = null;
    await _polling;
    await Future.wait(_operations.toList());
    for (final route in _routes.values) {
      await _release(route);
    }
    _routes.clear();
    _publish();
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await stop();
    _closed = true;
    await _peers.close();
  }
}

class _EmulatorRoute {
  _EmulatorRoute(this.serial, this.discoveryPort, this.socket);
  final String serial;
  final int discoveryPort;
  final RawDatagramSocket socket;
  StreamSubscription<RawSocketEvent>? subscription;
  int? guestControl;
  int? guestNative;
  int? controlPort;
  int? nativePort;
  bool nativeUdp = false;
  bool updating = false;
  LanDiscoveredPeer? peer;
}
