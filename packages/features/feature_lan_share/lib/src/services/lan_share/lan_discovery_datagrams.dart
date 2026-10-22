import 'dart:convert';
import 'dart:io';

import 'lan_share_models.dart';

/// Processes bounded UDP discovery messages independently of socket ownership.
final class LanDiscoveryDatagramHandler {
  LanDiscoveryDatagramHandler({
    required this.advertisement,
    required this.reply,
    required this.onPeer,
    required this.onRemove,
  });

  final Map<String, Object> advertisement;
  final void Function(List<int> bytes, String address, int port) reply;
  final void Function(LanDiscoveredPeer peer) onPeer;
  final void Function(String peerId) onRemove;

  void handle(List<int> bytes, String sourceAddress, int sourcePort) {
    if (bytes.length > 4096 || sourcePort < 1 || sourcePort > 65535) {
      return;
    }
    try {
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic>) {
        return;
      }
      final rawId = body['id'];
      if (rawId is! String || rawId.length > 128) {
        return;
      }
      final id = rawId.contains('(') && rawId.endsWith(')')
          ? rawId.substring(rawId.lastIndexOf('(') + 1, rawId.length - 1).trim()
          : rawId.trim();
      if (id.isEmpty || id == advertisement['id']) {
        return;
      }
      final type = body['type'];
      if (type == 'BYE' || type == 'DISCONNECT' || type == 'OFFLINE') {
        onRemove(id);
        return;
      }
      if (type != 'PING' && type != 'PONG') {
        return;
      }
      final alias = body['alias'];
      final os = body['os'];
      final port = body['port'];
      final nativePort = body['nativePort'];
      if (alias is! String ||
          alias.isEmpty ||
          alias.length > 128 ||
          os is! String ||
          os.isEmpty ||
          os.length > 64 ||
          port is! int ||
          port < 1 ||
          port > 65535 ||
          (nativePort != null &&
              (nativePort is! int || nativePort < 1 || nativePort > 65535))) {
        return;
      }
      final address = sourceAddress.startsWith('::ffff:')
          ? sourceAddress.substring(7)
          : sourceAddress;
      if (InternetAddress.tryParse(address) == null) {
        return;
      }
      if (type == 'PING') {
        reply(
          utf8.encode(jsonEncode({...advertisement, 'type': 'PONG'})),
          address,
          sourcePort,
        );
      }
      // NAT loopback observations need a separately established local mapping.
      if (InternetAddress(address).isLoopback) {
        return;
      }
      final lowerOs = os.toLowerCase();
      onPeer(
        LanDiscoveredPeer(
          deviceId: id,
          alias: alias,
          ip: address,
          controlPort: port,
          advertisedNativePort: nativePort as int?,
          os: os,
          deviceType: lowerOs.contains('android') || lowerOs.contains('ios')
              ? LanDeviceType.mobile
              : lowerOs.contains('web')
              ? LanDeviceType.webBrowser
              : LanDeviceType.desktop,
          lastSeen: DateTime.now(),
        ),
      );
    } on Object {
      // Malformed discovery data cannot create a peer or escape the UDP loop.
    }
  }
}
