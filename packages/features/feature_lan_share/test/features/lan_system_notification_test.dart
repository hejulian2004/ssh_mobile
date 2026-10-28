import 'dart:async';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  LanMessage message({
    required LanPayloadType type,
    bool incoming = true,
    bool recalled = false,
    String id = 'm1',
    String senderId = 'peer',
  }) {
    return LanMessage(
      id: id,
      senderId: senderId,
      senderAlias: 'Phone',
      receiverId: 'local',
      payloadType: type,
      textContent: 'hello secret',
      createdAt: DateTime.utc(2026),
      isIncoming: incoming,
      isRecalled: recalled,
    );
  }

  test('only persisted incoming text and clipboard become events', () {
    final text = incomingMessageNotification(
      message(type: LanPayloadType.text),
    );
    expect(text?.kind, LanNotificationKind.message);
    expect(text?.displayName, 'Phone');
    expect(text.toString(), isNot(contains('hello secret')));
    expect(
      incomingMessageNotification(
        message(type: LanPayloadType.clipboard),
      )?.kind,
      LanNotificationKind.message,
    );
    expect(
      incomingMessageNotification(message(type: LanPayloadType.image)),
      isNull,
    );
    expect(
      incomingMessageNotification(message(type: LanPayloadType.file)),
      isNull,
    );
    expect(
      incomingMessageNotification(
        message(type: LanPayloadType.text, incoming: false),
      ),
      isNull,
    );
    expect(
      incomingMessageNotification(
        message(type: LanPayloadType.text, recalled: true),
      ),
      isNull,
    );
  });

  test('file events omit names and ignore outgoing or progress results', () {
    final request = transferRequestNotification(
      sessionId: 'tx-1',
      peerId: 'peer',
      expired: false,
    );
    expect(request?.kind, LanNotificationKind.transferRequest);
    expect(request?.businessId, 'tx-1');
    expect(
      transferRequestNotification(
        sessionId: 'tx-1',
        peerId: 'peer',
        expired: true,
      ),
      isNull,
    );
    expect(
      incomingTransferTerminalNotification(
        isIncoming: true,
        succeeded: true,
        transferId: 'tx-1',
        peerId: 'peer',
        displayName: 'Phone',
      )?.kind,
      LanNotificationKind.transferSucceeded,
    );
    expect(
      incomingTransferTerminalNotification(
        isIncoming: true,
        succeeded: false,
        transferId: 'tx-1',
        peerId: 'peer',
      )?.kind,
      LanNotificationKind.transferFailed,
    );
    expect(
      incomingTransferTerminalNotification(
        isIncoming: false,
        succeeded: true,
        transferId: 'tx-1',
        peerId: 'peer',
      ),
      isNull,
    );
  });

  test('clicks never accept a request and ignore recalled history', () {
    final history = [
      message(type: LanPayloadType.text, id: 'm1'),
      message(type: LanPayloadType.text, id: 'old', recalled: true),
    ];
    expect(
      decideLanNotificationClick(
        kind: LanNotificationKind.message,
        peerId: 'peer',
        businessId: 'm1',
        history: history,
      ),
      isA<LanNotificationOpenChat>(),
    );
    expect(
      decideLanNotificationClick(
        kind: LanNotificationKind.message,
        peerId: 'peer',
        businessId: 'm1',
        history: history,
        visiblePeerId: 'peer',
      ),
      isA<LanNotificationShowApp>(),
    );
    expect(
      decideLanNotificationClick(
        kind: LanNotificationKind.transferRequest,
        peerId: 'peer',
        businessId: 'tx',
        history: const [],
      ),
      isA<LanNotificationShowApp>(),
    );
    expect(
      decideLanNotificationClick(
        kind: LanNotificationKind.message,
        peerId: 'peer',
        businessId: 'old',
        history: history,
      ),
      isA<LanNotificationIgnore>(),
    );
    expect(
      decideLanNotificationClick(
        kind: LanNotificationKind.transferSucceeded,
        peerId: 'other',
        businessId: 'm1',
        history: history,
      ),
      isA<LanNotificationIgnore>(),
    );
    expect(
      decideLanNotificationClick(
        kind: LanNotificationKind.message,
        peerId: '',
        businessId: 'm1',
        history: history,
      ),
      isA<LanNotificationIgnore>(),
    );
  });

  test('click context is empty without a view model', () {
    final context = readLanNotificationClickContext(null, 'peer');
    expect(context.history, isEmpty);
    expect(context.alias, isEmpty);
  });

  test('visible chat restores the route underneath', () {
    final chat = LanVisibleChat();
    chat.claim('lower');
    chat.claim('upper');
    expect(chat.peerId, 'upper');
    chat.release('upper');
    expect(chat.peerId, 'lower');
    chat.release('missing');
    expect(chat.peerId, 'lower');
    chat.release('lower');
    expect(chat.peerId, isNull);
    chat.claim('');
    expect(chat.peerId, isNull);
  });

  testWidgets('binder forwards events and ignores a missing view model', (
    tester,
  ) async {
    final notifier = ChangeNotifier();
    final controller = StreamController<LanNotificationEvent>.broadcast();
    addTearDown(controller.close);
    addTearDown(notifier.dispose);
    final presented = <LanNotificationKind>[];
    Stream<LanNotificationEvent>? stream;
    var fail = false;
    await tester.pumpWidget(
      Provider<LanSystemNotificationPort>.value(
        value: _Port(presented.add),
        child: LanNotificationBinder(
          listenable: notifier,
          events: () {
            if (fail) throw TypeError();
            return stream;
          },
          child: const SizedBox.shrink(),
        ),
      ),
    );
    stream = controller.stream;
    notifier.notifyListeners();
    controller.add(
      const LanNotificationEvent(
        kind: LanNotificationKind.message,
        businessId: 'm1',
        peerId: 'peer',
      ),
    );
    await tester.pump();
    expect(presented, [LanNotificationKind.message]);

    fail = true;
    notifier.notifyListeners();
    controller.add(
      const LanNotificationEvent(
        kind: LanNotificationKind.transferFailed,
        businessId: 'm2',
        peerId: 'peer',
      ),
    );
    await tester.pump();
    expect(presented, [LanNotificationKind.message]);
  });

  testWidgets('notification click opens the existing chat and claims it', (
    tester,
  ) async {
    final settings = FakeLanShareSettings(english: true);
    final viewModel = LanShareViewModel(
      discoveryService: FakeLanDiscoveryService(),
      securityService: _PairedSecurity(),
      storageService: FakeLanStorageService(),
      transferService: _IdleTransfer(),
      historyDao: FakeLanHistoryDao(),
      appSettings: settings,
      dataProtection: FakeLanShareDataProtection(),
      logger: FakeLanShareLogger(),
      ownsRuntime: false,
    );
    addTearDown(viewModel.dispose);
    addTearDown(settings.dispose);
    final loaded = readLanNotificationClickContext(viewModel, 'peer-1');
    expect(loaded.history, isEmpty);
    expect(loaded.alias, isEmpty);
    final navigatorKey = GlobalKey<NavigatorState>();
    final visible = LanVisibleChat();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<LanShareSettingsPort>.value(value: settings),
          ChangeNotifierProvider<LanShareViewModel>.value(value: viewModel),
          Provider<LanVisibleChat>.value(value: visible),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );

    openLanNotificationChat(
      navigator: null,
      decision: const LanNotificationOpenChat('peer-1'),
      initialAlias: 'Remote Desktop',
    );
    openLanNotificationChat(
      navigator: navigatorKey.currentState,
      decision: const LanNotificationShowApp(),
      initialAlias: 'Remote Desktop',
    );
    openLanNotificationChat(
      navigator: navigatorKey.currentState,
      decision: const LanNotificationIgnore(),
      initialAlias: 'Remote Desktop',
    );
    expect(find.byType(LanChatScreen), findsNothing);

    openLanNotificationChat(
      navigator: navigatorKey.currentState,
      decision: const LanNotificationOpenChat('peer-1'),
      initialAlias: 'Remote Desktop',
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(LanChatScreen), findsOneWidget);
    expect(find.text('Remote Desktop'), findsWidgets);
    expect(visible.peerId, 'peer-1');

    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump();
    expect(find.byType(LanChatScreen), findsNothing);
    expect(visible.peerId, isNull);
  });

  testWidgets('binder swaps its listenable and ignores a missing port', (
    tester,
  ) async {
    final first = ChangeNotifier();
    final second = ChangeNotifier();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final controller = StreamController<LanNotificationEvent>.broadcast();
    addTearDown(controller.close);
    await tester.pumpWidget(
      LanNotificationBinder(
        listenable: first,
        events: () => controller.stream,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pumpWidget(
      LanNotificationBinder(
        listenable: second,
        events: () => controller.stream,
        child: const SizedBox.shrink(),
      ),
    );
    controller.add(
      const LanNotificationEvent(
        kind: LanNotificationKind.transferRequest,
        businessId: 'tx',
        peerId: 'peer',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

final class _PairedSecurity extends Fake implements LanSecurityService {
  @override
  Future<bool> isDevicePaired(
    String deviceId, {
    String? ip,
    int? port,
    String? localDeviceId,
  }) async => true;
}

final class _IdleTransfer extends Fake implements LanTransferService {
  @override
  bool isWebSocketConnected(String deviceId) => false;
}

final class _Port implements LanSystemNotificationPort {
  _Port(this.onEvent);
  final void Function(LanNotificationKind kind) onEvent;

  @override
  Future<void> present(LanNotificationEvent event) async {
    onEvent(event.kind);
  }
}
