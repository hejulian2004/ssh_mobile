import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile/app/app_network_resources.dart';
import 'package:ssh_mobile/app/app_runtime.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Runtime and its root listeners do not initialize network identity',
    () async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousPrint = debugPrint;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final native = FakeNetworkRuntime();
      native.realtimeGateway = RuntimeNetworkRealtimeGateway(native.gateway);
      final harness = await newRuntimeHarness(
        networkRuntime: native,
        disposeLogger: false,
      );
      AppRuntime? runtime;
      try {
        runtime = await harness.createFuture;
        expect(native.ensureCapabilityCalls, 0);
        expect(native.openCommandGatewayCalls, 0);
        expect(native.openRealtimeGatewayCalls, 0);
        expect(
          await const FlutterSecureStorage().read(
            key: 'network_quic_ed25519_seed_v1',
          ),
          isNull,
        );
        expect(runtime.lanReceiverCoordinator.initialized, isFalse);
        await runtime.networkRuntime.openCommandGateway();
        expect(native.ensureCapabilityCalls, 1);
        expect(native.openCommandGatewayCalls, 2);
        expect(native.openRealtimeGatewayCalls, 1);
        expect(
          await const FlutterSecureStorage().read(
            key: 'network_quic_ed25519_seed_v1',
          ),
          isNotNull,
        );
        expect(runtime.lanReceiverCoordinator.initialized, isFalse);
      } finally {
        await runtime?.dispose();
        await harness.close();
        debugDefaultTargetPlatformOverride = previousPlatform;
        debugPrint = previousPrint;
      }
    },
  );
  test(
    'construction and event subscriptions leave native resources cold',
    () async {
      final native = FakeNetworkRuntime();
      var starts = 0;
      final resources = AppNetworkResources(
        nativeRuntime: native,
        initialize: (_) async {
          starts++;
          return _Facade();
        },
        createRealtimeSession: ({required realtimeId, required peerId}) =>
            throw UnimplementedError(),
      );
      final listener = resources.events.listen((_) {});
      expect(starts, 0);
      expect(resources.networkRuntime.state, NetworkRuntimeState.idle);
      expect(resources.networkRuntime.diagnostics.nativeHandles, 0);
      expect(native.ensureCapabilityCalls, 0);
      await listener.cancel();
      await resources.dispose();
      expect(starts, 0);
      await resources.networkRuntime.dispose();
      expect(native.disposeCalls, 1);
    },
  );

  AppNetworkResources owner(
    FakeNetworkRuntime native,
    Future<NetworkFacade> Function(NetworkRuntime) load,
  ) => AppNetworkResources(
    nativeRuntime: native,
    initialize: load,
    createRealtimeSession: ({required realtimeId, required peerId}) =>
        _Session(),
  );

  test(
    'concurrent first actions share configuration and forward events',
    () async {
      final native = FakeNetworkRuntime();
      final barrier = Completer<NetworkFacade>();
      final facade = _Facade();
      var starts = 0;
      final resources = owner(native, (_) {
        starts++;
        return barrier.future;
      });
      final received = <SdkEvent>[];
      final errors = <Object>[];
      final listener = resources.events.listen(
        received.add,
        onError: errors.add,
      );
      final first = resources.networkRuntime.ensureCapability(
        NetworkCapability.runtime,
      );
      final gateway = resources.networkRuntime.openCommandGateway();
      expect(resources.networkRuntime.state, NetworkRuntimeState.starting);
      expect(starts, 1);
      barrier.complete(facade);
      await first;
      expect(await gateway, same(native.gateway));
      expect(
        resources.networkRuntime.isCapabilityReady(NetworkCapability.runtime),
        isFalse,
      );
      final event = TransferProgress(
        eventId: 'synthetic',
        timestamp: DateTime(2026),
        transferId: 't',
        bytesTransferred: 1,
        totalBytes: 2,
      );
      facade.controller.add(event);
      facade.controller.addError(StateError('synthetic'));
      await Future<void>.delayed(Duration.zero);
      expect(received, [same(event)]);
      expect(errors.single, isStateError);
      await listener.cancel();
      await resources.dispose();
      await resources.dispose();
      expect(facade.disposals, 1);
      expect(
        native.disposeCalls,
        0,
        reason: 'SSH/SFTP must release before native teardown',
      );
      await resources.networkRuntime.dispose();
      await resources.networkRuntime.dispose();
      expect(native.disposeCalls, 1);
      expect(resources.networkRuntime.state, NetworkRuntimeState.disposed);
      await expectLater(
        resources.networkRuntime.openCommandGateway(),
        throwsA(isA<SdkClientDisposedException>()),
      );
      expect(
        () => resources.createRealtimeSession(realtimeId: 'r', peerId: 'p'),
        throwsA(isA<SdkClientDisposedException>()),
      );
      expect(await resources.stop(), isA<SdkSuccess<void>>());
    },
  );

  test(
    'failed configuration is retryable and disposal drains late resources',
    () async {
      final native = FakeNetworkRuntime();
      final barrier = Completer<NetworkFacade>();
      var attempts = 0;
      final resources = owner(native, (_) {
        attempts++;
        return attempts == 1
            ? Future.error(StateError('synthetic'))
            : barrier.future;
      });
      await expectLater(resources.disconnectRelay(), throwsStateError);
      final pending = resources.disconnectRelay();
      final failed = expectLater(
        pending,
        throwsA(isA<SdkClientDisposedException>()),
      );
      final close = resources.dispose();
      final facade = _Facade();
      barrier.complete(facade);
      await failed;
      await close;
      expect(attempts, 2);
      expect(facade.disposals, 1);
      await resources.networkRuntime.dispose();
      expect(native.disposeCalls, 1);
    },
  );

  test('cold stop stays cold and rejects later actions', () async {
    final native = FakeNetworkRuntime();
    final resources = owner(
      native,
      (_) => throw StateError('must remain cold'),
    );
    expect(
      resources.createRealtimeSession(realtimeId: 'r', peerId: 'p'),
      isA<RealtimeSession>(),
    );
    await resources.stop();
    await resources.stop();
    await expectLater(
      resources.disconnectRelay(),
      throwsA(isA<SdkClientDisposedException>()),
    );
    await resources.dispose();
    await resources.networkRuntime.dispose();
    expect(native.disposeCalls, 1);
  });

  test(
    'all operations use the same configured owner and preserve arguments',
    () async {
      final native = FakeNetworkRuntime();
      final facade = _Facade();
      var starts = 0;
      final resources = owner(native, (_) async {
        starts++;
        return facade;
      });
      final seed = Uint8List(32);
      final config = SdkRuntimeConfig(
        deviceId: 'synthetic',
        identityPrivateKey: seed,
        e2ePrivateKey: seed,
        listenAddress: '0.0.0.0:0',
        receiveDirectory: 'synthetic',
      );
      final peer = SdkPeerConfig(
        peerId: 'p',
        endpointAddress: '',
        identityPublicKey: seed,
        e2ePublicKey: seed,
      );
      final relay = SdkRelayConfig(
        relayUrl: 'wss://relay.example.test',
        relayCredential: 'synthetic',
        relaySigningSeed: seed,
      );
      await resources.start(config);
      await resources.registerPeer(peer);
      await resources.removePeer('p');
      await resources.connectPeer(
        'p',
        communicationClass: CommunicationClass.reliableMessage,
      );
      await resources.disconnectPeer('p');
      await resources.configureRelay(relay);
      await resources.disconnectRelay();
      await resources.cancelTransfer('t');
      await resources.respondToIncomingTransfer(transferId: 't', accept: false);
      await resources.sendMessage(peerId: 'p', payload: seed);
      await expectLater(
        resources.transferFile(
          transferId: 't',
          peerId: 'p',
          filePath: 'synthetic',
        ),
        throwsUnimplementedError,
      );
      await expectLater(resources.peerState('p'), throwsUnimplementedError);
      await expectLater(
        resources.networkRuntime.openRealtimeGateway(),
        throwsUnimplementedError,
      );
      await resources.stop();
      expect(starts, 1);
      expect(facade.calls.map((call) => call.memberName), [
        #start,
        #registerPeer,
        #removePeer,
        #connectPeer,
        #disconnectPeer,
        #configureRelay,
        #disconnectRelay,
        #cancelTransfer,
        #respondToIncomingTransfer,
        #sendMessage,
        #transferFile,
        #peerState,
        #stop,
      ]);
      expect(facade.calls.first.positionalArguments.single, same(config));
      expect(
        facade.calls[3].namedArguments[#communicationClass],
        CommunicationClass.reliableMessage,
      );
      expect(facade.calls[8].namedArguments[#accept], isFalse);
      expect(facade.calls[9].namedArguments[#payload], same(seed));
      await resources.dispose();
      expect(facade.disposals, 1);
    },
  );

  test(
    'stop waits for first use and cleanup survives a facade failure',
    () async {
      final native = FakeNetworkRuntime();
      final barrier = Completer<NetworkFacade>();
      final resources = owner(native, (_) => barrier.future);
      final pending = resources.disconnectRelay();
      final stop = resources.stop();
      final facade = _Facade()..failDisposal = true;
      barrier.complete(facade);
      await pending;
      await stop;
      await expectLater(resources.dispose(), throwsStateError);
      await expectLater(resources.networkRuntime.dispose(), throwsStateError);
      expect(native.disposeCalls, 1);
    },
  );
}

class _Facade extends Fake implements NetworkFacade {
  final controller = StreamController<SdkEvent>.broadcast();
  final calls = <Invocation>[];
  int disposals = 0;
  bool failDisposal = false;
  @override
  Stream<SdkEvent> get events => controller.stream;
  @override
  Future<void> dispose() async {
    disposals++;
    await controller.close();
    if (failDisposal) throw StateError('synthetic');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    if (invocation.memberName == #transferFile ||
        invocation.memberName == #peerState) {
      throw UnimplementedError();
    }
    return Future<SdkResult<void>>.value(const SdkSuccess<void>(null));
  }
}

class _Session extends Fake implements RealtimeSession {}
