/// One IPv4 default-route row returned by the App-owned raw route reader.
final class LanShareWindowsRouteRow {
  const LanShareWindowsRouteRow({
    required this.interfaceIndex,
    required this.routeMetric,
  });

  final int interfaceIndex;
  final int routeMetric;
}

/// An eligible default route with its corresponding interface metric.
final class LanShareWindowsDefaultRouteMetric {
  const LanShareWindowsDefaultRouteMetric({
    required this.interfaceIndex,
    required this.routeMetric,
    required this.interfaceMetric,
  });

  final int interfaceIndex;
  final int routeMetric;
  final int interfaceMetric;

  int get effectiveMetric => routeMetric + interfaceMetric;
}

/// Lease around the IP Helper-owned route table buffer.
abstract interface class LanShareWindowsForwardTableLease {
  List<LanShareWindowsRouteRow> get rows;

  void release();
}

/// App-local boundary around native IP Helper calls, fakeable in adapter tests.
abstract interface class LanShareWindowsIpHelperApi {
  LanShareWindowsForwardTableLease getIpv4ForwardTable();

  int getIpv4InterfaceMetric(int interfaceIndex);
}

/// Reads default-route and interface metrics, always releasing the route table.
final class LanShareWindowsRouteSnapshotReader {
  const LanShareWindowsRouteSnapshotReader({required this.api});

  final LanShareWindowsIpHelperApi api;

  List<LanShareWindowsDefaultRouteMetric> readDefaultRoutes(
    Set<int> eligibleInterfaceIndexes,
  ) {
    final table = api.getIpv4ForwardTable();
    try {
      final interfaceMetrics = <int, int>{};
      final result = <LanShareWindowsDefaultRouteMetric>[];
      for (final row in table.rows) {
        if (!eligibleInterfaceIndexes.contains(row.interfaceIndex)) continue;
        final interfaceMetric = interfaceMetrics.putIfAbsent(
          row.interfaceIndex,
          () => api.getIpv4InterfaceMetric(row.interfaceIndex),
        );
        result.add(
          LanShareWindowsDefaultRouteMetric(
            interfaceIndex: row.interfaceIndex,
            routeMetric: row.routeMetric,
            interfaceMetric: interfaceMetric,
          ),
        );
      }
      return List.unmodifiable(result);
    } finally {
      table.release();
    }
  }
}
