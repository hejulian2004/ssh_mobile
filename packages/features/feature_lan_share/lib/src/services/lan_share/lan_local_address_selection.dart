import 'dart:io';

import '../../domain/lan_share_ports.dart';

/// Loads the current eligible local IPv4 candidates from the host OS.
abstract interface class LanShareLocalIpv4CandidateSource {
  Future<List<LanShareLocalIpv4Candidate>> loadCandidates();
}

/// Feature-owned candidate collection through the cross-platform Dart API.
final class DartLanShareLocalIpv4CandidateSource
    implements LanShareLocalIpv4CandidateSource {
  const DartLanShareLocalIpv4CandidateSource();

  @override
  Future<List<LanShareLocalIpv4Candidate>> loadCandidates() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    final candidates = <LanShareLocalIpv4Candidate>[];
    for (final interface in interfaces) {
      if (_isVirtualNetworkInterface(interface.name)) continue;
      for (final address in interface.addresses) {
        if (address.type != InternetAddressType.IPv4 ||
            address.isLoopback ||
            address.address.startsWith('169.254.')) {
          continue;
        }
        candidates.add(
          LanShareLocalIpv4Candidate(
            address: address.address,
            interfaceName: interface.name,
            interfaceIndex: interface.index,
          ),
        );
      }
    }
    return sortLanShareLocalIpv4Candidates(candidates);
  }

  static bool _isVirtualNetworkInterface(String name) {
    final lowerName = name.toLowerCase();
    const markers = <String>[
      'docker',
      'vethernet',
      'vbox',
      'vmnet',
      'wireguard',
      'wintun',
      'tailscale',
      'zerotier',
      'hamachi',
      'nordlynx',
      'mullvad',
      'vpn',
      'tun',
      'tap',
      'utun',
      'ppp',
    ];
    return markers.any(lowerName.contains);
  }
}

/// Applies explicit override precedence before delegating Automatic selection.
final class LanShareLocalAddressResolver {
  const LanShareLocalAddressResolver({
    required this.candidateSource,
    required this.selectionPort,
  });

  final LanShareLocalIpv4CandidateSource candidateSource;
  final LanShareLocalAddressSelectionPort selectionPort;

  Future<LanShareLocalAddressSelectionResult> resolve({
    String? override,
  }) async {
    late final List<LanShareLocalIpv4Candidate> candidates;
    try {
      candidates = await candidateSource.loadCandidates();
    } on Object {
      return const LanShareLocalAddressUnavailable();
    }

    if (override != null) {
      for (final candidate in candidates) {
        if (candidate.address == override) {
          return LanShareLocalAddressSelected(candidate);
        }
      }
      return LanShareLocalAddressStaleOverride(override);
    }

    try {
      return await selectionPort.selectPreferredIpv4(
        sortLanShareLocalIpv4Candidates(candidates),
      );
    } on Object {
      return const LanShareLocalAddressUnavailable();
    }
  }
}
