import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing parser uses advertised host and LAN control port', () {
    final target = parseLanShareWebSharePairingTarget(
      'https://192.168.1.20:53319/?deviceId=peer-a&lanPort=62017'
      '&nativePort=62018&access=opaque-token&certFingerprint=abc123',
    );

    expect(target, isNotNull);
    expect(target!.host, '192.168.1.20');
    expect(target.controlPort, 62017);
    expect(target.nativePort, 62018);
    expect(target.deviceId, 'peer-a');
  });

  test('parser rejects non-HTTPS and hostless links', () {
    expect(
      parseLanShareWebSharePairingTarget('http://192.168.1.20/?lanPort=53317'),
      isNull,
    );
    expect(parseLanShareWebSharePairingTarget('https:///path'), isNull);
  });
}
