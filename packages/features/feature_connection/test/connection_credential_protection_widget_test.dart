import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:feature_connection/src/presentation/connection_credential_protection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'fakes/protected_credentials_fakes.dart';

void main() {
  testWidgets(
    'edit page keeps protected secrets hidden until one explicit unlock',
    (tester) async {
      final credentials = ProtectedCredentialFake();
      final repository = ConnectionRepositoryFake();
      final vm = ConnectionViewModel(
        connectionRepository: repository,
        credentialRepository: credentials,
        hostKeyRepository: repository,
        runtimePort: ConnectionRuntimeFake(),
        verificationPort: ConnectionVerificationFake(),
      );
      addTearDown(vm.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ConnectionViewModel>.value(value: vm),
            ChangeNotifierProvider<ConnectionStrings>(
              create: (_) =>
                  ConnectionStrings(language: ConnectionLanguage.english),
            ),
          ],
          child: ShadTheme(
            data: ShadThemeData(brightness: Brightness.light),
            child: const MaterialApp(home: AddEditScreen(editId: 'server-1')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(credentials.plainReads, 0);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('credential-unlock')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('credential-unlock')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('connection-save-button')),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('credential-unlock')),
      );
      await tester.tap(find.byKey(const ValueKey('credential-unlock')));
      await tester.pumpAndSettle();
      final values = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((field) => field.controller.text);
      expect(values, containsAll(['fixture-password', 'fixture-key']));
      expect(credentials.unlockCalls, 1);
      await tester.ensureVisible(find.byKey(const ValueKey('credential-lock')));
      await tester.tap(find.byKey(const ValueKey('credential-lock')));
      await tester.pumpAndSettle();
      final lockedValues = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((field) => field.controller.text);
      expect(lockedValues, isNot(contains('fixture-key')));
    },
  );

  for (final code in CredentialProtectionError.values) {
    testWidgets('protection panel localizes $code', (tester) async {
      final credentials = ProtectedCredentialFake();
      final editor = ConnectionCredentialEditor(
        connectionId: 'server-1',
        connectionRepository: ConnectionRepositoryFake(),
        credentialRepository: credentials,
      );
      addTearDown(editor.dispose);
      await editor.initialize();
      credentials.error = code;
      await editor.unlock();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionCredentialProtection(
              editor: editor,
              isEnglish: true,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('credential-protection-error')),
        findsOneWidget,
      );
      expect(find.textContaining('Exception'), findsNothing);
    });
  }

  testWidgets(
    'changing saved protection invokes Core and changes locked state',
    (tester) async {
      final credentials = ProtectedCredentialFake()..protected = false;
      final editor = ConnectionCredentialEditor(
        connectionId: 'server-1',
        connectionRepository: ConnectionRepositoryFake(),
        credentialRepository: credentials,
      );
      addTearDown(editor.dispose);
      await editor.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionCredentialProtection(
              editor: editor,
              isEnglish: true,
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('credential-protection-switch')),
      );
      await tester.pumpAndSettle();
      expect(credentials.enables, 1);
      expect(editor.isProtected, isTrue);
      await tester.tap(
        find.byKey(const ValueKey('credential-protection-switch')),
      );
      await tester.pumpAndSettle();
      expect(credentials.disables, 1);
      expect(editor.isProtected, isFalse);
    },
  );

  testWidgets(
    'dirty credential fields require saving before changing protection',
    (tester) async {
      final credentials = ProtectedCredentialFake()..protected = false;
      final editor = ConnectionCredentialEditor(
        connectionId: 'server-1',
        connectionRepository: ConnectionRepositoryFake(),
        credentialRepository: credentials,
      );
      addTearDown(editor.dispose);
      await editor.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionCredentialProtection(
              editor: editor,
              isEnglish: false,
              hasUnsavedCredentials: true,
            ),
          ),
        ),
      );
      expect(find.text('请先保存凭据修改，再更改保护状态。'), findsOneWidget);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('credential-protection-switch')),
            )
            .onChanged,
        isNull,
      );
    },
  );

  testWidgets('cancelled unlock keeps edit fields hidden and save disabled', (
    tester,
  ) async {
    final credentials = ProtectedCredentialFake()
      ..error = CredentialProtectionError.cancelled;
    await _pumpEdit(tester, credentials);
    await tester.tap(find.byKey(const ValueKey('credential-unlock')));
    await tester.pumpAndSettle();
    expect(
      find.text('Authentication cancelled. Credentials remain locked.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('connection-save-button')),
          )
          .onPressed,
      isNull,
    );
    expect(credentials.plainReads, 0);
    expect(_secretValues(tester), isNot(contains('fixture-key')));
  });

  testWidgets('closing edit page during authentication discards late success', (
    tester,
  ) async {
    final pending = Completer<CredentialPair>();
    final credentials = ProtectedCredentialFake()
      ..unlockResult = pending.future;
    await _pumpEdit(tester, credentials);
    await tester.tap(find.byKey(const ValueKey('credential-unlock')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(
      const CredentialPair(privateKey: 'late-secret', revision: 'revision-1'),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('late-secret'), findsNothing);
  });

  testWidgets('hiding the app clears authenticated edit fields', (
    tester,
  ) async {
    final credentials = ProtectedCredentialFake();
    await _pumpEdit(tester, credentials);
    await tester.tap(find.byKey(const ValueKey('credential-unlock')));
    await tester.pumpAndSettle();
    expect(_secretValues(tester), contains('fixture-key'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(_secretValues(tester), isNot(contains('fixture-key')));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('cancelled enable clears controllers before a successful retry', (
    tester,
  ) async {
    final credentials = ProtectedCredentialFake()..protected = false;
    await _pumpEdit(tester, credentials);
    final controllers = _secretControllers(tester);
    expect(
      controllers.map((controller) => controller.text),
      containsAll(['fixture-password', 'fixture-key']),
    );
    credentials.error = CredentialProtectionError.cancelled;
    await tester.tap(
      find.byKey(const ValueKey('credential-protection-switch')),
    );
    await tester.pumpAndSettle();
    expect(controllers.every((controller) => controller.text.isEmpty), isTrue);
    credentials.error = null;
    await tester.tap(
      find.byKey(const ValueKey('credential-protection-switch')),
    );
    await tester.pumpAndSettle();
    expect(credentials.enables, 2);
    expect(credentials.protected, isTrue);
    expect(controllers.every((controller) => controller.text.isEmpty), isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('credential-unlock')),
      -250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('credential-unlock')), findsOneWidget);
  });

  testWidgets(
    'hidden pending enable cannot commit and can retry after resume',
    (tester) async {
      final pause = Completer<void>();
      final credentials = ProtectedCredentialFake()
        ..protected = false
        ..beforeMutation = () => pause.future;
      await _pumpEdit(tester, credentials);
      final controllers = _secretControllers(tester);
      await tester.tap(
        find.byKey(const ValueKey('credential-protection-switch')),
      );
      await tester.pump();
      expect(credentials.enables, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      pause.complete();
      await tester.pumpAndSettle();
      expect(credentials.protected, isFalse);
      expect(
        controllers.every((controller) => controller.text.isEmpty),
        isTrue,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      credentials.beforeMutation = null;
      await tester.tap(
        find.byKey(const ValueKey('credential-protection-switch')),
      );
      await tester.pumpAndSettle();
      expect(credentials.enables, 2);
      expect(credentials.protected, isTrue);
      expect(
        controllers.every((controller) => controller.text.isEmpty),
        isTrue,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('credential-unlock')),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('credential-unlock')));
      await tester.pumpAndSettle();
      expect(_secretValues(tester), contains('fixture-key'));
    },
  );

  testWidgets('hidden pending disable remains protected and can retry', (
    tester,
  ) async {
    final pause = Completer<void>();
    final credentials = ProtectedCredentialFake()
      ..beforeMutation = () => pause.future;
    await _pumpEdit(tester, credentials);
    await tester.tap(
      find.byKey(const ValueKey('credential-protection-switch')),
    );
    await tester.pump();
    expect(credentials.disables, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    pause.complete();
    await tester.pumpAndSettle();
    expect(credentials.protected, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    credentials.beforeMutation = null;
    await tester.tap(
      find.byKey(const ValueKey('credential-protection-switch')),
    );
    await tester.pumpAndSettle();
    expect(credentials.disables, 2);
    expect(credentials.protected, isFalse);
    expect(_secretValues(tester), contains('fixture-key'));
  });

  testWidgets('hidden pending unlock discards late success and can retry', (
    tester,
  ) async {
    final pending = Completer<CredentialPair>();
    final credentials = ProtectedCredentialFake()
      ..unlockResult = pending.future;
    await _pumpEdit(tester, credentials);
    await tester.tap(find.byKey(const ValueKey('credential-unlock')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    pending.complete(
      const CredentialPair(privateKey: 'late-key', revision: 'revision-1'),
    );
    await tester.pumpAndSettle();
    expect(_secretValues(tester), isNot(contains('late-key')));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    credentials.unlockResult = null;
    await tester.tap(find.byKey(const ValueKey('credential-unlock')));
    await tester.pumpAndSettle();
    expect(credentials.unlockCalls, 2);
    expect(_secretValues(tester), contains('fixture-key'));
  });

  for (final protected in [false, true]) {
    testWidgets(
      'a rebound target cannot save the old ${protected ? 'unlocked' : 'plain'} form',
      (tester) async {
        final repository = ConnectionRepositoryFake();
        final verification = ConnectionVerificationFake();
        final credentials = ProtectedCredentialFake()..protected = protected;
        await _pumpEdit(
          tester,
          credentials,
          repository: repository,
          verification: verification,
        );
        if (protected) {
          await tester.tap(find.byKey(const ValueKey('credential-unlock')));
          await tester.pumpAndSettle();
        }
        final save = tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('connection-save-button')),
            )
            .onPressed;
        expect(save, isNotNull);
        repository.current = repository.current!.copyWith(
          host: 'replacement.example.test',
        );
        // 模拟已有帧的点击：实际动作也必须校验，不能只依赖按钮重建。
        save!();
        await tester.pumpAndSettle();
        expect(verification.calls, 0);
        expect(credentials.plainWrites, 0);
        expect(credentials.protectedWrites, 0);
        expect(repository.current!.host, 'replacement.example.test');
        final strings = tester
            .element(find.byType(AddEditScreen))
            .read<ConnectionStrings>();
        strings.setLanguage(ConnectionLanguage.chinese);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('connection-save-button')),
              )
              .onPressed,
          isNull,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('credential-protection-error')),
          -250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('连接或凭据已更改，请重新打开编辑页。'), findsOneWidget);
      },
    );

    testWidgets(
      'an explicit host edit can save ${protected ? 'protected' : 'plain'} credentials',
      (tester) async {
        final repository = ConnectionRepositoryFake();
        final verification = ConnectionVerificationFake();
        final credentials = ProtectedCredentialFake()..protected = protected;
        await _pumpEdit(
          tester,
          credentials,
          repository: repository,
          verification: verification,
        );
        if (protected) {
          await tester.tap(find.byKey(const ValueKey('credential-unlock')));
          await tester.pumpAndSettle();
        }
        final host = find.byWidgetPredicate(
          (widget) =>
              widget is EditableText &&
              widget.controller.text == 'fixture.example.test',
        );
        await tester.scrollUntilVisible(
          host,
          -250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(host);
        await tester.enterText(host, 'edited.example.test');
        await tester.pumpAndSettle();
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('connection-save-button')),
            )
            .onPressed!();
        await tester.pumpAndSettle();
        expect(verification.calls, 1);
        expect(repository.current!.host, 'edited.example.test');
        expect(credentials.protectedWrites, protected ? 1 : 0);
        expect(credentials.plainWrites, protected ? 0 : 1);
        expect(find.textContaining('Reopen the editor'), findsNothing);
      },
    );
  }

  testWidgets(
    'editing decrypted fields prevents changing saved protection before save',
    (tester) async {
      await _pumpEdit(tester, ProtectedCredentialFake());
      await tester.tap(find.byKey(const ValueKey('credential-unlock')));
      await tester.pumpAndSettle();
      final password = find.byWidgetPredicate(
        (widget) =>
            widget is EditableText &&
            widget.controller.text == 'fixture-password',
      );
      await tester.ensureVisible(password);
      await tester.enterText(password, 'changed-fixture-password');
      await tester.pumpAndSettle();
      expect(
        find.text('Save credential changes before changing protection.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('credential-protection-switch')),
            )
            .onChanged,
        isNull,
      );
    },
  );

  testWidgets('unsupported protected credentials remain locked', (
    tester,
  ) async {
    final credentials = ProtectedCredentialFake()..supportsProtection = false;
    final editor = ConnectionCredentialEditor(
      connectionId: 'server-1',
      connectionRepository: ConnectionRepositoryFake(),
      credentialRepository: credentials,
    );
    addTearDown(editor.dispose);
    await editor.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionCredentialProtection(editor: editor, isEnglish: true),
        ),
      ),
    );
    expect(
      find.text(
        'Biometric credential protection is unavailable on this device.',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('credential-unlock')))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'unprotected platforms without capability keep existing edit presentation',
    (tester) async {
      final credentials = ProtectedCredentialFake()
        ..supportsProtection = false
        ..protected = false;
      final editor = ConnectionCredentialEditor(
        connectionId: 'server-1',
        connectionRepository: ConnectionRepositoryFake(),
        credentialRepository: credentials,
      );
      addTearDown(editor.dispose);
      await editor.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionCredentialProtection(
              editor: editor,
              isEnglish: true,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('credential-protection-switch')),
        findsNothing,
      );
    },
  );
}

Iterable<String> _secretValues(WidgetTester tester) => tester
    .widgetList<EditableText>(find.byType(EditableText))
    .map((field) => field.controller.text);

List<TextEditingController> _secretControllers(WidgetTester tester) => tester
    .widgetList<EditableText>(find.byType(EditableText))
    .where(
      (field) =>
          field.controller.text == 'fixture-password' ||
          field.controller.text == 'fixture-key',
    )
    .map((field) => field.controller)
    .toList();

Future<void> _pumpEdit(
  WidgetTester tester,
  ProtectedCredentialFake credentials, {
  ConnectionRepositoryFake? repository,
  ConnectionVerificationFake? verification,
}) async {
  final connectionRepository = repository ?? ConnectionRepositoryFake();
  final vm = ConnectionViewModel(
    connectionRepository: connectionRepository,
    credentialRepository: credentials,
    hostKeyRepository: connectionRepository,
    runtimePort: ConnectionRuntimeFake(),
    verificationPort: verification ?? ConnectionVerificationFake(),
  );
  addTearDown(vm.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ConnectionViewModel>.value(value: vm),
        ChangeNotifierProvider<ConnectionStrings>(
          create: (_) =>
              ConnectionStrings(language: ConnectionLanguage.english),
        ),
      ],
      child: ShadTheme(
        data: ShadThemeData(brightness: Brightness.light),
        child: const MaterialApp(home: AddEditScreen(editId: 'server-1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('credential-protection-switch')),
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(
    find.byKey(const ValueKey('credential-protection-switch')),
  );
  await tester.pumpAndSettle();
}
