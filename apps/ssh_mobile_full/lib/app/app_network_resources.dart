import 'dart:async';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';

/// App-owned network resources, configured once on the first network action.
/// Event listeners and diagnostics never allocate a native handle or identity.
final class AppNetworkResources implements NetworkFacade {
  AppNetworkResources({
    required NetworkRuntime nativeRuntime,
    required this._initialize,
    required this._createRealtimeSession,
  }) : _native = nativeRuntime;

  final NetworkRuntime _native;
  final Future<NetworkFacade> Function(NetworkRuntime) _initialize;
  final RealtimeSession Function({
    required String realtimeId,
    required String peerId,
  })
  _createRealtimeSession;
  final _events = StreamController<SdkEvent>.broadcast();
  NetworkFacade? _facade;
  Future<NetworkFacade>? _loading;
  StreamSubscription<SdkEvent>? _subscription;
  Future<void>? _closing;
  Future<void>? _closingNative;
  bool _disposed = false;
  bool _stopped = false;

  /// Runtime disposal remains separate: SSH/SFTP release before native teardown.
  late final NetworkRuntime networkRuntime = _AppNetworkRuntime(this);

  @override
  Stream<SdkEvent> get events => _events.stream;

  NetworkRuntimeState get state => _disposed
      ? NetworkRuntimeState.disposed
      : _loading != null
      ? NetworkRuntimeState.starting
      : _native.state;

  NetworkRuntimeDiagnostics get diagnostics => _native.diagnostics;

  bool isCapabilityReady(NetworkCapability capability) =>
      !_disposed && _facade != null && _native.isCapabilityReady(capability);

  Future<NetworkFacade> _ensureReady() {
    _ensureUsable();
    final ready = _facade;
    if (ready != null) return Future.value(ready);
    final pending = _loading;
    if (pending != null) return pending;
    final future = _load();
    _loading = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_loading, future)) _loading = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_loading, future)) _loading = null;
        },
      ),
    );
    return future;
  }

  Future<NetworkFacade> _load() async {
    final facade = await _initialize(_native);
    _facade = facade;
    if (_disposed || _stopped) {
      // Disposal waits for this generation and releases the late facade.
      throw const SdkClientDisposedException();
    }
    _subscription = facade.events.listen(
      _events.add,
      onError: _events.addError,
    );
    return facade;
  }

  void _ensureUsable() {
    if (_disposed || _stopped) throw const SdkClientDisposedException();
  }

  Future<void> ensureCapability(NetworkCapability capability) async {
    await _ensureReady();
    await _native.ensureCapability(capability);
  }

  Future<NetworkCommandGateway> openCommandGateway() async {
    await _ensureReady();
    return _native.openCommandGateway();
  }

  Future<NetworkRealtimeGateway> openRealtimeGateway() async {
    await _ensureReady();
    return _native.openRealtimeGateway();
  }

  Future<SdkResult<T>> _withFacade<T>(
    Future<SdkResult<T>> Function(NetworkFacade) action,
  ) async => action(await _ensureReady());

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) =>
      _withFacade((facade) => facade.start(config));

  @override
  Future<SdkResult<void>> stop() async {
    if (_disposed || _stopped) return const SdkSuccess(null);
    final pending = _loading;
    if (pending != null) await pending;
    _stopped = true;
    return _facade?.stop() ?? const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> registerPeer(SdkPeerConfig peer) =>
      _withFacade((facade) => facade.registerPeer(peer));

  @override
  Future<SdkResult<void>> removePeer(String peerId) =>
      _withFacade((facade) => facade.removePeer(peerId));

  @override
  Future<SdkResult<void>> connectPeer(
    String peerId, {
    CommunicationClass communicationClass = CommunicationClass.reliableStream,
  }) => _withFacade(
    (facade) =>
        facade.connectPeer(peerId, communicationClass: communicationClass),
  );

  @override
  Future<SdkResult<void>> disconnectPeer(String peerId) =>
      _withFacade((facade) => facade.disconnectPeer(peerId));

  @override
  Future<SdkResult<void>> configureRelay(SdkRelayConfig config) =>
      _withFacade((facade) => facade.configureRelay(config));

  @override
  Future<SdkResult<void>> disconnectRelay() =>
      _withFacade((facade) => facade.disconnectRelay());

  @override
  Future<SdkResult<SdkTransferSession>> transferFile({
    required String transferId,
    required String peerId,
    required String filePath,
    CommunicationClass communicationClass = CommunicationClass.bulkTransfer,
  }) => _withFacade(
    (facade) => facade.transferFile(
      transferId: transferId,
      peerId: peerId,
      filePath: filePath,
      communicationClass: communicationClass,
    ),
  );

  @override
  Future<SdkResult<void>> cancelTransfer(String transferId) =>
      _withFacade((facade) => facade.cancelTransfer(transferId));

  @override
  Future<SdkResult<void>> respondToIncomingTransfer({
    required String transferId,
    required bool accept,
  }) => _withFacade(
    (facade) => facade.respondToIncomingTransfer(
      transferId: transferId,
      accept: accept,
    ),
  );

  @override
  Future<SdkResult<void>> sendMessage({
    required String peerId,
    required Uint8List payload,
    CommunicationClass communicationClass = CommunicationClass.reliableMessage,
  }) => _withFacade(
    (facade) => facade.sendMessage(
      peerId: peerId,
      payload: payload,
      communicationClass: communicationClass,
    ),
  );

  @override
  Future<SdkResult<SdkRouteSnapshot>> peerState(String peerId) =>
      _withFacade((facade) => facade.peerState(peerId));

  @override
  RealtimeSession createRealtimeSession({
    required String realtimeId,
    required String peerId,
  }) {
    _ensureUsable();
    // Creating a session is cheap; its backend initializes on first command.
    return _createRealtimeSession(realtimeId: realtimeId, peerId: peerId);
  }

  @override
  Future<void> dispose() {
    if (_closing != null) return _closing!;
    _disposed = true;
    return _closing = _dispose();
  }

  Future<void> _dispose() async {
    try {
      try {
        await _loading;
      } catch (_) {
        // The caller receives the initialization error; cleanup still proceeds.
      }
      await _subscription?.cancel();
      await _facade?.dispose();
    } finally {
      await _events.close();
    }
  }

  Future<void> _disposeRuntime() => _closingNative ??= () async {
    try {
      await dispose();
    } finally {
      await _native.dispose();
    }
  }();
}

final class _AppNetworkRuntime implements NetworkRuntime {
  const _AppNetworkRuntime(this._owner);
  final AppNetworkResources _owner;

  @override
  NetworkRuntimeState get state => _owner.state;
  @override
  NetworkRuntimeDiagnostics get diagnostics => _owner.diagnostics;
  @override
  bool isCapabilityReady(NetworkCapability capability) =>
      _owner.isCapabilityReady(capability);
  @override
  Future<void> ensureCapability(NetworkCapability capability) =>
      _owner.ensureCapability(capability);
  @override
  Future<NetworkCommandGateway> openCommandGateway() =>
      _owner.openCommandGateway();
  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() =>
      _owner.openRealtimeGateway();
  @override
  Future<void> dispose() => _owner._disposeRuntime();
}
