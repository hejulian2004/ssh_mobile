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
      _udpSocketSubscription = socket.listen((event) {
        if (!identical(_udpSocket, socket)) return;
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram == null) return;
          try {
            final messageStr = utf8.decode(datagram.data);
            final json = jsonDecode(messageStr) as Map<String, dynamic>;

            /// 注册一个通过 UDP 发现的对端，并发布设备快照。
            void registerDiscoveredPeerFromDatagram(
              String rawId,
              Map<String, dynamic> json,
              String hostIp,
            ) {
              final id = _extractCleanId(rawId);
              if (id.isEmpty || id == currentDeviceId) return;
              final cleanHostIp = hostIp.startsWith('::ffff:')
                  ? hostIp.substring(7)
                  : hostIp;
              final peer = LanDiscoveredPeer(
                deviceId: id,
                alias: json['alias'] as String? ?? 'Device',
                ip: cleanHostIp,
                controlPort:
                    (json['port'] as num?)?.toInt() ??
                    LanDiscoveryService.defaultPort,
                advertisedNativePort: (json['nativePort'] as num?)?.toInt(),
                deviceType: _guessDeviceType(json['os'] as String? ?? ''),
                os: json['os'] as String? ?? 'Unknown',
                lastSeen: DateTime.now(),
              );
              _peerMap[id] = peer;
              _notifyPeersUpdated();
            }

            final type = json['type'] as String?;
            if (type == 'PING') {
              final senderId = json['id'] as String?;
              if (senderId != null && senderId != currentDeviceId) {
                _sendUdpPong(
                  datagram.address,
                  listeningHttpPort,
                  nativePort: nativePort,
                );
                registerDiscoveredPeerFromDatagram(
                  senderId,
                  json,
                  datagram.address.address,
                );
              }
            } else if (type == 'PONG') {
              final id = json['id'] as String?;
              if (id != null && id != currentDeviceId) {
                registerDiscoveredPeerFromDatagram(
                  id,
                  json,
                  datagram.address.address,
                );
              }
            } else if (type == 'BYE' ||
                type == 'DISCONNECT' ||
                type == 'OFFLINE') {
              final id = json['id'] as String?;
              if (id != null) {
                final cleanId = _extractCleanId(id);
                _peerMap.remove(cleanId);
                _peerMap.remove(id);
                _notifyPeersUpdated();
              }
            }
          } catch (_) {}
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

  /// 向发现 ping 发送 UDP 响应。
  void _sendUdpPong(
    InternetAddress targetAddress,
    int port, {
    int? nativePort,
  }) {
    final socket = _udpSocket;
    if (socket == null) return;
    try {
      final payload = jsonEncode({
        'type': 'PONG',
        'id': currentDeviceId,
        'alias': currentDeviceAlias,
        'port': port,
        'nativePort': ?nativePort,
        'os': Platform.operatingSystem,
      });
      final bytes = utf8.encode(payload);
      socket.send(bytes, targetAddress, LanDiscoveryService.udpDiscoveryPort);
    } catch (_) {}
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
