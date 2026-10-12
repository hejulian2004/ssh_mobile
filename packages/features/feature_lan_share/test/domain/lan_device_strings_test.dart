import 'package:feature_lan_share/src/domain/lan_device_strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  test(
    'device actions explain pairing, rediscovery and failures in both languages',
    () {
      final english = FakeLanShareStrings();
      expect(english.lanDevicePaired, 'Paired');
      expect(english.lanDeviceUnpaired, 'Not paired');
      expect(english.lanDeviceUnknown, 'Unknown');
      expect(english.lanDeviceLastOnline, 'Last came online');
      expect(english.lanDeviceUnpair, 'Unpair');
      expect(english.lanDeviceUnpairTitle, 'Unpair this device?');
      expect(
        english.lanDeviceUnpairHint,
        contains('discovered and paired again'),
      );
      expect(english.lanDeviceUnpairFailed, contains('Try again'));
      final chinese = FakeLanShareStrings(english: false);
      expect(chinese.lanDevicePaired, '已配对');
      expect(chinese.lanDeviceUnpaired, '未配对');
      expect(chinese.lanDeviceUnknown, '未知');
      expect(chinese.lanDeviceLastOnline, '最近上线');
      expect(chinese.lanDeviceUnpair, '解除配对');
      expect(chinese.lanDeviceUnpairTitle, '解除设备配对？');
      expect(chinese.lanDeviceUnpairHint, contains('重新发现和配对'));
      expect(chinese.lanDeviceUnpairFailed, contains('请重试'));
    },
  );
}
