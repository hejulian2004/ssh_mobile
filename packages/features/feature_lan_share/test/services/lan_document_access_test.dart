import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('system document save text names no assumed storage location', () {
    for (final locale in [(true, 'File saved'), (false, '文件已保存')]) {
      expect(LanDocumentStrings(isEnglish: locale.$1).saved, locale.$2);
    }
    expect(LanDocumentLimits.maxSendBytes, 2 * 1024 * 1024 * 1024);
  });
}
