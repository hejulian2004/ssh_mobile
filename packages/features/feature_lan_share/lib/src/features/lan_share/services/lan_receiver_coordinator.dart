// LAN Share 接收器协调器。
//
// 该 library 保留 Receiver 的公共类型和所有状态所有权；按职责拆分的
// 生命周期、观察、传输策略实现位于同一 library 的 part 文件中。

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:uuid/uuid.dart';

import '../../../data/database/lan_share_database.dart';
import '../../../data/repositories/lan_share_history_repository.dart';
import '../../../domain/lan_share_ports.dart';
import '../../../services/lan_share/lan_discovery_service.dart';
import '../../../services/lan_share/lan_native_transfer_coordinator.dart';
import '../../../services/lan_share/lan_peer_trust.dart';
import '../../../services/lan_share/lan_security_service.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import '../../../services/relay/relay_enrollment_service.dart';
import '../viewmodels/lan_share_viewmodel.dart';
import 'lan_native_peer_registry.dart';
import 'lan_relay_coordinator.dart';

export 'lan_relay_coordinator.dart' show LanRelayStatus;

part 'lan_receiver_coordinator_incoming.dart';
part 'lan_receiver_coordinator_lifecycle.dart';
part 'lan_receiver_coordinator_observation.dart';
part 'lan_receiver_coordinator_relay.dart';

/// 负责 LAN Receiver 的激活、停用和最终释放。
final class LanReceiverCoordinator extends ChangeNotifier {
  /// 创建一个只使用注入依赖的 LAN 接收器协调器。
  LanReceiverCoordinator({
    required this.appSettings,
    required this.logger,
    required this.dataProtection,
    required this.networkIdentity,
    required this.networkAccess,
    required this.bootstrapClient,
    required this.historyRepository,
    required this.networkRuntime,
    this.localAddressSelectionPort =
        const LanShareSingleCandidateLocalAddressSelection(),
    LanPeerTrustStore? peerTrustStore,
    this.initializeNetwork = true,
    this.transferServiceOverride,
    this.discoveryServiceOverride,
    this.storageServiceOverride,
  }) : peerTrustStore = peerTrustStore ?? LanPeerTrustStore(),
       _ownsPeerTrustStore = peerTrustStore == null;

  /// App Scope 的 LAN 设置和身份配置。
  final LanShareSettingsPort appSettings;

  /// App Scope 的日志适配器。
  final LanShareLoggerPort logger;

  /// Module 注入的数据库敏感字段保护服务。
  final LanShareDataProtectionPort dataProtection;

  /// App Scope 的稳定 QUIC 身份加载端口。
  final LanShareNetworkIdentityPort networkIdentity;

  /// 访问 App 级共享原生网络 Facade 的端口。
  final LanShareNetworkAccessPort networkAccess;

  /// App Shell 注入的无 Bearer Bootstrap 客户端。
  final BootstrapClient bootstrapClient;

  /// Module 所有的历史 Repository。
  final LanShareHistoryRepository historyRepository;

  /// App Scope 唯一网络运行时，用于按需准备 native runtime Capability。
  final NetworkRuntime networkRuntime;

  /// App-selected route-aware Automatic local IPv4 selector.
  final LanShareLocalAddressSelectionPort localAddressSelectionPort;

  /// Module-owned atomic trust store. The Coordinator only consumes it and
  /// never treats discovery/reachability as trust.
  final LanPeerTrustStore peerTrustStore;
  final bool _ownsPeerTrustStore;

  /// The single Feature owner for native peer registration and revocation.
  late final LanNativePeerRegistry peerRegistry = LanNativePeerRegistry(
    trustStore: peerTrustStore,
  );

  /// 测试中可关闭监听器和原生网络初始化，但仍保留服务装配流程。
  final bool initializeNetwork;

  /// 可选的 LAN 传输服务覆盖；缺省时由初始化流程内部构造真实服务。
  ///
  /// 供测试注入 fake，避免在测试环境触发真实 HTTPS 绑定、TLS 证书 isolate
  /// 生成或 multicast 网络路径。
  final LanTransferService? transferServiceOverride;

  /// 可选的 LAN 发现服务覆盖；缺省时由初始化流程内部构造真实服务。
  final LanDiscoveryService? discoveryServiceOverride;

  /// 可选的 LAN 存储服务覆盖；缺省时由初始化流程内部构造真实服务。
  final LanStorageService? storageServiceOverride;

  LanDiscoveryService? _discoveryService;
  LanSecurityService? _securityService;
  LanStorageService? _lanStorageService;
  LanTransferService? _transferService;
  LanRelayCoordinator? _relayCoordinator;
  LanNativeTransferCoordinator? _nativeTransferCoordinator;
  NetworkFacade? _networkFacade;
  bool _receiverActive = false;

  final StreamController<LanPairingRequest> _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final Map<String, LanPairingRequest> _latestPairingRequests = {};
  StreamSubscription<LanPairingRequest>? _pairingInviteSubscription;
  StreamSubscription<LanDiscoveredPeer>? _announcedPeerSubscription;
  StreamSubscription<List<LanDiscoveredPeer>>? _discoveredPeersSubscription;
  StreamSubscription<LanDiscoveredPeer>? _handshakeSuccessSubscription;
  StreamSubscription<IncomingTransferOffer>? _nativeOfferSubscription;
  final StreamController<IncomingTransferOffer> _incomingTransferController =
      StreamController<IncomingTransferOffer>.broadcast();

  bool _initialized = false;
  bool _disposed = false;
  bool _notifierDisposed = false;
  Future<void>? _initFuture;
  Future<void>? _activationFuture;
  Future<void>? _closeFuture;
  LanShareViewModel? _viewModel;
  Future<LanShareViewModel>? _viewModelFuture;

  /// 接收器资源是否已完成初始化。
  bool get initialized => _initialized;

  /// 接收器当前是否正在监听和广播。
  bool get receiverActive => _receiverActive;

  /// 共享的页面 ViewModel（已就绪时返回）。
  LanShareViewModel? get viewModel => _viewModel;

  /// 初始化完成后返回共享发现服务。
  LanDiscoveryService? get discoveryService => _discoveryService;

  /// 初始化完成后返回共享 LAN 安全服务。
  LanSecurityService? get securityService => _securityService;

  /// 初始化完成后返回唯一 LAN 存储服务。
  LanStorageService? get lanStorageService => _lanStorageService;

  /// 初始化完成后返回唯一 LAN 传输服务。
  LanTransferService? get transferService => _transferService;

  /// 初始化完成后返回 Relay enrollment 服务。
  LanRelayEnrollmentPort? get relayEnrollmentService =>
      _relayCoordinator?.enrollmentService;

  /// 当前是否已启用原生 Relay 配置。
  bool get nativeRelayActive => _relayCoordinator?.nativeRelayActive ?? false;

  /// 当前 Relay 配置、连接和自动重连状态。
  LanRelayStatus get relayStatus =>
      _relayCoordinator?.status ??
      LanRelayStatus(
        endpoint: appSettings.relayEndpoint,
        state: RelayConnectionState.disconnected,
        enrolled: false,
        reconnectAttempt: 0,
      );

  /// 可用时返回 App Shell 注入的网络 Facade。
  NetworkFacade? get networkFacade => _networkFacade;

  /// 当前 runtime generation 的 Network V2 file-transfer coordinator。
  LanNativeTransferCoordinator? get nativeTransferCoordinator =>
      _nativeTransferCoordinator;

  /// 传入传输申请的超时时间。
  Duration get incomingOfferTimeout =>
      _nativeTransferCoordinator?.offerTimeout ??
      LanNativeTransferCoordinator.defaultOfferTimeout;

  /// 接收器初始化后发布原生传入传输申请。
  Stream<IncomingTransferOffer> get nativeIncomingTransferOffers =>
      _incomingTransferController.stream;

  /// Flutter 兼容入口；正式 Module 会等待 [close] 完成。
  @override
  void dispose() {
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
    unawaited(
      close().catchError((Object error) {
        logger.warning(
          'LAN receiver cleanup failed',
          details: 'errorType=${error.runtimeType}',
        );
      }),
    );
  }

  void _disposeNotifier() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    super.dispose();
  }

  void _notifyListeners() {
    notifyListeners();
  }
}
