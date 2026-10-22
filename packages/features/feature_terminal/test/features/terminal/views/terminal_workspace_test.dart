import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:feature_terminal/feature_terminal.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:app_ui/app_ui.dart';

import '../../../fakes/terminal_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void useViewport(
    WidgetTester tester, {
    required Size physicalSize,
    double devicePixelRatio = 1,
  }) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget appHost({required Widget home, double textScale = 1}) {
    return MaterialApp(
      theme: AppTheme.lightThemeFor(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );
  }

  group('terminal workspace chrome', () {
    testWidgets('app bar exposes endpoint, real status, and 48dp actions', (
      tester,
    ) async {
      useViewport(tester, physicalSize: const Size(320, 640));
      var switchCalls = 0;
      var reconnectCalls = 0;

      await tester.pumpWidget(
        appHost(
          textScale: 2,
          home: Scaffold(
            appBar: TerminalScreenAppBar(
              strings: const TerminalStrings('en'),
              displayName: 'Production shell with a long session name',
              serverName: 'Production',
              serverEndpoint: 'deployment@prod.example.com:2222',
              connectionState: TerminalLinkState.error,
              isDarkMode: false,
              reconnectInProgress: false,
              onReconnect: () => reconnectCalls++,
              onToggleTheme: () {},
              onSwitchWindow: () => switchCalls++,
              onCloseWindow: () {},
              onOpenSiblingSession: () {},
              onSmallerFont: () {},
              onLargerFont: () {},
            ),
            body: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('terminal-switch-window'))),
        const Size(48, 48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('terminal-more-actions'))),
        const Size(48, 48),
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('terminal-connection-status')),
            )
            .label,
        contains('Error'),
      );

      await tester.tap(find.byKey(const ValueKey('terminal-switch-window')));
      expect(switchCalls, 1);

      await tester.tap(find.byKey(const ValueKey('terminal-more-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();
      expect(reconnectCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error overlay remains usable at 320dp and 200% text', (
      tester,
    ) async {
      useViewport(tester, physicalSize: const Size(320, 720));
      var reconnectCalls = 0;
      var switchCalls = 0;
      var closeCalls = 0;

      await tester.pumpWidget(
        appHost(
          textScale: 2,
          home: Scaffold(
            body: TerminalConnectionOverlay(
              strings: const TerminalStrings('en'),
              connectionState: TerminalLinkState.error,
              reconnectInProgress: false,
              terminalBackground: const Color(0xFF09090B),
              endpoint: 'deployment@prod.example.com:2222',
              errorMessage: 'Host key negotiation failed after timeout',
              onReconnect: () => reconnectCalls++,
              onSwitchWindow: () => switchCalls++,
              onCloseWindow: () => closeCalls++,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Could not connect to the terminal'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('terminal-reconnect'))).height,
        greaterThanOrEqualTo(48),
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('terminal-reconnect')),
      );
      await tester.tap(find.byKey(const ValueKey('terminal-reconnect')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('terminal-manage-windows')),
      );
      await tester.tap(find.byKey(const ValueKey('terminal-manage-windows')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('terminal-close-window')),
      );
      await tester.tap(find.byKey(const ValueKey('terminal-close-window')));

      expect(reconnectCalls, 1);
      expect(switchCalls, 1);
      expect(closeCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('connecting overlay fits a short landscape viewport', (
      tester,
    ) async {
      useViewport(tester, physicalSize: const Size(640, 320));

      await tester.pumpWidget(
        appHost(
          home: Scaffold(
            body: TerminalConnectionOverlay(
              strings: const TerminalStrings('en'),
              connectionState: TerminalLinkState.connecting,
              reconnectInProgress: false,
              terminalBackground: const Color(0xFF09090B),
              endpoint: 'ops@staging.example.com:22',
              onReconnect: () {},
              onSwitchWindow: () {},
              onCloseWindow: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Connecting to the terminal'), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal-reconnect')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('terminal shortcut panel', () {
    late FakeTerminalCapability terminal;
    late FakeSshSessionManager sshManager;
    late FakeTerminalShortcuts shortcutService;
    late FakeTerminalSettings settings;
    late TextEditingController inputController;
    late FocusNode focusNode;

    setUp(() {
      terminal = FakeTerminalCapability();
      sshManager = FakeSshSessionManager(terminal);
      shortcutService = FakeTerminalShortcuts();
      settings = FakeTerminalSettings(language: 'en');
      inputController = TextEditingController();
      focusNode = FocusNode();
    });

    tearDown(() async {
      focusNode.dispose();
      inputController.dispose();
      shortcutService.dispose();
      settings.dispose();
      await terminal.close();
    });

    testWidgets(
      'compact 200% layout keeps actions tappable and sheet scrollable',
      (tester) async {
        useViewport(tester, physicalSize: const Size(320, 720));
        String? submittedCommand;

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ListenableProvider<TerminalShortcutPort>.value(
                value: shortcutService,
              ),
              ListenableProvider<TerminalSettingsPort>.value(value: settings),
              Provider<SshSessionManager>.value(value: sshManager),
            ],
            child: appHost(
              textScale: 2,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: TerminalShortcutPanel(
                    strings: const TerminalStrings('en'),
                    toolbarColor: const Color(0xFF09090B),
                    complexInputController: inputController,
                    onSendData: (_) {},
                    onSendComplexInput: (value) => submittedCommand = value,
                    onTerminalStroke: (_) {},
                    terminalFocusNode: focusNode,
                    ctrlActive: false,
                    onToggleCtrl: () {},
                    altActive: false,
                    onToggleAlt: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const ValueKey('terminal-add-shortcut'))),
          const Size(48, 48),
        );
        expect(
          tester.getSize(
            find.byKey(const ValueKey('terminal-advanced-keyboard')),
          ),
          const Size(48, 48),
        );

        await tester.tap(
          find.byKey(const ValueKey('terminal-advanced-keyboard')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Windows Keyboard'), findsOneWidget);
        expect(find.text('Function Keys'), findsOneWidget);
        final symbolsLayer = find.byKey(
          const ValueKey('terminal-keyboard-layer-symbols'),
        );
        await tester.ensureVisible(symbolsLayer);
        await tester.pumpAndSettle();
        await tester.tap(symbolsLayer);
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('terminal-custom-key-pipe')),
        );
        await tester.tap(
          find.byKey(const ValueKey('terminal-custom-key-pipe')),
        );
        expect(inputController.text, '|');

        await tester.enterText(
          find.byKey(const ValueKey('terminal-custom-keyboard-input')),
          'printf "first"\nprintf "second"',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('terminal-custom-keyboard-send')),
        );
        await tester.tap(
          find.byKey(const ValueKey('terminal-custom-keyboard-send')),
        );
        await tester.pumpAndSettle();
        expect(submittedCommand, 'printf "first"\nprintf "second"');
        expect(inputController.text, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('TerminalScreen keeps terminal mounted while history loads', (
      tester,
    ) async {
      useViewport(tester, physicalSize: const Size(1280, 800));
      final history = Completer<String>();
      final terminal = FakeTerminalCapability(
        sessions: [_terminalSession(SshConnectionState.connected)],
      )..historyLoader = (_) => history.future;
      addTearDown(terminal.close);

      await tester.pumpWidget(_terminalScreenHost(terminal));
      await tester.pump();

      expect(find.byType(TerminalViewArea), findsOneWidget);
      expect(find.byType(AppTerminalSkeleton), findsOneWidget);
      expect(find.byType(TerminalBufferedOutputIndicator), findsOneWidget);

      history.complete('ready');
      await tester.pump();
    });

    testWidgets('TerminalScreen reconnect overlay does not replace terminal', (
      tester,
    ) async {
      useViewport(tester, physicalSize: const Size(1280, 800));
      final reconnect = Completer<bool>();
      final terminal = FakeTerminalCapability(
        sessions: [_terminalSession(SshConnectionState.disconnected)],
      )..ensureSessionConnectedHandler = (_, _) => reconnect.future;
      addTearDown(terminal.close);

      await tester.pumpWidget(_terminalScreenHost(terminal));
      await tester.pump();
      await tester.pump();
      final context = tester.element(find.byType(TerminalViewArea));
      final viewModel = Provider.of<TerminalSessionViewModel>(
        context,
        listen: false,
      );

      unawaited(viewModel.reconnect());
      await tester.pump();

      expect(find.byType(TerminalViewArea), findsOneWidget);
      expect(find.byType(TerminalConnectionOverlay), findsOneWidget);
      expect(find.byType(AppTerminalSkeleton), findsNothing);

      reconnect.complete(false);
      await tester.pump();
    });
  });
}

Widget _terminalScreenHost(FakeTerminalCapability terminal) {
  return TerminalFeatureScope(
    sshSessionManager: FakeSshSessionManager(terminal),
    settings: FakeTerminalSettings(language: 'en'),
    shortcuts: FakeTerminalShortcuts(),
    connections: _TerminalConnections(),
    logger: FakeTerminalLogger(),
    historyRepository: _TerminalHistoryRepository(),
    child: MaterialApp(
      theme: AppTheme.lightThemeFor(),
      home: const TerminalScreen(
        connectionId: 'conn-1',
        sessionId: 'session-1',
      ),
    ),
  );
}

SshTerminalSession _terminalSession(SshConnectionState state) {
  return SshTerminalSession(
    id: 'session-1',
    connectionId: 'conn-1',
    connectionName: 'Server',
    displayName: 'Shell',
    tmuxSessionName: null,
    tmuxAutoDeleteSeconds: null,
    fontSize: 13,
    state: state,
    errorMessage: null,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    output: const Stream<String>.empty(),
    outputText: '',
    estimatedMemoryBytes: 0,
  );
}

final class _TerminalConnections implements TerminalConnectionPort {
  @override
  TerminalConnectionInfo? getConnection(String connectionId) => null;

  @override
  String defaultDisplayNameForConnection(String connectionId) => connectionId;

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
  }) async => null;

  @override
  Future<void> openConnectionEditor(
    String connectionId, {
    bool isNew = false,
  }) async {}
}

final class _TerminalHistoryRepository implements TerminalHistoryRepository {
  @override
  Future<List<TerminalHistoryRecord>> loadRecords() async => const [];

  @override
  Future<void> removeRecord(String sessionId) async {}

  @override
  Future<void> replaceAll(Iterable<TerminalHistoryRecord> records) async {}

  @override
  Future<void> saveRecord(TerminalHistoryRecord record) async {}
}
