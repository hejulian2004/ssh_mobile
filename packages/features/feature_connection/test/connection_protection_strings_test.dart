import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/src/presentation/connection_protection_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('credential protection actions and errors have both localizations', () {
    for (final english in [true, false]) {
      final strings = ConnectionProtectionStrings(isEnglish: english);
      expect(
        strings.title,
        english ? 'Biometric credential protection' : '生物识别凭据保护',
      );
      expect(strings.unlock, english ? 'Unlock credentials' : '解锁凭据');
      expect(strings.lock, english ? 'Lock credentials' : '锁定凭据');
      final descriptions = [
        strings.help,
        strings.locked,
        strings.unlocked,
        strings.busy,
        strings.saveFirst,
        strings.savePrompt,
        for (final code in CredentialProtectionError.values)
          strings.error(code),
      ];
      expect(
        descriptions.every((description) => description.isNotEmpty),
        isTrue,
      );
      expect(descriptions.join(), isNot(contains('Exception')));
      expect(
        strings.error(CredentialProtectionError.cancelled),
        english
            ? 'Authentication cancelled. Credentials remain locked.'
            : '已取消身份验证，凭据仍然锁定。',
      );
      expect(
        strings.error(CredentialProtectionError.keyInvalidated),
        english
            ? 'The security key is unavailable. Delete this connection and add it again with your credentials.'
            : '安全密钥已失效，请删除此连接后重新添加凭据。',
      );
      expect(
        strings.error(CredentialProtectionError.corrupt),
        english
            ? 'Protected credentials are damaged. Delete this connection and add it again with your credentials.'
            : '受保护凭据已损坏，请删除此连接后重新添加凭据。',
      );
    }
  });
}
