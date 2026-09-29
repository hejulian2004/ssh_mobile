import 'package:feature_lan_share/feature_lan_share.dart' as lan;

import 'lan_share_windows_ffi.dart';
import 'lan_share_windows_route_models.dart';

export 'lan_share_windows_route_models.dart';

/// Pure Windows route-aware selection algorithm, independent of FFI.
lan.LanShareLocalAddressSelectionResult selectLanShareWindowsIpv4Candidate({
  required List<lan.LanShareLocalIpv4Candidate> candidates,
  required List<LanShareWindowsDefaultRouteMetric> defaultRoutes,
}) {
  final orderedCandidates = lan.sortLanShareLocalIpv4Candidates(candidates);
  if (orderedCandidates.isEmpty) {
    return const lan.LanShareLocalAddressUnavailable();
  }

  final candidateIndexes = orderedCandidates
      .map((candidate) => candidate.interfaceIndex)
      .toSet();
  final minimumByInterface = <int, int>{};
  for (final route in defaultRoutes) {
    if (!candidateIndexes.contains(route.interfaceIndex)) continue;
    final current = minimumByInterface[route.interfaceIndex];
    if (current == null || route.effectiveMetric < current) {
      minimumByInterface[route.interfaceIndex] = route.effectiveMetric;
    }
  }

  if (minimumByInterface.isEmpty) {
    if (orderedCandidates.length == 1) {
      return lan.LanShareLocalAddressSelected(orderedCandidates.single);
    }
    return lan.LanShareLocalAddressAmbiguous(orderedCandidates);
  }

  final lowestMetric = minimumByInterface.values.reduce(
    (left, right) => left < right ? left : right,
  );
  final preferredIndexes = minimumByInterface.entries
      .where((entry) => entry.value == lowestMetric)
      .map((entry) => entry.key)
      .toSet();
  if (preferredIndexes.length != 1) {
    return lan.LanShareLocalAddressAmbiguous(
      orderedCandidates
          .where(
            (candidate) => preferredIndexes.contains(candidate.interfaceIndex),
          )
          .toList(),
    );
  }

  final selectedInterface = preferredIndexes.single;
  final interfaceCandidates = orderedCandidates
      .where((candidate) => candidate.interfaceIndex == selectedInterface)
      .toList();
  if (interfaceCandidates.length != 1) {
    return lan.LanShareLocalAddressAmbiguous(interfaceCandidates);
  }
  return lan.LanShareLocalAddressSelected(interfaceCandidates.single);
}

/// App-provided Windows selector implementing the Feature port.
final class LanShareWindowsLocalAddressSelectionPort
    implements lan.LanShareLocalAddressSelectionPort {
  const LanShareWindowsLocalAddressSelectionPort({required this.routeReader});

  final LanShareWindowsRouteSnapshotReader routeReader;

  @override
  Future<lan.LanShareLocalAddressSelectionResult> selectPreferredIpv4(
    List<lan.LanShareLocalIpv4Candidate> candidates,
  ) async {
    if (candidates.isEmpty) {
      return const lan.LanShareLocalAddressUnavailable();
    }
    try {
      final indexes = candidates
          .map((candidate) => candidate.interfaceIndex)
          .toSet();
      final routes = routeReader.readDefaultRoutes(indexes);
      return selectLanShareWindowsIpv4Candidate(
        candidates: candidates,
        defaultRoutes: routes,
      );
    } on Object {
      // A route or interface query failure is not equivalent to no routes.
      return const lan.LanShareLocalAddressUnavailable();
    }
  }
}

/// App composition-root platform choice for the Feature selector port.
lan.LanShareLocalAddressSelectionPort createLanShareLocalAddressSelectionPort({
  required bool isWindows,
  LanShareWindowsRouteSnapshotReader? windowsRouteReader,
}) {
  if (!isWindows) {
    return const lan.LanShareSingleCandidateLocalAddressSelection();
  }
  return LanShareWindowsLocalAddressSelectionPort(
    routeReader:
        windowsRouteReader ??
        LanShareWindowsRouteSnapshotReader(
          api: FfiLanShareWindowsIpHelperApi(),
        ),
  );
}
