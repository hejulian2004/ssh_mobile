import 'dart:convert';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final local = LanDiscoveryService.createUdpPingPayload(
    deviceId: 'desktop',
    alias: 'Desktop',
    os: 'windows',
    port: 53317,
  );
  final packet = <String, Object>{
    'type': 'PING',
    'id': 'android',
    'alias': 'Android',
    'os': 'android',
    'port': 53317,
    'nativePort': 45000,
  };

  test('UDP discovery replies to the observed source port across NAT', () {
    final replies = <(String, int)>[];
    final peers = <LanDiscoveredPeer>[];
    final handler = LanDiscoveryDatagramHandler(
      advertisement: local,
      reply: (bytes, address, port) {
        expect((jsonDecode(utf8.decode(bytes)) as Map)['id'], 'desktop');
        replies.add((address, port));
      },
      onPeer: peers.add,
      onRemove: (_) {},
    );
    handler.handle(utf8.encode(jsonEncode(packet)), '127.0.0.1', 41000);
    expect(replies, [('127.0.0.1', 41000)]);
    expect(peers, isEmpty);
    handler.handle(utf8.encode(jsonEncode(packet)), '::ffff:127.0.0.1', 41001);
    expect(replies.last, ('127.0.0.1', 41001));
    expect(peers, isEmpty);
  });

  test(
    'LAN advertisements retain separate native ports and device categories',
    () {
      final peers = <LanDiscoveredPeer>[];
      final removed = <String>[];
      var replies = 0;
      final handler = LanDiscoveryDatagramHandler(
        advertisement: local,
        reply: (_, _, _) => replies++,
        onPeer: peers.add,
        onRemove: removed.add,
      );
      void send(
        Map<String, Object> body, {
        String ip = '192.168.1.20',
        int port = 53318,
      }) => handler.handle(utf8.encode(jsonEncode(body)), ip, port);
      send(packet);
      expect(peers.single.advertisedNativePort, 45000);
      expect(peers.single.deviceType, LanDeviceType.mobile);
      send({...packet, 'type': 'PONG', 'os': 'ios'});
      send({...packet, 'type': 'PONG', 'os': 'web'});
      expect(peers.last.deviceType, LanDeviceType.webBrowser);
      send({...packet, 'type': 'PONG', 'os': 'windows'});
      expect(peers.last.deviceType, LanDeviceType.desktop);
      expect(replies, 1);
      for (final type in ['BYE', 'DISCONNECT', 'OFFLINE']) {
        send({'type': type, 'id': 'Alias (android)'});
      }
      expect(removed, ['android', 'android', 'android']);
      final count = peers.length;
      for (final invalid in [
        {...packet, 'id': ''},
        {...packet, 'id': 'desktop'},
        {...packet, 'id': 123},
        {...packet, 'id': 'a' * 129},
        {...packet, 'alias': ''},
        {...packet, 'alias': 'a' * 129},
        {...packet, 'os': ''},
        {...packet, 'os': 'a' * 65},
        {...packet, 'port': 0},
        {...packet, 'port': 65536},
        {...packet, 'port': 12.5},
        {...packet, 'nativePort': 0},
        {...packet, 'type': 'UNKNOWN'},
      ]) {
        send(invalid);
      }
      send(packet, ip: 'invalid');
      send(packet, port: 0);
      send(packet, port: 65536);
      handler.handle([255], '192.168.1.20', 53318);
      handler.handle(utf8.encode('[]'), '192.168.1.20', 53318);
      handler.handle(List.filled(4097, 0), '192.168.1.20', 53318);
      expect(peers.length, count);
    },
  );
}
