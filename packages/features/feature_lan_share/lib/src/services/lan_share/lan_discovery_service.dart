// LAN Control V2 发现、广播与 WebShare 生命周期服务。
//
// 设备事件保持类型化事件流，生命周期和 WebShare 命令返回统一
// NetworkResult 模型。

import 'dart:async';

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'lan_multicast_lock.dart';
import 'package:network_sdk/network_sdk.dart';
import 'lan_share_models.dart';
import 'lan_security_service.dart';
import 'lan_storage_service.dart';
import 'lan_transfer_protocol.dart';
import 'lan_transfer_service.dart';
import 'lan_web_share_request_handler.dart';
import 'lan_local_address_selection.dart';
import '../../domain/lan_share_ports.dart';

part 'lan_web_share_server.dart';
part 'lan_web_share_lifecycle.dart';
part 'lan_discovery_advertising.dart';
part 'lan_discovery_peers.dart';

/// 负责 LAN 设备发现（mDNS 与 UDP 备用路径）以及 Web Share 服务。
class LanDiscoveryService {
  static const String serviceType = '_ssh-mobile-share._tcp';
  static const int defaultPort = 53317;
  static const int udpDiscoveryPort = 53318;
  // 手动输入和二维码解析得到的对端需要比一分钟配对会话存活更久，
  // 避免清理逻辑使正在显示的 PIN 界面失效。
  static const Duration devicePresenceTtl = Duration(seconds: 90);
  static const Duration _deviceCleanupInterval = Duration(seconds: 10);

  final String currentDeviceId;
  String currentDeviceAlias;
  final LanMulticastLock multicastLock;
  final LanShareLocalAddressSelectionPort localAddressSelectionPort;
  final LanShareLocalIpv4CandidateSource localAddressCandidateSource;
  late final LanShareLocalAddressResolver _localAddressResolver =
      LanShareLocalAddressResolver(
        candidateSource: localAddressCandidateSource,
        selectionPort: localAddressSelectionPort,
      );

  nsd.Registration? _registration;
  int? _advertisedPort;
  int? _advertisedNativePort;
  nsd.Discovery? _discovery;
  RawDatagramSocket? _udpSocket;
  StreamSubscription<RawSocketEvent>? _udpSocketSubscription;
  Timer? _udpBroadcastTimer;
  Timer? _deviceCleanupTimer;
  int _udpBroadcastCount = 0;
  int _discoveryGeneration = 0;
  int _advertisingGeneration = 0;
  Future<void> _discoveryLifecycle = Future<void>.value();
  Future<void> _advertisingLifecycle = Future<void>.value();
  Future<void> _webShareLifecycle = Future<void>.value();
  final Set<Future<void>> _webShareRequestOperations = {};
  Future<void>? _closeFuture;
  bool _closing = false;
  bool _closed = false;

  final _discoveredPeersController =
      StreamController<List<LanDiscoveredPeer>>.broadcast();
  final Map<String, LanDiscoveredPeer> _peerMap = {};

  bool _isScanning = false;

  /// 当前是否正在运行主动发现。
  bool get isScanning => _isScanning;

  /// 当前通过 mDNS 和 UDP 广播的原生 HTTPS 端口。
  int? get advertisedPort => _advertisedPort;

  /// 当前广播的原生可靠传输端口。
  int? get advertisedNativePort => _advertisedNativePort;

  HttpServer? _webShareServer;
  LanWebShareRequestHandler? _webShareRequestHandler;
  bool _isWebShareActive = false;

  /// 当前是否正在运行 WebShare 服务。
  bool get isWebShareActive => _isWebShareActive;
  String? _webShareUrl;

  /// WebShare 激活时返回当前 URL。
  String? get webShareUrl => _webShareUrl;
  String? _webShareToken;

  String? _customIp;

  LanShareLocalAddressSelectionResult? _webShareAddressSelectionResult;

  /// 返回 WebShare URL 使用的可选 IP 覆盖值。
  String? get customIp => _customIp;

  /// Latest local address resolution result, retained for Feature-local UI.
  LanShareLocalAddressSelectionResult? get webShareAddressSelectionResult =>
      _webShareAddressSelectionResult;

  /// 使用注入的地址 selector 和可选的平台组播锁创建发现服务。
  LanDiscoveryService({
    required this.currentDeviceId,
    required this.currentDeviceAlias,
    required this.localAddressSelectionPort,
    LanShareLocalIpv4CandidateSource? localAddressCandidateSource,
    LanMulticastLock? multicastLock,
  }) : localAddressCandidateSource =
           localAddressCandidateSource ??
           const DartLanShareLocalIpv4CandidateSource(),
       multicastLock = multicastLock ?? PlatformLanMulticastLock();

  /// 动态更新当前设备别名；若正在广播则重新启动广播。
  Future<NetworkResult<void>> updateDeviceAlias(String newAlias) async {
    if (_closing || _closed) {
      return _closedFailure<void>(NetworkOperation.startAdvertising);
    }
    if (currentDeviceAlias == newAlias) {
      return const NetworkSuccess<void>(null);
    }
    currentDeviceAlias = newAlias;
    final activePort = _advertisedPort;
    final activeNativePort = _advertisedNativePort;
    if (activePort != null) {
      debugPrint(
        '[LanDiscoveryService] Restarting advertising with new alias: $newAlias',
      );
      await stopAdvertising();
      await startAdvertising(port: activePort, nativePort: activeNativePort);
    }
    return const NetworkSuccess<void>(null);
  }

  /// 返回当前 eligible IPv4 candidates，interface index 仅供本次选择使用。
  static Future<List<LanShareLocalIpv4Candidate>> getLocalIpv4Candidates() =>
      const DartLanShareLocalIpv4CandidateSource().loadCandidates();

  /// 返回可用于显示或复制的本机 IPv4 地址。
  static Future<List<String>> getLocalIpAddresses() async {
    try {
      final candidates = await getLocalIpv4Candidates();
      return candidates.map((candidate) => candidate.address).toList();
    } catch (e) {
      debugPrint('[LanDiscoveryService] Error listing network interfaces: $e');
      return const [];
    }
  }

  /// 获取映射到网络接口名称的本地 IPv4 地址。
  static Future<Map<String, String>> getLocalIpInterfaces() async {
    try {
      final candidates = await getLocalIpv4Candidates();
      return {
        for (final candidate in candidates)
          candidate.address: candidate.interfaceName,
      };
    } catch (e) {
      debugPrint('[LanDiscoveryService] Error listing network interfaces: $e');
      return const {};
    }
  }

  /// 执行平台 mDNS/UDP 广播初始化。
  @protected
  Future<void> performStartAdvertising(int port, {int? nativePort}) async {
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
          type: serviceType,
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
  }

  /// 执行平台 mDNS/UDP 广播清理。
  @protected
  Future<void> performStopAdvertising() async {
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

  /// 启动主动发现（mDNS 与限速 UDP 广播备用路径）。
  Future<NetworkResult<void>> startDiscovery() async {
    if (_closing || _closed) {
      return _closedFailure<void>(NetworkOperation.startDiscovery);
    }
    if (_isScanning) return const NetworkSuccess<void>(null);
    _isScanning = true;
    final generation = ++_discoveryGeneration;
    _peerMap.clear();
    _notifyPeersUpdated();

    try {
      await _enqueueDiscoveryLifecycle(
        () => _performStartDiscovery(generation),
      );
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'LAN discovery start failed.',
          operation: NetworkOperation.startDiscovery,
        ),
      );
    }
  }

  /// 为一个串行化生命周期代次启动发现资源。
  Future<void> _performStartDiscovery(int generation) async {
    if (!_isCurrentDiscoveryStart(generation)) return;

    var multicastLockAcquired = false;
    try {
      await multicastLock.acquire();
      multicastLockAcquired = true;
    } catch (e) {
      debugPrint('[LanDiscoveryService] Multicast lock error: $e');
    }
    if (!_isCurrentDiscoveryStart(generation)) {
      if (multicastLockAcquired) {
        await _releaseMulticastLock();
      }
      return;
    }

    nsd.Discovery? discovery;
    try {
      discovery = await performStartDiscovery();
    } catch (e) {
      debugPrint('[LanDiscoveryService] mDNS Discovery error: $e');
    }
    if (!_isCurrentDiscoveryStart(generation)) {
      if (discovery != null) {
        await _stopNsdDiscovery(discovery);
      }
      if (multicastLockAcquired) {
        await _releaseMulticastLock();
      }
      return;
    }

    if (discovery != null) {
      _discovery = discovery;
      discovery.addListener(() {
        if (!_isCurrentDiscoveryStart(generation) ||
            !identical(_discovery, discovery)) {
          return;
        }
        for (final service in discovery!.services) {
          _handleDiscoveredNsdService(service);
        }
      });
      debugPrint('[LanDiscoveryService] mDNS Discovery started');
    }

    _startRateLimitedUdpBroadcast();
    _startDeviceCleanup();
  }

  /// 停止主动发现以节省电量和网络带宽。
  Future<NetworkResult<void>> stopDiscovery() async {
    final generation = ++_discoveryGeneration;
    _isScanning = false;
    _cancelDiscoveryTimers();
    try {
      await _enqueueDiscoveryLifecycle(() => _performStopDiscovery(generation));
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'LAN discovery stop failed.',
          operation: NetworkOperation.stopDiscovery,
        ),
      );
    }
  }

  /// 停止发现资源并释放组播锁。
  Future<void> _performStopDiscovery(int generation) async {
    // 清理必须无条件执行。过期的启动任务可能在请求 stopDiscovery() 后仍创建资源。
    _cancelDiscoveryTimers();
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      await _stopNsdDiscovery(discovery);
    }

    // 生命周期操作已串行化，因此当前停止操作释放共享锁前，更新代次无法获取它。
    await _releaseMulticastLock();
    if (generation == _discoveryGeneration || !_isScanning) {
      debugPrint('[LanDiscoveryService] Discovery stopped');
    }
  }

  /// 停止一个 mDNS 发现实例，同时保持清理安全性。
  Future<void> _stopNsdDiscovery(nsd.Discovery discovery) async {
    try {
      await performStopDiscovery(discovery);
    } catch (e) {
      debugPrint('[LanDiscoveryService] mDNS Stop Discovery error: $e');
    }
  }

  /// 释放平台组播锁。
  Future<void> _releaseMulticastLock() async {
    try {
      await multicastLock.release();
    } catch (e) {
      debugPrint('[LanDiscoveryService] Multicast unlock error: $e');
    }
  }

  /// 取消发现广播和过期设备定时器。
  void _cancelDiscoveryTimers() {
    _deviceCleanupTimer?.cancel();
    _deviceCleanupTimer = null;
    _udpBroadcastTimer?.cancel();
    _udpBroadcastTimer = null;
  }

  /// 返回 [generation] 是否仍是当前主动发现请求。
  bool _isCurrentDiscoveryStart(int generation) =>
      !_closing &&
      !_closed &&
      _isScanning &&
      generation == _discoveryGeneration;

  /// 串行化发现生命周期操作。
  Future<void> _enqueueDiscoveryLifecycle(Future<void> Function() operation) {
    final next = _discoveryLifecycle.then((_) => operation());
    _discoveryLifecycle = next.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      debugPrint('[LanDiscoveryService] Discovery lifecycle error: $error');
    });
    return next;
  }

  /// 创建平台 mDNS 发现实例。
  @protected
  Future<nsd.Discovery> performStartDiscovery() =>
      nsd.startDiscovery(serviceType);

  /// 停止平台 mDNS 发现实例。
  @protected
  Future<void> performStopDiscovery(nsd.Discovery discovery) =>
      nsd.stopDiscovery(discovery);

  /// 将一个 mDNS 服务记录转换为类型化 LAN 设备。
  void _handleDiscoveredNsdService(nsd.Service service) {
    final txt = service.txt ?? {};
    final rawId = txt['id'] != null
        ? utf8.decode(txt['id']!)
        : service.name ?? '';
    final id = _extractCleanId(rawId);
    if (id.isEmpty || id == currentDeviceId) return;

    final rawAlias = txt['alias'] != null
        ? utf8.decode(txt['alias']!)
        : service.name ?? 'Device';
    final alias = _extractCleanAlias(rawAlias);
    final os = txt['os'] != null ? utf8.decode(txt['os']!) : 'Unknown';
    var hostIp =
        service.host ?? (txt['ip'] != null ? utf8.decode(txt['ip']!) : '');
    if (hostIp.startsWith('::ffff:')) {
      hostIp = hostIp.substring(7);
    }
    final port = service.port ?? defaultPort;
    final nativePort = int.tryParse(
      txt['nativePort'] == null ? '' : utf8.decode(txt['nativePort']!),
    );

    if (hostIp.isEmpty) return;

    final peer = LanDiscoveredPeer(
      deviceId: id,
      alias: alias,
      ip: hostIp,
      controlPort: port,
      advertisedNativePort: nativePort,
      deviceType: _guessDeviceType(os),
      os: os,
      lastSeen: DateTime.now(),
    );

    _peerMap[id] = peer;
    _notifyPeersUpdated();
  }

  /// 将发现到的操作系统标签映射为功能使用的设备类别。
  LanDeviceType _guessDeviceType(String os) {
    final lower = os.toLowerCase();
    if (lower.contains('android') || lower.contains('ios')) {
      return LanDeviceType.mobile;
    }
    if (lower.contains('web')) {
      return LanDeviceType.webBrowser;
    }
    return LanDeviceType.desktop;
  }

  /// 构建稳定的 V2 UDP 发现载荷。
  @visibleForTesting
  static Map<String, Object> createUdpPingPayload({
    required String deviceId,
    required String alias,
    required String os,
    required int port,
    int? nativePort,
  }) {
    return {
      'type': 'PING',
      'id': deviceId,
      'alias': alias,
      'port': port,
      'nativePort': ?nativePort,
      'os': os,
    };
  }

  NetworkFailure<T> _closedFailure<T>(NetworkOperation operation) {
    return NetworkFailure<T>(
      NetworkError(
        code: NetworkErrorCode.ioError,
        message: 'LAN discovery service is closed.',
        operation: operation,
      ),
    );
  }

  /// 可等待且幂等地停止发现、广播、WebShare，再关闭事件流。
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    _closing = true;
    _discoveryGeneration++;
    _advertisingGeneration++;
    await Future.wait([
      stopDiscovery(),
      stopAdvertising(),
      stopWebShareServer(),
    ]);
    if (!_discoveredPeersController.isClosed) {
      await _discoveredPeersController.close();
    }
    _closed = true;
  }

  /// Flutter 同步生命周期入口；正式 owner 应等待 [close]。
  void dispose() {
    unawaited(close());
  }
}
