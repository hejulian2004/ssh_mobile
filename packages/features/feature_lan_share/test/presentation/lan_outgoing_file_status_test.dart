import 'dart:io';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:feature_lan_share/src/features/lan_share/views/widgets/lan_outgoing_file_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('outgoing media retry follows the stored failure and source file', () {
    final failed = _message(failureReason: 'timeout');
    expect(canRetryOutgoingLanFile(failed, sourceExists: true), isTrue);
    expect(canRetryOutgoingLanFile(failed, sourceExists: false), isFalse);
    expect(
      canRetryOutgoingLanFile(
        _message(failureReason: null),
        sourceExists: true,
      ),
      isTrue,
    );
    expect(
      canRetryOutgoingLanFile(
        _message(failureReason: 'not-a-code'),
        sourceExists: true,
      ),
      isTrue,
    );
    expect(
      canRetryOutgoingLanFile(
        _message(failureReason: 'authenticationFailed'),
        sourceExists: true,
      ),
      isFalse,
    );
    expect(
      canRetryOutgoingLanFile(
        _message(payloadType: LanPayloadType.text),
        sourceExists: true,
      ),
      isFalse,
    );
    expect(
      canRetryOutgoingLanFile(_message(isIncoming: true), sourceExists: true),
      isFalse,
    );
  });

  testWidgets(
    'failed outgoing media shows retry only while the source exists',
    (tester) async {
      final existingPath = Platform.resolvedExecutable;
      const missingPath = r'C:\missing\lan-share-clip.mp4';
      var retries = 0;

      await tester.pumpWidget(
        _harness(
          message: _message(localPath: existingPath),
          onRetry: () => retries++,
        ),
      );
      expect(find.text('失败'), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(retries, 1);

      await tester.pumpWidget(
        _harness(
          message: _message(localPath: missingPath),
          onRetry: () {},
        ),
      );
      expect(find.text('失败'), findsOneWidget);
      expect(find.text('重试'), findsNothing);

      await tester.pumpWidget(
        _harness(
          message: _message(
            localPath: existingPath,
            failureReason: 'authenticationFailed',
          ),
          onRetry: () {},
        ),
      );
      expect(find.text('失败'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    },
  );
}

Widget _harness({required LanMessage message, required VoidCallback onRetry}) {
  return MaterialApp(
    home: Scaffold(
      body: LanOutgoingFileStatus(
        message: message,
        strings: _StatusStrings(),
        foreground: const Color(0xFF112233),
        onRetry: onRetry,
      ),
    ),
  );
}

LanMessage _message({
  LanPayloadType payloadType = LanPayloadType.video,
  LanTransferStatus status = LanTransferStatus.failed,
  String? failureReason = 'timeout',
  String? localPath = r'C:\media\clip.mp4',
  bool isIncoming = false,
}) {
  return LanMessage(
    id: 'transfer-1',
    senderId: 'local',
    senderAlias: 'This device',
    receiverId: 'peer',
    payloadType: payloadType,
    fileName: 'clip.mp4',
    fileSize: 4,
    localPath: localPath,
    status: status,
    failureReason: failureReason,
    createdAt: DateTime.utc(2026),
    isIncoming: isIncoming,
  );
}

final class _StatusStrings extends Fake implements LanShareStrings {
  @override
  bool get isEnglish => false;

  @override
  String get retry => '重试';

  @override
  String get lanShareFailed => '失败';
}
