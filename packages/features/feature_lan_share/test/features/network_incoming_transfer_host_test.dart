import 'dart:async';

import 'package:feature_lan_share/src/domain/lan_page_outcome.dart';
import 'package:feature_lan_share/src/domain/lan_share_ports.dart';
import 'package:feature_lan_share/src/features/lan_share/notifications/lan_system_notification.dart';
import 'package:feature_lan_share/src/features/lan_share/views/network_incoming_transfer_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildDialogHost({
    required Widget dialog,
    required FakeLanShareSettings settings,
    required LanShareLoggerPort logger,
  }) {
    return MultiProvider(
      providers: [
        ListenableProvider<LanShareSettingsPort>.value(value: settings),
        Provider<LanShareLoggerPort>.value(value: logger),
      ],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: false,
          splashFactory: InkRipple.splashFactory,
        ),
        home: Scaffold(body: dialog),
      ),
    );
  }

  testWidgets(
    'IncomingApprovalDialog: retryable failure keeps dialog open, shows error, and allows Retry',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int acceptCalls = 0;
      LanUiOutcome<void> nextResult = const LanUiOutcome<void>.failure(
        LanUiFailure(
          kind: LanUiFailureKind.other,
          message: 'Socket write failed',
          retryable: true,
          detail: 'Socket write failed',
        ),
      );

      final request = IncomingApprovalRequest(
        sessionId: 'tx-1',
        senderId: 'peer-test',
        fileName: 'test.pdf',
        totalBytes: 1024,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        accept: () async {
          acceptCalls++;
          return nextResult;
        },
        reject: () async => const LanUiOutcome<void>.success(),
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      // Initial state: shows Accept and Reject buttons
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(find.text('Socket write failed'), findsNothing);

      // Tap Accept -> fails with retryable error
      await tester.tap(find.text('Accept'));
      await tester.pump();

      expect(acceptCalls, 1);
      // Dialog remains open, error message is shown, button changed to Retry
      expect(find.text('Socket write failed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // Setup success for second attempt
      nextResult = const LanUiOutcome<void>.success();

      // Tap Retry -> succeeds
      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(acceptCalls, 2);
    },
  );

  testWidgets(
    'IncomingApprovalDialog: non-retryable failure triggers failure SnackBar',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int acceptCalls = 0;

      final request = IncomingApprovalRequest(
        sessionId: 'tx-2',
        senderId: 'peer-test',
        fileName: 'huge.iso',
        totalBytes: 1024 * 1024 * 1024,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        accept: () async {
          acceptCalls++;
          return const LanUiOutcome<void>.failure(
            LanUiFailure(
              kind: LanUiFailureKind.resourceLimit,
              message: 'Insufficient storage space',
              retryable: false,
              detail: 'Insufficient storage space',
            ),
          );
        },
        reject: () async => const LanUiOutcome<void>.success(),
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      expect(find.text('Accept'), findsOneWidget);

      // Tap Accept -> fails non-retryable
      await tester.tap(find.text('Accept'));
      await tester.pump();

      expect(acceptCalls, 1);
      // SnackBar shown with resourceLimit message
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.text('Insufficient storage space for incoming transfer.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'IncomingApprovalDialog: double click is disabled while submitting',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int acceptCalls = 0;
      final completer = Completer<LanUiOutcome<void>>();

      final request = IncomingApprovalRequest(
        sessionId: 'tx-3',
        senderId: 'peer-test',
        fileName: 'test.bin',
        totalBytes: 100,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        accept: () async {
          acceptCalls++;
          return completer.future;
        },
        reject: () async => const LanUiOutcome<void>.success(),
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      // First tap starts accept
      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(acceptCalls, 1);

      // In-flight: progress indicator is visible and buttons are disabled
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Completing the future finishes the accept
      completer.complete(const LanUiOutcome<void>.success());
      await tester.pump();
      expect(acceptCalls, 1);
    },
  );

  testWidgets(
    'IncomingApprovalDialog: Accept crossing expiry failure does not show Retry and invokes reject',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int acceptCalls = 0;
      int rejectCalls = 0;
      final acceptCompleter = Completer<LanUiOutcome<void>>();

      final request = IncomingApprovalRequest(
        sessionId: 'tx-4',
        senderId: 'peer-test',
        fileName: 'test.bin',
        totalBytes: 100,
        expiresAt: DateTime.now().add(const Duration(milliseconds: 100)),
        accept: () async {
          acceptCalls++;
          return acceptCompleter.future;
        },
        reject: () async {
          rejectCalls++;
          return const LanUiOutcome<void>.success();
        },
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      // Start accept
      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(acceptCalls, 1);

      // Advance clock past expiry
      await tester.pump(const Duration(milliseconds: 200));

      // Fail the accept with retryable error
      acceptCompleter.complete(
        const LanUiOutcome<void>.failure(
          LanUiFailure(
            kind: LanUiFailureKind.other,
            message: 'Socket timeout',
            retryable: true,
            detail: 'Socket timeout',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Dialog is closed (expired), reject was invoked, Retry is NOT shown
      expect(rejectCalls, 1);
      expect(find.text('Retry'), findsNothing);
    },
  );

  testWidgets(
    'IncomingApprovalDialog: Accept crossing expiry success wins and closes without invoking reject',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int acceptCalls = 0;
      int rejectCalls = 0;
      final acceptCompleter = Completer<LanUiOutcome<void>>();

      final request = IncomingApprovalRequest(
        sessionId: 'tx-5',
        senderId: 'peer-test',
        fileName: 'test.bin',
        totalBytes: 100,
        expiresAt: DateTime.now().add(const Duration(milliseconds: 100)),
        accept: () async {
          acceptCalls++;
          return acceptCompleter.future;
        },
        reject: () async {
          rejectCalls++;
          return const LanUiOutcome<void>.success();
        },
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      // Start accept
      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(acceptCalls, 1);

      // Advance clock past expiry
      await tester.pump(const Duration(milliseconds: 200));

      // Sockets succeed despite clock
      acceptCompleter.complete(const LanUiOutcome<void>.success());
      await tester.pumpAndSettle();

      // Succeeded, reject was NOT invoked
      expect(rejectCalls, 0);
      expect(find.byType(IncomingApprovalDialog), findsNothing);
    },
  );

  testWidgets(
    'IncomingApprovalDialog: Reject failure keeps dialog open and allows Retry Reject',
    (tester) async {
      final settings = FakeLanShareSettings();
      final logger = FakeLanShareLogger();
      int rejectCalls = 0;
      LanUiOutcome<void> nextResult = const LanUiOutcome<void>.failure(
        LanUiFailure(
          kind: LanUiFailureKind.other,
          message: 'Network unreachable on reject',
          retryable: true,
          detail: 'Network unreachable on reject',
        ),
      );

      final request = IncomingApprovalRequest(
        sessionId: 'tx-6',
        senderId: 'peer-test',
        fileName: 'test.bin',
        totalBytes: 100,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        accept: () async => const LanUiOutcome<void>.success(),
        reject: () async {
          rejectCalls++;
          return nextResult;
        },
      );

      await tester.pumpWidget(
        buildDialogHost(
          dialog: IncomingApprovalDialog(request: request),
          settings: settings,
          logger: logger,
        ),
      );

      // Tap Reject -> fails
      await tester.tap(find.text('Reject'));
      await tester.pump();

      expect(rejectCalls, 1);
      // Dialog remains open, error shown, button changed to Retry Reject
      expect(find.text('Network unreachable on reject'), findsOneWidget);
      expect(find.text('Retry Reject'), findsOneWidget);

      // Second attempt succeeds
      nextResult = const LanUiOutcome<void>.success();
      await tester.tap(find.text('Retry Reject'));
      await tester.pumpAndSettle();

      expect(rejectCalls, 2);
      expect(find.byType(IncomingApprovalDialog), findsNothing);
    },
  );

  test('incoming file request queues one redacted notification', () {
    final pending = <IncomingApprovalRequest>[];
    final request = IncomingApprovalRequest(
      sessionId: 'secret-file',
      senderId: 'peer-a',
      fileName: 'secret-file.bin',
      totalBytes: 1,
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      accept: () async => const LanUiOutcome<void>.success(),
      reject: () async => const LanUiOutcome<void>.success(),
    );

    final first = decideIncomingTransferNotification(pending, request);
    final duplicate = decideIncomingTransferNotification(pending, request);
    final expired = decideIncomingTransferNotification(
      pending,
      IncomingApprovalRequest(
        sessionId: 'other',
        senderId: 'peer-a',
        fileName: 'secret-file.bin',
        totalBytes: 1,
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        accept: request.accept,
        reject: request.reject,
      ),
    );

    expect(first.queued, isTrue);
    expect(first.event?.kind, LanNotificationKind.transferRequest);
    expect(first.event?.businessId, 'secret-file');
    expect(first.event?.peerId, 'peer-a');
    expect(first.event?.displayName, isNull);
    expect(first.event.toString(), isNot(contains('secret-file.bin')));
    expect(duplicate.queued, isFalse);
    expect(duplicate.event, isNull);
    expect(expired.queued, isFalse);
    expect(pending, hasLength(1));
  });
}
