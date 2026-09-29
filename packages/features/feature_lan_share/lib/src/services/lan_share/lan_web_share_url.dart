/// Parsed address and Network V2 control port advertised by a WebShare QR URL.
final class LanShareWebSharePairingTarget {
  const LanShareWebSharePairingTarget({
    required this.host,
    required this.controlPort,
    required this.nativePort,
    required this.deviceId,
  });

  final String host;
  final int controlPort;
  final int? nativePort;
  final String? deviceId;
}

/// Parses the stable pairing fields from an HTTPS WebShare URL.
///
/// Browser access tokens and certificate fingerprints remain WebShare
/// transport fields and are intentionally not used by the LAN invite parser.
LanShareWebSharePairingTarget? parseLanShareWebSharePairingTarget(
  String input,
) {
  final uri = Uri.tryParse(input);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  final queryPort = int.tryParse(uri.queryParameters['lanPort'] ?? '');
  final queryNativePort = int.tryParse(uri.queryParameters['nativePort'] ?? '');
  final rawDeviceId = uri.queryParameters['deviceId']?.trim();
  return LanShareWebSharePairingTarget(
    host: uri.host,
    controlPort: queryPort ?? (uri.port > 0 ? uri.port : 53317),
    nativePort: queryNativePort,
    deviceId: rawDeviceId == null || rawDeviceId.isEmpty ? null : rawDeviceId,
  );
}
