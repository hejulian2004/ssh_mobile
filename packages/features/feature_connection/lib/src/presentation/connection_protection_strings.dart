import 'package:connection_core/connection_core.dart';

/// 生物识别保护独立双语文案；只展示稳定错误，不拼接平台异常或凭据。
final class ConnectionProtectionStrings {
  const ConnectionProtectionStrings({required this.isEnglish});
  final bool isEnglish;
  String get title =>
      isEnglish ? 'Biometric credential protection' : '生物识别凭据保护';
  String get help => isEnglish
      ? 'Require biometric authentication to use saved credentials.'
      : '使用已保存凭据前，需通过生物识别验证。';
  String get unlock => isEnglish ? 'Unlock credentials' : '解锁凭据';
  String get lock => isEnglish ? 'Lock credentials' : '锁定凭据';
  String get locked => isEnglish ? 'Credentials are locked' : '凭据已锁定';
  String get unlocked =>
      isEnglish ? 'Credentials unlocked for this edit' : '凭据已为本次编辑解锁';
  String get busy => isEnglish ? 'Authenticating…' : '正在验证身份…';
  String get saveFirst => isEnglish
      ? 'Save credential changes before changing protection.'
      : '请先保存凭据修改，再更改保护状态。';
  String get savePrompt => isEnglish
      ? 'Saving protected credentials requires authentication again.'
      : '保存受保护凭据时需要再次验证身份。';

  String error(CredentialProtectionError code) => switch (code) {
    CredentialProtectionError.locked => locked,
    CredentialProtectionError.corrupt =>
      isEnglish
          ? 'Protected credentials are damaged. Delete this connection and add it again with your credentials.'
          : '受保护凭据已损坏，请删除此连接后重新添加凭据。',
    CredentialProtectionError.unsupported =>
      isEnglish
          ? 'Biometric credential protection is unavailable on this device.'
          : '此设备暂不支持生物识别凭据保护。',
    CredentialProtectionError.cancelled =>
      isEnglish
          ? 'Authentication cancelled. Credentials remain locked.'
          : '已取消身份验证，凭据仍然锁定。',
    CredentialProtectionError.stale =>
      isEnglish
          ? 'The connection or credentials changed. Reopen the editor.'
          : '连接或凭据已更改，请重新打开编辑页。',
    CredentialProtectionError.authenticationFailed =>
      isEnglish ? 'Authentication failed. Try again.' : '身份验证失败，请重试。',
    CredentialProtectionError.keyInvalidated =>
      isEnglish
          ? 'The security key is unavailable. Delete this connection and add it again with your credentials.'
          : '安全密钥已失效，请删除此连接后重新添加凭据。',
    CredentialProtectionError.storageFailure =>
      isEnglish
          ? 'Credentials could not be stored securely. Try again.'
          : '无法安全保存凭据，请重试。',
  };
}
