// Route aggregation coverage for lib/app/ssh_mobile_app_routes.dart.
//
// Drives every named route case exposed by the App Shell and proves each
// pushed page mounts without throwing. The default switch branch is not
// reachable through the public Navigator API: every accepted route name is
// either an explicit case or rejected by the contribution assert, so that
// branch stays intentionally uncovered.

import 'package:feature_ai/feature_ai.dart' as feature_ai;
import 'package:feature_connection/feature_connection.dart'
    as feature_connection;
import 'package:feature_mcp/feature_mcp.dart' as feature_mcp;
import 'package:feature_playbook/feature_playbook.dart' as feature_playbook;
import 'package:feature_rag/feature_rag.dart' as feature_rag;
import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:feature_terminal/feature_terminal.dart' as feature_terminal;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/app_runtime.dart';
import 'package:ssh_mobile/app/connection_feature_adapters.dart';
import 'package:ssh_mobile/app/navigation/app_route_contributions.dart';
import 'package:ssh_mobile/app/sftp_feature_adapters.dart';
import 'package:ssh_mobile/app/ssh_mobile_app.dart';
import 'package:ssh_mobile/app/terminal_feature_adapters.dart';
import 'package:ssh_mobile/features/home/views/home_screen.dart';
import 'package:ssh_mobile/features/startup/views/startup_screen.dart';

import 'support/app_runtime_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RuntimeHarness harness;
  late AppRuntime runtime;

  setUp(() async {
    harness = await newRuntimeHarness(
      disposeLogger: false,
      // Route aggregation is UI coverage; do not start a native transport
      // per test and leave its asynchronous teardown overlapping the next
      // route tree in this Flutter tester process.
      networkRuntime: FakeNetworkRuntime(),
    );
    runtime = await harness.createFuture;
  });

  tearDown(() async {
    await harness.close();
  });

  NavigatorState navigator(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator));

  Future<void> withWindowsPlatform(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    // The Startup screen only schedules its battery-exemption timer on
    // Android; force Windows so no pending timer survives the test.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(SshMobileApp(runtime: runtime));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  }

  Future<void> pushRoute(
    WidgetTester tester,
    String name, {
    Object? arguments,
  }) async {
    navigator(tester).pushNamed(name, arguments: arguments);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> popRoute(WidgetTester tester) async {
    navigator(tester).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  void expectRoute(WidgetTester tester, Type screenType) {
    expect(tester.takeException(), isNull);
    expect(find.byType(screenType), findsOneWidget);
  }

  void expectBlockedPush(
    WidgetTester tester,
    String name, {
    Object? arguments,
  }) {
    expect(
      () => navigator(tester).pushNamed(name, arguments: arguments),
      throwsA(anyOf(isA<StateError>(), isA<ArgumentError>())),
    );
    expect(tester.takeException(), isNull);
  }

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // The AppLogService singleton installs a debugPrint bridge; with
    // disposeLogger: false the runtime never restores it. The test binding
    // asserts foundation debug variables are unchanged, so restore the
    // synchronous callback the automated binding installs for widget tests.
    debugPrint = debugPrintSynchronously;
  }

  testWidgets('mounts the shell and rejects unknown or invalid route args', (
    tester,
  ) async {
    await withWindowsPlatform(tester, () async {
      await pumpApp(tester);
      expectRoute(tester, StartupScreen);

      // Unknown names fail the contribution contract instead of reaching the
      // default branch; invalid arguments fail closed with a typed error.
      expectBlockedPush(tester, '/definitely-not-a-route');
      expectBlockedPush(
        tester,
        feature_connection.ConnectionRouteNames.edit,
        arguments: 42,
      );

      await pushRoute(tester, AppShellRouteNames.performance);
      expectRoute(tester, HomeScreen);
      await popRoute(tester);
      expectRoute(tester, StartupScreen);

      await disposeTree(tester);
    });
  });

  testWidgets('terminal routes mount the terminal module scope', (
    tester,
  ) async {
    await withWindowsPlatform(tester, () async {
      await pumpApp(tester);

      await pushRoute(
        tester,
        feature_terminal.TerminalRouteNames.terminal,
        arguments: <String, dynamic>{'id': 'conn-1', 'sessionId': 's-1'},
      );
      expectRoute(tester, AppTerminalModuleScope);
      await popRoute(tester);

      await pushRoute(tester, feature_terminal.TerminalRouteNames.history);
      expectRoute(tester, AppTerminalModuleScope);
      await popRoute(tester);

      await pushRoute(
        tester,
        feature_terminal.TerminalRouteNames.windows,
        arguments: 'conn-2',
      );
      expectRoute(tester, AppTerminalModuleScope);
      await popRoute(tester);

      await pushRoute(
        tester,
        feature_terminal.TerminalRouteNames.windows,
        arguments: <String, dynamic>{'connectionId': 'conn-3'},
      );
      expectRoute(tester, AppTerminalModuleScope);
      await popRoute(tester);

      await pushRoute(
        tester,
        feature_terminal.TerminalRouteNames.windows,
        arguments: <String, dynamic>{'connectionId': 99},
      );
      expectRoute(tester, AppTerminalModuleScope);
      await popRoute(tester);

      await pushRoute(
        tester,
        feature_terminal.TerminalRouteNames.windows,
        arguments: 42,
      );
      expectRoute(tester, AppTerminalModuleScope);
      await popRoute(tester);

      await disposeTree(tester);
    });
  });

  testWidgets('sftp and AI routes mount their screens', (tester) async {
    await withWindowsPlatform(tester, () async {
      await pumpApp(tester);

      await pushRoute(tester, feature_sftp.SftpRouteNames.browser);
      expectRoute(tester, AppSftpModuleScope);
      await popRoute(tester);

      await pushRoute(tester, feature_ai.AiRouteNames.skills);
      expectRoute(tester, feature_ai.AiSkillsScreen);
      await popRoute(tester);

      final skillsViewModel = feature_ai.AiSkillsViewModel(
        storageService: runtime.aiStorageAdapter,
        appSettings: runtime.aiSettingsAdapter,
      );
      addTearDown(skillsViewModel.dispose);
      await pushRoute(
        tester,
        feature_ai.AiRouteNames.skillEdit,
        arguments: <String, dynamic>{'viewModel': skillsViewModel},
      );
      expectRoute(tester, feature_ai.AiSkillEditScreen);
      await popRoute(tester);

      await disposeTree(tester);
    });
  });

  testWidgets('playbook and connection routes mount their screens', (
    tester,
  ) async {
    await withWindowsPlatform(tester, () async {
      await pumpApp(tester);

      await pushRoute(tester, feature_playbook.PlaybookRouteNames.list);
      expectRoute(tester, feature_playbook.PlaybookScreen);
      await popRoute(tester);

      final connectionViewModel = feature_connection.ConnectionViewModel(
        connectionRepository: runtime.connectionRepository,
        credentialRepository: runtime.credentialRepository,
        hostKeyRepository: runtime.hostKeyRepository,
        runtimePort: AppConnectionRuntimeAdapter(),
        verificationPort: AppConnectionVerificationAdapter(
          credentialRepository: runtime.credentialRepository,
          hostKeyRepository: runtime.hostKeyRepository,
          logger: runtime.appLogService,
        ),
      );
      addTearDown(connectionViewModel.dispose);

      await pushRoute(tester, feature_connection.ConnectionRouteNames.add);
      expectRoute(tester, feature_connection.AddEditScreen);
      await popRoute(tester);

      await pushRoute(
        tester,
        feature_connection.ConnectionRouteNames.add,
        arguments: connectionViewModel,
      );
      expectRoute(tester, feature_connection.AddEditScreen);
      await popRoute(tester);

      await pushRoute(
        tester,
        feature_connection.ConnectionRouteNames.edit,
        arguments: 'conn-9',
      );
      expectRoute(tester, feature_connection.AddEditScreen);
      await popRoute(tester);

      await pushRoute(
        tester,
        feature_connection.ConnectionRouteNames.edit,
        arguments: AppConnectionEditRouteArguments(
          connectionId: 'conn-10',
          viewModel: connectionViewModel,
        ),
      );
      expectRoute(tester, feature_connection.AddEditScreen);
      await popRoute(tester);

      await disposeTree(tester);
    });
  });

  testWidgets('rag and MCP routes mount their screens', (tester) async {
    await withWindowsPlatform(tester, () async {
      await pumpApp(tester);

      await pushRoute(tester, feature_rag.RagRouteNames.knowledge);
      expectRoute(tester, feature_rag.RagKnowledgeScreen);
      await popRoute(tester);

      await pushRoute(tester, feature_mcp.McpRouteNames.console);
      expectRoute(tester, feature_mcp.McpConsoleScreen);
      await popRoute(tester);

      await pushRoute(tester, feature_mcp.McpRouteNames.settings);
      expectRoute(tester, feature_mcp.McpSettingsScreen);
      await popRoute(tester);

      await disposeTree(tester);
    });
  });
}
