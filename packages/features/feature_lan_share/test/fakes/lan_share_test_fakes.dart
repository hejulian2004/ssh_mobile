import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';

final class FakeLanShareStrings extends Fake implements LanShareStrings {
  FakeLanShareStrings({this.english = true});

  final bool english;

  @override
  bool get isEnglish => english;

  @override
  String get accept => 'Accept';

  @override
  String get reject => 'Reject';

  @override
  String get networkIncomingTransferTitle => 'Incoming Transfer';

  @override
  String networkIncomingTransferDescription(
    String sender,
    String fileName,
    String size,
  ) => 'From $sender: $fileName ($size)';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName == #isEnglish ? english : '';
}

final class FakeLanShareSettings extends ChangeNotifier
    implements LanShareSettingsPort {
  FakeLanShareSettings({this.english = false, this.relayEndpoint = ''});

  final bool english;

  /// 已保存的 Relay origin；默认空字符串表示未配置。
  @override
  String relayEndpoint;
  final FakeLanShareStrings _strings = FakeLanShareStrings();

  @override
  LanShareLanguage get language =>
      english ? LanShareLanguage.en : LanShareLanguage.zh;

  @override
  bool get isEnglish => english;

  @override
  LanShareStrings get strings => _strings;

  @override
  String get lanDeviceId => 'test-device';

  @override
  String get lanDeviceAlias => 'Test Device';

  @override
  String get relayHost => '';

  @override
  int get relayPort => 443;

  @override
  bool get receiverEnabled => true;

  @override
  Future<void> ensureLanIdentity() async {}

  @override
  Future<void> setLanDeviceAlias(String alias) async {}

  @override
  Future<void> setRelayEndpoint(String endpoint) async {
    relayEndpoint = endpoint;
    notifyListeners();
  }

  @override
  Future<void> setRelayServer({
    required String host,
    required int port,
  }) async {}
}

final class FakeLanShareLogger implements LanShareLoggerPort {
  final List<String> warnings = [];

  @override
  void info(String message, {String? details}) {}

  @override
  void warning(String message, {String? details}) => warnings.add(message);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {}
}

final class FakeLanShareDataProtection implements LanShareDataProtectionPort {
  @override
  Future<String> encryptString(String value) async => 'encrypted:$value';

  @override
  Future<String> decryptString(String value) async =>
      value.startsWith('encrypted:') ? value.substring(10) : value;

  @override
  bool isEncrypted(String value) => value.startsWith('encrypted:');
}

final class FakeLanShareIdentity implements LanShareNetworkIdentityPort {
  int loadCalls = 0;

  @override
  Future<LanShareNetworkIdentityMaterial> loadOrCreate() async {
    loadCalls++;
    return LanShareNetworkIdentityMaterial(
      privateSeed: Uint8List(32),
      publicKey: Uint8List(32),
      x25519PrivateSeed: Uint8List(32),
      x25519PublicKey: Uint8List(32),
    );
  }
}

final class FakeLanShareNetworkAccessPort implements LanShareNetworkAccessPort {
  FakeLanShareNetworkAccessPort({
    this.networkFacade,
    this.networkFacades = const <NetworkFacade>[],
  });

  int borrowCalls = 0;

  /// 返回给协调器的 NetworkFacade；null 模拟 App Shell 未创建原生门面。
  final NetworkFacade? networkFacade;
  final List<NetworkFacade> networkFacades;

  @override
  Future<NetworkFacade?> borrowFacade() async {
    borrowCalls++;
    if (borrowCalls <= networkFacades.length) {
      return networkFacades[borrowCalls - 1];
    }
    return networkFacade;
  }
}

final class FakeLanShareNetworkRuntime implements NetworkRuntime {
  FakeLanShareNetworkRuntime({
    this.refuseWebSocketRelay = false,
    this.boundLocalPort = 43123,
  });

  int ensureCalls = 0;

  /// 按请求顺序记录已请求的 Capability。
  final List<NetworkCapability> requestedCapabilities = <NetworkCapability>[];

  /// 为 true 时，`webSocketRelay` 请求抛出 `UnsupportedError`。
  final bool refuseWebSocketRelay;
  final int? boundLocalPort;
  bool disposed = false;

  @override
  NetworkRuntimeState get state =>
      disposed ? NetworkRuntimeState.disposed : NetworkRuntimeState.idle;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 0,
    readyCapabilities: const <NetworkCapability>[],
    boundLocalPort: boundLocalPort,
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {
    ensureCalls++;
    requestedCapabilities.add(capability);
    if (refuseWebSocketRelay &&
        capability == NetworkCapability.webSocketRelay) {
      throw UnsupportedError(
        'Network capability is unavailable: ${capability.label}',
      );
    }
  }

  @override
  Future<NetworkCommandGateway> openCommandGateway() async =>
      throw UnsupportedError('fake runtime has no command gateway');

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async =>
      throw UnsupportedError('fake runtime has no realtime gateway');

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 记录 Relay 配置调用且支持受控生命周期的 fake NetworkFacade。
final class FakeLanShareNetworkService implements NetworkFacade {
  final StreamController<NetworkEvent> _events =
      StreamController<NetworkEvent>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int configureRelayCalls = 0;
  int disconnectRelayCalls = 0;
  int connectPeerCalls = 0;
  int registerPeerCalls = 0;
  int removePeerCalls = 0;
  int transferFileCalls = 0;
  SdkPeerConfig? lastPeerConfig;
  SdkPeerConfig? lastRegisteredPeerConfig;
  int _eventSequence = 0;
  bool disposed = false;

  void emitEvent(NetworkEvent event) => _events.add(event);

  @override
  Stream<NetworkEvent> get events => _events.stream;

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async {
    startCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> stop() async {
    stopCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) async {
    configureRelayCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> disconnectRelay() async {
    disconnectRelayCalls++;
    return const SdkSuccess<void>(null);
  }

  /// 向协调器发布一个受控的 Relay 生命周期事件。
  void emitRelayState(RelayConnectionState state, {NetworkError? error}) {
    _events.add(
      RelayStateChanged(
        eventId: 'relay-event-${++_eventSequence}',
        timestamp: DateTime.now(),
        state: state,
        error: error,
      ),
    );
  }

  @override
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) async {
    connectPeerCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> registerPeer(SdkPeerConfig peer) async {
    registerPeerCalls++;
    lastPeerConfig = peer;
    lastRegisteredPeerConfig = peer;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> removePeer(String peerId) async {
    removePeerCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> disconnectPeer(String peerId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkTransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  }) async {
    transferFileCalls++;
    return SdkSuccess(
      SdkTransferSession(
        transferId: transferId,
        peerId: peerId,
        filePath: filePath,
        routeType: NetworkRouteType.lan,
      ),
    );
  }

  int respondToIncomingTransferCalls = 0;
  final List<(String, bool)> incomingResponses = <(String, bool)>[];
  bool failRespond = false;

  @override
  Future<SdkResult<void>> cancelTransfer(String transferId) async =>
      const SdkSuccess<void>(null);

  @override
  Future<SdkResult<void>> respondToIncomingTransfer({
    required String transferId,
    required bool accept,
  }) async {
    respondToIncomingTransferCalls++;
    incomingResponses.add((transferId, accept));
    if (failRespond) {
      return NetworkFailure<void>(
        const NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'respond failed',
          operation: NetworkOperation.respondToIncoming,
        ),
      );
    }
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> sendMessage({
    required String peerId,
    required Uint8List payload,
    CommunicationClass communicationClass = CommunicationClass.reliableMessage,
  }) async => const SdkSuccess<void>(null);

  @override
  Future<SdkResult<SdkRouteSnapshot>> peerState(String peerId) async =>
      SdkSuccess(
        SdkRouteSnapshot(peerId: peerId, routeType: NetworkRouteType.lan),
      );

  @override
  RealtimeSession createRealtimeSession({
    required String realtimeId,
    required String peerId,
  }) => throw UnimplementedError('not used in this test');

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

final class FakeLanShareBootstrapClient implements BootstrapClient {
  FakeLanShareBootstrapClient({this.onRefresh});

  /// 可选的 refresh 处理器；缺省返回一个未来过期的假凭据。
  final Future<SdkResult<DeviceEnrollment>> Function(
    Uri endpoint,
    RefreshRequest request,
  )?
  onRefresh;

  int refreshCalls = 0;

  @override
  Future<SdkResult<BootstrapMetadata>> probe(Uri endpoint) async =>
      const SdkSuccess(BootstrapMetadata(protocolVersion: 2));

  @override
  Future<SdkResult<DeviceEnrollment>> enroll(
    Uri endpoint,
    EnrollmentRequest request,
  ) async => SdkSuccess(
    DeviceEnrollment(
      deviceId: request.deviceId,
      relayCredential: 'fake',
      expiresAt: DateTime.utc(2030),
      serverTime: DateTime.utc(2029),
      protocolVersion: 2,
    ),
  );

  @override
  Future<SdkResult<DeviceEnrollment>> refresh(
    Uri endpoint,
    RefreshRequest request,
  ) async {
    refreshCalls++;
    final handler = onRefresh;
    if (handler != null) return handler(endpoint, request);
    return SdkSuccess(
      DeviceEnrollment(
        deviceId: request.deviceId,
        relayCredential: 'fake-refreshed',
        expiresAt: DateTime.utc(2030),
        serverTime: DateTime.utc(2029),
        protocolVersion: 2,
      ),
    );
  }
}

final class FakeLanSecurityService extends Fake implements LanSecurityService {
  @override
  String? get activePin => '123456';

  @override
  int get pinSecondsRemaining => 60;

  @override
  String getOrGenerate6DigitPin() => activePin!;
}

final class FakeLanDiscoveryService extends Fake
    implements LanDiscoveryService {
  FakeLanDiscoveryService({this.activeWebShare = false, this.shareUrl});

  final bool activeWebShare;
  final String? shareUrl;
  bool disposed = false;
  final List<(int, int?)> advertisedEndpoints = <(int, int?)>[];
  final StreamController<List<LanDiscoveredPeer>> _discoveredPeersController =
      StreamController<List<LanDiscoveredPeer>>.broadcast();
  List<LanDiscoveredPeer> _currentDiscoveredPeers = <LanDiscoveredPeer>[];

  @override
  bool get isScanning => false;

  @override
  bool touchDiscoveredPeer(String deviceId, {DateTime? now}) => false;

  @override
  LanShareLocalAddressSelectionResult? get webShareAddressSelectionResult =>
      null;

  @override
  Stream<List<LanDiscoveredPeer>> get discoveredPeersStream =>
      _discoveredPeersController.stream;

  @override
  List<LanDiscoveredPeer> get currentDiscoveredPeers =>
      List<LanDiscoveredPeer>.unmodifiable(_currentDiscoveredPeers);

  void emitDiscoveredPeers(List<LanDiscoveredPeer> peers) {
    _currentDiscoveredPeers = List<LanDiscoveredPeer>.from(peers);
    _discoveredPeersController.add(peers);
  }

  @override
  String get currentDeviceId => 'test-device';

  @override
  String get currentDeviceAlias => 'Test Device';

  @override
  bool get isWebShareActive => activeWebShare;

  @override
  String? get webShareUrl => shareUrl;

  @override
  Future<NetworkResult<void>> startDiscovery() async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> startAdvertising({
    int port = LanDiscoveryService.defaultPort,
    int? nativePort,
  }) async {
    advertisedEndpoints.add((port, nativePort));
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<NetworkResult<void>> stopDiscovery() async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> stopAdvertising() async =>
      const NetworkSuccess<void>(null);

  @override
  Future<NetworkResult<void>> stopWebShareServer() async =>
      const NetworkSuccess<void>(null);

  @override
  Future<void> close() async {
    disposed = true;
    if (!_discoveredPeersController.isClosed) {
      await _discoveredPeersController.close();
    }
  }

  @override
  void dispose() {
    unawaited(close());
  }
}

/// 支持受控监听端口和启停计数的 fake LAN 传输服务。
///
/// 默认模拟一个已可绑定端口（`LanTransferService.defaultHttpPort`）的服务，
/// 让 Coordinator 在 `initializeNetwork: true` 时能走到 native runtime
/// Capability 请求路径，而不会触发真实 HTTPS 绑定或 TLS 证书生成。
final class FakeLanTransferService extends Fake implements LanTransferService {
  FakeLanTransferService({this.startListeningResult});

  final StreamController<LanPairingRequest> _pairingInviteController =
      StreamController<LanPairingRequest>.broadcast();
  final StreamController<LanDiscoveredPeer> _announcedPeerController =
      StreamController<LanDiscoveredPeer>.broadcast();
  final StreamController<LanDiscoveredPeer> _handshakeSuccessController =
      StreamController<LanDiscoveredPeer>.broadcast();
  final StreamController<LanDiscoveredPeer> _observedPeerController =
      StreamController<LanDiscoveredPeer>.broadcast();
  int _port = LanTransferService.defaultHttpPort;
  bool _listening = false;
  final NetworkResult<int>? startListeningResult;
  int stopListeningCalls = 0;
  bool disposed = false;
  final List<LanMessage> messages = <LanMessage>[];

  @override
  String get currentDeviceId => 'test-device';

  @override
  void handleIncomingMessageFromWeb(LanMessage message) {
    messages.add(message);
  }

  @override
  Stream<LanPairingRequest> get pairingInviteStream =>
      _pairingInviteController.stream;

  @override
  Stream<LanDiscoveredPeer> get announcedPeerStream =>
      _announcedPeerController.stream;

  @override
  Stream<LanDiscoveredPeer> get handshakeSuccessPeerStream =>
      _handshakeSuccessController.stream;

  @override
  Stream<LanDiscoveredPeer> get observedPeerStream =>
      _observedPeerController.stream;

  void emitObservedPeer(LanDiscoveredPeer peer) =>
      _observedPeerController.add(peer);

  @override
  Stream<LanPairingDirectionNotice> get pairingDirectionStream =>
      const Stream.empty();

  @override
  LanPairingDirectionNotice? pairingDirectionFor(String peerId) => null;

  @override
  bool hasPendingPairing(String peerId) => false;

  @override
  Stream<LanMessage> get incomingMessageStream => const Stream.empty();

  @override
  Stream<LanMessage> get messageProgressStream => const Stream.empty();

  @override
  Stream<LanRecallRequest> get recalledMessageIdStream => const Stream.empty();

  @override
  Stream<LanConnectionStateChanged> get connectionStateStream =>
      const Stream.empty();

  void emitHandshakeSuccess(LanDiscoveredPeer device) =>
      _handshakeSuccessController.add(device);

  @override
  bool get isListening => _listening;

  @override
  int get activePort => _port;

  @override
  Future<NetworkResult<int>> startListening({
    int port = LanTransferService.defaultHttpPort,
  }) async {
    final result = startListeningResult;
    if (result != null) {
      _listening = result is NetworkSuccess<int>;
      if (_listening) _port = (result as NetworkSuccess<int>).data;
      return result;
    }
    _listening = true;
    _port = port;
    return NetworkSuccess<int>(port);
  }

  @override
  Future<NetworkResult<void>> stopListening() async {
    _listening = false;
    stopListeningCalls++;
    return const NetworkSuccess<void>(null);
  }

  @override
  Future<void> close() async {
    _listening = false;
    disposed = true;
    await Future.wait([
      if (!_pairingInviteController.isClosed) _pairingInviteController.close(),
      if (!_announcedPeerController.isClosed) _announcedPeerController.close(),
      if (!_handshakeSuccessController.isClosed)
        _handshakeSuccessController.close(),
      if (!_observedPeerController.isClosed) _observedPeerController.close(),
    ]);
  }

  @override
  void dispose() {
    unawaited(close());
  }
}

final class FakeLanStorageService extends Fake implements LanStorageService {
  bool hasSpace = true;

  @override
  Future<bool> hasSufficientSpace(int requiredBytes) async => hasSpace;

  @override
  Future<bool> deleteSandboxFile(String localPath) async => true;

  @override
  Future<Directory> getSandboxDirectory() async =>
      Directory('/tmp/lan_sandbox_fake');

  @override
  Future<int> perform7DayGarbageCollection({
    Duration ttl = const Duration(days: 7),
  }) async => 0;
}

final class FakeLanHistoryDao extends Fake implements LanHistoryDao {
  @override
  Stream<List<LanTransferRecord>> watchAllRecords() => const Stream.empty();

  @override
  Future<List<LanTransferRecord>> getAllRecords() async => const [];

  @override
  Future<int> insertRecord(LanTransferRecordsCompanion record) async => 1;

  @override
  Future<bool> updateRecordStatus(
    String id,
    String status, {
    int? bytesTransferred,
    bool? isRecalled,
    String? localPath,
    String? transport,
    String? routeType,
    int? avgRtt,
    int? bytesTotal,
    String? failureReason,
  }) async => true;
}
