import 'lan_share_ports.dart';

/// Feature-owned device list copy shared by every App shell.
extension LanDeviceStrings on LanShareStrings {
  String get lanDeviceConnecting => isEnglish ? 'Connecting…' : '连接中…';
  String get lanDeviceTerminate => isEnglish ? 'Terminate' : '终止';
  String get lanDevicePaired => isEnglish ? 'Paired' : '已配对';
  String get lanDeviceUnpaired => isEnglish ? 'Not paired' : '未配对';
  String get lanDeviceUnknown => isEnglish ? 'Unknown' : '未知';
  String get lanDeviceLastOnline => isEnglish ? 'Last came online' : '最近上线';
  String get lanDeviceUnpair => isEnglish ? 'Unpair' : '解除配对';
  String get lanDeviceUnpairTitle =>
      isEnglish ? 'Unpair this device?' : '解除设备配对？';
  String get lanDeviceUnpairHint => isEnglish
      ? 'The device can be discovered and paired again. Chat history will be kept.'
      : '设备仍可被重新发现和配对，聊天记录会保留。';
  String get lanDeviceUnpairFailed =>
      isEnglish ? 'Unable to unpair. Try again.' : '解除配对失败，请重试。';
}
