import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:feature_lan_share/feature_lan_share.dart' as feature_lan_share;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/app/app_runtime.dart';
import 'package:ssh_mobile/app/app_runtime_factory.dart';
import 'package:ssh_mobile/services/network/network_protocol_v2_codec.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// 可注入的 NetworkRuntime 替身：记录 dispose 次数，可配置 dispose 抛错，
/// 便于确定性地验证回滚顺序和错误隔离，而不触碰 native handle。
final class FakeNetworkRuntime implements NetworkRuntime {
  Object? disposeError;
  int disposeCalls = 0;
  int ensureCapabilityCalls = 0;
  int openCommandGatewayCalls = 0;
  bool disposed = false;
  final FakeCommandGateway gateway = FakeCommandGateway();
  final Set<NetworkCapability> _readyCapabilities = <NetworkCapability>{};

  @override
  NetworkRuntimeState get state =>
      disposed ? NetworkRuntimeState.disposed : NetworkRuntimeState.idle;

  @override
  NetworkRuntimeDiagnostics get diagnostics => NetworkRuntimeDiagnostics(
    state: state,
    activeConnections: 0,
    nativeHandles: 0,
    readyCapabilities: const <NetworkCapability>[],
  );

  @override
  Future<void> ensureCapability(NetworkCapability capability) async {
    if (_readyCapabilities.contains(capability)) return;
    ensureCapabilityCalls++;
    _readyCapabilities.add(capability);
  }

  @override
  Future<NetworkCommandGateway> openCommandGateway() async {
    openCommandGatewayCalls++;
    return gateway;
  }

  @override
  Future<NetworkRealtimeGateway> openRealtimeGateway() async {
    throw UnimplementedError('openRealtimeGateway is not expected in tests');
  }

  @override
  bool isCapabilityReady(NetworkCapability capability) => false;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
    await gateway.close();
    final error = disposeError;
    if (error != null) throw error;
  }
}

final class FakeCommandGateway implements NetworkCommandGateway {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> commands = <Uint8List>[];
  final NetworkProtocolV2Codec _codec = const NetworkProtocolV2Codec();

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) {
    commands.add(command);
    final commandId = _codec.commandId(command);
    scheduleMicrotask(() {
      if (!_events.isClosed) _events.add(_commandResultFrame(commandId));
    });
    return TransportOperationStatus.success;
  }

  Future<void> close() => _events.close();
}

Uint8List _commandResultFrame(String commandId) => Uint8List.fromList(
  _eventFrame(13, <int>[
    ..._bytesField(1, utf8.encode(commandId)),
    ..._varintField(2, 1),
  ]),
);

List<int> _eventFrame(int eventField, List<int> payload) => <int>[
  ..._bytesField(1, utf8.encode('event-a')),
  ..._varintField(2, 1),
  ..._varintField(3, 2),
  ..._bytesField(eventField, payload),
];

List<int> _varintField(int fieldNumber, int value) => <int>[
  ..._varint(fieldNumber << 3),
  ..._varint(value),
];

List<int> _bytesField(int fieldNumber, List<int> value) => <int>[
  ..._varint((fieldNumber << 3) | 2),
  ..._varint(value.length),
  ...value,
];

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    final next = remaining & 0x7f;
    remaining >>= 7;
    bytes.add(remaining == 0 ? next : next | 0x80);
  } while (remaining != 0);
  return bytes;
}

/// ConnectionRepository 替身：initialize 永久挂起，用于证明构造失败回滚
/// 不会被一个永远不完成的启动任务阻塞。
final class HangingConnectionRepository implements ConnectionRepository {
  int initializeCalls = 0;

  @override
  List<ConnectionConfig> get connections => const <ConnectionConfig>[];

  @override
  Future<void> initialize() {
    initializeCalls++;
    return Completer<void>().future;
  }

  @override
  Future<List<ConnectionConfig>> loadConnections() async =>
      const <ConnectionConfig>[];

  @override
  Future<void> addConnection(ConnectionConfig config) async {}

  @override
  Future<void> updateConnection(ConnectionConfig config) async {}

  @override
  Future<void> deleteConnection(String id) async {}

  @override
  Future<void> deleteConnections(List<String> ids) async {}

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}

  @override
  ConnectionConfig? getConnection(String id) => null;
}

/// HostKeyRepository 替身；仅用于让 [AppRuntimeFactory] 在注入自定义
/// ConnectionRepository 时通过 Host Key 解析。
final class FakeHostKeyRepository implements HostKeyRepository {
  @override
  Future<void> trustHostKey(
    String connectionId, {
    required String? algorithm,
    required String? fingerprint,
    required DateTime? trustedAt,
  }) async {}
}

/// 一次工厂调用所需的隔离资源：独立内存 Connection 数据库 + 独立 RAG 缓存目录。
final class RuntimeHarness {
  RuntimeHarness._(this.connectionDatabase, this.ragCacheDirectory);

  final ConnectionDatabase connectionDatabase;
  final Directory ragCacheDirectory;
  late final Future<AppRuntime> createFuture;

  Future<void> close() async {
    // ConnectionDatabase.dispose 幂等，重复调用安全。
    await connectionDatabase.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    try {
      await ragCacheDirectory.delete(recursive: true);
    } on FileSystemException {
      // 已经由回滚/释放清理。
    }
  }
}

/// 构造一次 Runtime 工厂调用；所有内存数据库按测试隔离创建。
///
/// [disposeLogger] 默认 true，测试可以关闭它避免销毁跨用例共享的
/// `AppLogService` 全局单例。
Future<RuntimeHarness> newRuntimeHarness({
  ConnectionRepository? connectionRepository,
  HostKeyRepository? hostKeyRepository,
  NetworkRuntime? networkRuntime,
  feature_lan_share.LanShareDatabaseFactory? lanShareDatabaseFactory,
  String relayEndpoint = '',
  String? relayCredential,
  String relayDeviceId = 'runtime-test-device',
  bool disposeLogger = true,
  bool startPendingInitialization = true,
  void Function(String event)? lifecycleObserver,
}) async {
  final preferences = <String, Object>{'relay_endpoint': relayEndpoint};
  final secureStorage = <String, String>{};
  if (relayCredential != null) {
    preferences['lan_device_id'] = relayDeviceId;
    secureStorage['lan_device_id'] = relayDeviceId;
    secureStorage['relay_device_credential_v1'] = jsonEncode({
      'endpoint': relayEndpoint,
      'device_id': relayDeviceId,
      'credential': relayCredential,
      'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      'protocol_version': 2,
    });
  }
  SharedPreferences.setMockInitialValues(preferences);
  FlutterSecureStorage.setMockInitialValues(secureStorage);
  final connectionDatabase = ConnectionDatabase.forTesting(
    NativeDatabase.memory(),
  );
  final ragCacheDirectory = await Directory.systemTemp.createTemp(
    'app-runtime-rag-',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        _pathProviderChannel,
        (_) async => ragCacheDirectory.path,
      );
  final harness = RuntimeHarness._(connectionDatabase, ragCacheDirectory);
  harness.createFuture = AppRuntimeFactory.create(
    connectionDatabase: connectionDatabase,
    connectionRepository: connectionRepository,
    credentialRepository: SecureCredentialRepository(),
    hostKeyRepository: hostKeyRepository,
    networkRuntime: networkRuntime,
    lanShareDatabaseFactory:
        lanShareDatabaseFactory ??
        () => feature_lan_share.LanShareDatabase.forTesting(
          NativeDatabase.memory(),
        ),
    lanShareReceiverEnabled: false,
    startPendingInitialization: startPendingInitialization,
    playbookDatabaseFactory: () =>
        feature_playbook.PlaybookDatabase.forTesting(NativeDatabase.memory()),
    ragDatabaseFactory: () =>
        feature_rag.RagDatabase.forTesting(NativeDatabase.memory()),
    ragCacheStoreFactory: () => feature_rag.RagCacheStore(
      directoryFactory: () async => ragCacheDirectory,
    ),
    mcpDatabaseFactory: () =>
        feature_mcp.McpDatabase.forTesting(NativeDatabase.memory()),
    disposeLogger: disposeLogger,
    lifecycleObserver: lifecycleObserver,
  );
  return harness;
}

/// 从 lifecycleObserver 事件中解析回滚优先级序列。
List<int> rollbackPriorities(List<String> events) {
  const prefix = 'rollback.priority-';
  return events
      .where((event) => event.startsWith(prefix))
      .map((event) => int.parse(event.substring(prefix.length)))
      .toList();
}
