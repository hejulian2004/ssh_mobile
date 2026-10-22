// mDNS/UDP advertising lifecycle and discovery fallback path.

part of 'lan_discovery_service.dart';

extension LanDiscoveryAdvertisingOperations on LanDiscoveryService {
  /// 启动 mDNS 注册，向附近对端广播本设备。
  Future<NetworkResult<void>> startAdvertising({
    int port = LanDiscoveryService.defaultPort,
    int? nativePort,
  }) {
    if (_closing || _closed) {
      return Future.value(
        _closedFailure<void>(NetworkOperation.startAdvertising),
      );
    }
    final generation = ++_advertisingGeneration;
    return _enqueueAdvertisingLifecycle(() async {
      if (_closing || _closed || generation != _advertisingGeneration) {
        return _closedFailure<void>(NetworkOperation.startAdvertising);
      }
      try {
        // Repeated starts are a restart, not an additional registration. Close
        // the previous mDNS/UDP owners before creating the next generation.
        if (_advertisedPort != null ||
            _registration != null ||
            _udpSocket != null) {
          await performStopAdvertising();
        }
        await performStartAdvertising(port, nativePort: nativePort);
        if (_closing || _closed || generation != _advertisingGeneration) {
          await performStopAdvertising();
          return _closedFailure<void>(NetworkOperation.startAdvertising);
        }
        _advertisedPort = port;
        _advertisedNativePort = nativePort;
        return const NetworkSuccess<void>(null);
      } catch (error) {
        return NetworkFailure(
          const NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'LAN advertising failed.',
            operation: NetworkOperation.startAdvertising,
          ),
        );
      }
    });
  }

  /// 停止 mDNS 注册。
  Future<NetworkResult<void>> stopAdvertising() {
    _advertisingGeneration++;
    _advertisedPort = null;
    _advertisedNativePort = null;
    return _enqueueAdvertisingLifecycle(() async {
      try {
        await performStopAdvertising();
        return const NetworkSuccess<void>(null);
      } catch (error) {
        return NetworkFailure(
          const NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'LAN advertising stop failed.',
            operation: NetworkOperation.stopAdvertising,
          ),
        );
      }
    });
  }

  Future<void> _performStartAdvertising(int port, {int? nativePort}) async {
    try {
      String? selectedIp;
      try {
        final result = await _localAddressResolver.resolve();
        if (result case LanShareLocalAddressSelected(:final candidate)) {
          selectedIp = candidate.address;
        }
      } on Object {
        // mDNS can still advertise its resolved service host when no unique
        // TXT IPv4 can be selected; never publish a guessed or loopback IP.
      }
      _registration = await nsd.register(
        nsd.Service(
          name: '$currentDeviceAlias ($currentDeviceId)',
          type: LanDiscoveryService.serviceType,
          port: port,
          txt: {
            'id': utf8.encode(currentDeviceId),
            'alias': utf8.encode(currentDeviceAlias),
            'os': utf8.encode(Platform.operatingSystem),
            if (selectedIp != null) 'ip': utf8.encode(selectedIp),
            if (nativePort != null)
              'nativePort': utf8.encode(nativePort.toString()),
          },
        ),
      );
      debugPrint(
        '[LanDiscoveryService] mDNS Advertising started on port $port',
      );
    } catch (e) {
      debugPrint('[LanDiscoveryService] mDNS Advertising error: $e');
    }

    await _startUdpListener(port, nativePort: nativePort);
    await _bridgeBinding.start(
      LanDiscoveryService.createUdpPingPayload(
        deviceId: currentDeviceId,
        alias: currentDeviceAlias,
        os: Platform.operatingSystem,
        port: port,
        nativePort: nativePort,
      ),
    );
  }

  Future<void> _performStopAdvertising() async {
    await _bridgeBinding.stop();
    await _sendUdpDisconnect();
    if (_registration != null) {
      try {
        await nsd.unregister(_registration!);
        _registration = null;
      } catch (e) {
        debugPrint('[LanDiscoveryService] mDNS Unregister error: $e');
      }
    }
    await _stopUdpListener();
  }

  Future<T> _enqueueAdvertisingLifecycle<T>(Future<T> Function() operation) {
    final next = _advertisingLifecycle.then((_) => operation());
    _advertisingLifecycle = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  /// UDP 备用 ping 数据包监听器。
  /// 启动接收发现广播的 UDP 备用监听器。
  Future<void> _startUdpListener(
    int listeningHttpPort, {
    int? nativePort,
  }) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        LanDiscoveryService.udpDiscoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      if (_closing || _closed) {
        socket.close();
        return;
      }
      _udpSocket = socket;
      socket.broadcastEnabled = true;
      final handler = LanDiscoveryDatagramHandler(
        advertisement: LanDiscoveryService.createUdpPingPayload(
          deviceId: currentDeviceId,
          alias: currentDeviceAlias,
          os: Platform.operatingSystem,
          port: listeningHttpPort,
          nativePort: nativePort,
        ),
        reply: (bytes, address, port) =>
            socket.send(bytes, InternetAddress(address), port),
        onPeer: (peer) {
          _nsdPeerIds.remove(peer.deviceId);
          _peerMap[peer.deviceId] = peer;
          LanDiscoveryPeerOperations(this)._notifyPeersUpdated();
        },
        onRemove: (id) {
          _nsdPeerIds.remove(id);
          _peerMap.remove(id);
          LanDiscoveryPeerOperations(this)._notifyPeersUpdated();
        },
      );
      _udpSocketSubscription = socket.listen((event) {
        if (!identical(_udpSocket, socket) || event != RawSocketEvent.read) {
          return;
        }
        final datagram = socket.receive();
        if (datagram != null) {
          handler.handle(
            datagram.data,
            datagram.address.address,
            datagram.port,
          );
        }
      });
    } catch (e) {
      debugPrint('[LanDiscoveryService] UDP listener error: $e');
    }
  }

  /// 停止 UDP 发现监听器。
  Future<void> _stopUdpListener() async {
    final socket = _udpSocket;
    final subscription = _udpSocketSubscription;
    _udpSocket = null;
    _udpSocketSubscription = null;
    try {
      await subscription?.cancel();
    } finally {
      socket?.close();
    }
  }

  /// 向已发现对端广播 V2 离线通知。
  Future<void> _sendUdpDisconnect() async {
    final socket = _udpSocket;
    if (socket == null) return;
    try {
      final payload = jsonEncode({
        'type': 'BYE',
        'id': currentDeviceId,
        'alias': currentDeviceAlias,
        'os': Platform.operatingSystem,
      });
      final bytes = utf8.encode(payload);
      socket.send(
        bytes,
        InternetAddress('255.255.255.255'),
        LanDiscoveryService.udpDiscoveryPort,
      );

      final localIps = await LanDiscoveryService.getLocalIpAddresses();
      if (!identical(_udpSocket, socket)) return;
      for (final ip in localIps) {
        final subnetBroadcast = _calculateSubnetBroadcast(ip);
        if (subnetBroadcast != '255.255.255.255') {
          socket.send(
            bytes,
            InternetAddress(subnetBroadcast),
            LanDiscoveryService.udpDiscoveryPort,
          );
        }
      }
      debugPrint('[LanDiscoveryService] UDP Disconnect/BYE broadcast sent');
    } catch (e) {
      debugPrint('[LanDiscoveryService] Failed to send UDP disconnect: $e');
    }
  }

  /// 前 30 秒每秒快速扫描；30 秒内没有发现设备时自动停止。
  /// 启动限速 UDP 发现广播循环。
  void _startRateLimitedUdpBroadcast() {
    _udpBroadcastCount = 0;
    _udpBroadcastTimer?.cancel();
    _sendUdpPing();

    _scheduleNextUdpPing();
  }

  /// 根据扫描速率限制安排下一次 UDP 发现 ping。
  void _scheduleNextUdpPing() {
    if (!_isScanning || _closing || _closed) return;
    _udpBroadcastCount++;

    // 保持低频扫描，使热点或网络配置完成后加入的对端仍能出现，
    // 不要求用户重新启动发现。
    final int delaySeconds = _udpBroadcastCount < 10 ? 1 : 5;

    _udpBroadcastTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_isScanning && !_closing && !_closed) {
        _sendUdpPing();
        _scheduleNextUdpPing();
      }
    });
  }

  /// 返回 [ip] 是否属于私有 IPv4 地址范围。
  bool _isPrivateIPv4(String ip) {
    try {
      final parts = ip.split('.');
      if (parts.length != 4) return false;
      final first = int.parse(parts[0]);
      final second = int.parse(parts[1]);
      if (first == 192 && second == 168) return true;
      if (first == 10) return true;
      if (first == 172 && second >= 16 && second <= 31) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 计算 UDP 备用路径使用的 /24 广播地址。
  String _calculateSubnetBroadcast(String ip) {
    final parts = ip.split('.');
    if (parts.length == 4) {
      return '${parts[0]}.${parts[1]}.${parts[2]}.255';
    }
    return '255.255.255.255';
  }

  /// 向全局、子网和限速主机目标发送发现 ping。
  Future<void> _sendUdpPing() async {
    final socket = _udpSocket;
    if (socket == null || !_isScanning || _closing || _closed) return;
    try {
      final payload = jsonEncode(
        LanDiscoveryService.createUdpPingPayload(
          deviceId: currentDeviceId,
          alias: currentDeviceAlias,
          os: Platform.operatingSystem,
          port: _advertisedPort ?? LanDiscoveryService.defaultPort,
          nativePort: _advertisedNativePort,
        ),
      );
      final bytes = utf8.encode(payload);

      // 1. 发送到全局广播地址。
      socket.send(
        bytes,
        InternetAddress('255.255.255.255'),
        LanDiscoveryService.udpDiscoveryPort,
      );

      // 2. 发送到所有本地子网广播地址（热点 AP 模式必须支持）。
      final localIps = await LanDiscoveryService.getLocalIpAddresses();
      if (!identical(_udpSocket, socket) ||
          !_isScanning ||
          _closing ||
          _closed) {
        return;
      }
      for (final ip in localIps) {
        final subnetBroadcast = _calculateSubnetBroadcast(ip);
        if (subnetBroadcast != '255.255.255.255') {
          socket.send(
            bytes,
            InternetAddress(subnetBroadcast),
            LanDiscoveryService.udpDiscoveryPort,
          );
        }

        // 3. 周期性的 /24 单播备用路径可帮助屏蔽广播的热点实现。
        // 不要每秒重复发送。
        final shouldProbeSubnet =
            _udpBroadcastCount <= 1 || _udpBroadcastCount % 6 == 0;
        if (shouldProbeSubnet && _isPrivateIPv4(ip)) {
          final parts = ip.split('.');
          if (parts.length == 4) {
            final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
            final selfHost = int.tryParse(parts[3]);
            for (int i = 1; i <= 254; i++) {
              if (i == selfHost) continue; // 跳过本机。
              try {
                socket.send(
                  bytes,
                  InternetAddress('$prefix.$i'),
                  LanDiscoveryService.udpDiscoveryPort,
                );
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}
  }
}
