import 'dart:async';

import 'package:android_server_widgets/android_server_widgets.dart';
import 'package:connection_core/connection_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/monitoring_widget_navigation_host.dart';
import 'package:ssh_mobile/app/navigation/app_route_contributions.dart';

void main() {
  late _Directory repository;
  late _Navigation port;
  late ValueNotifier<bool> ready;
  late GlobalKey<NavigatorState> key;
  final routes = <RouteSettings>[];
  setUp(() {
    repository = _Directory();
    port = _Navigation();
    ready = ValueNotifier(false);
    key = GlobalKey<NavigatorState>();
    routes.clear();
  });
  tearDown(() {
    ready.dispose();
  });
  void androidTest(String description, WidgetTesterCallback body) =>
      testWidgets(
        description,
        body,
        variant: TargetPlatformVariant({TargetPlatform.android}),
      );
  Widget app() => MaterialApp(
    navigatorKey: key,
    builder: (_, child) => MonitoringWidgetNavigationHost(
      repository: repository,
      navigatorKey: key,
      ready: ready,
      navigation: port,
      child: child!,
    ),
    home: const Text('Home'),
    onGenerateRoute: (settings) {
      routes.add(settings);
      return MaterialPageRoute(
        settings: settings,
        builder: (_) => Text('Monitor ${settings.arguments}'),
      );
    },
  );

  androidTest('cold click waits for startup and revalidates the directory', (
    tester,
  ) async {
    port.initial = const {'connectionId': 'server-a', 'requestId': 'cold-a'};
    await tester.pumpWidget(app());
    await tester.pump();
    expect(routes, isEmpty);
    ready.value = true;
    await tester.pumpAndSettle();
    expect(routes.single.name, AppShellRouteNames.monitoringDetails);
    expect(routes.single.arguments, 'server-a');
    expect(find.text('Monitor server-a'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(port.disposals, 1);
  });

  androidTest(
    'warm clicks deduplicate and deleted servers safely return home',
    (tester) async {
      ready.value = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      port.open('server-a', 'warm-a');
      await tester.pumpAndSettle();
      port.open('server-a', 'warm-a');
      await tester.pumpAndSettle();
      expect(routes.length, 1);
      repository.exists = false;
      port.open('server-a', 'deleted-a');
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(routes.length, 1);
    },
  );

  testWidgets('Windows never owns a plugin listener', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(port.starts, 0);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  androidTest(
    'disposal or a newer request invalidates asynchronous directory reads',
    (tester) async {
      ready.value = true;
      final gate = Completer<void>();
      repository.gate = gate.future;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      port.open('server-a', 'late-a');
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pumpAndSettle();
      expect(routes, isEmpty);
      expect(port.disposals, 1);
    },
  );

  androidTest('directory failures never navigate into an invalid target', (
    tester,
  ) async {
    ready.value = true;
    repository.fail = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    port.open('server-a', 'failed-a');
    await tester.pumpAndSettle();
    expect(routes, isEmpty);
    expect(find.text('Home'), findsOneWidget);
  });
}

final class _Directory implements ConnectionRepository {
  bool exists = true;
  bool fail = false;
  Future<void>? gate;
  @override
  Future<void> initialize() async {
    await gate;
    if (fail) throw StateError('fixture');
  }

  @override
  ConnectionConfig? getConnection(String id) => exists && id == 'server-a'
      ? ConnectionConfig(
          id: id,
          name: 'Compute A',
          host: 'example.invalid',
          username: 'fixture-user',
        )
      : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Navigation implements MonitoringWidgetNavigationPort {
  int starts = 0;
  int disposals = 0;
  Map<String, String>? initial;
  void Function(MonitoringWidgetOpenRequest)? listener;
  @override
  Future<void> start(void Function(MonitoringWidgetOpenRequest) onOpen) async {
    starts++;
    listener = onOpen;
    final request = MonitoringWidgetOpenRequest.tryParse(initial);
    if (request != null) onOpen(request);
  }

  void open(String id, String request) => listener?.call(
    MonitoringWidgetOpenRequest.tryParse({
      'connectionId': id,
      'requestId': request,
    })!,
  );
  @override
  Future<void> dispose() async {
    disposals++;
    listener = null;
  }
}
