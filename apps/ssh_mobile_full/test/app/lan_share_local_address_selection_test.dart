import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/lan_share_local_address_selection.dart';

void main() {
  const wifi = lan.LanShareLocalIpv4Candidate(
    address: '192.168.1.20',
    interfaceName: 'Wi-Fi',
    interfaceIndex: 7,
  );
  const ethernet = lan.LanShareLocalIpv4Candidate(
    address: '10.0.0.20',
    interfaceName: 'Ethernet',
    interfaceIndex: 3,
  );
  const otherEthernetAddress = lan.LanShareLocalIpv4Candidate(
    address: '10.0.0.21',
    interfaceName: 'Ethernet',
    interfaceIndex: 3,
  );

  group('Windows IPv4 candidate selection', () {
    test('groups duplicate lowest routes by interface', () {
      final result = selectLanShareWindowsIpv4Candidate(
        candidates: const [wifi, ethernet],
        defaultRoutes: const [
          LanShareWindowsDefaultRouteMetric(
            interfaceIndex: 3,
            routeMetric: 5,
            interfaceMetric: 10,
          ),
          LanShareWindowsDefaultRouteMetric(
            interfaceIndex: 3,
            routeMetric: 4,
            interfaceMetric: 11,
          ),
          LanShareWindowsDefaultRouteMetric(
            interfaceIndex: 7,
            routeMetric: 1,
            interfaceMetric: 40,
          ),
        ],
      );

      expect(result, const lan.LanShareLocalAddressSelected(ethernet));
    });

    test('equal minimum metrics across interfaces are ambiguous', () {
      final result = selectLanShareWindowsIpv4Candidate(
        candidates: const [wifi, ethernet],
        defaultRoutes: const [
          LanShareWindowsDefaultRouteMetric(
            interfaceIndex: 7,
            routeMetric: 12,
            interfaceMetric: 8,
          ),
          LanShareWindowsDefaultRouteMetric(
            interfaceIndex: 3,
            routeMetric: 10,
            interfaceMetric: 10,
          ),
        ],
      );

      expect(result, isA<lan.LanShareLocalAddressAmbiguous>());
    });

    test('ignores routes for interfaces outside candidate set', () {
      final result = selectLanShareWindowsIpv4Candidate(
        candidates: const [wifi, ethernet],
        defaultRoutes: const [
          LanShareWindowsDefaultRouteMetric(
            interfaceIndex: 55,
            routeMetric: 0,
            interfaceMetric: 0,
          ),
          LanShareWindowsDefaultRouteMetric(
            interfaceIndex: 7,
            routeMetric: 2,
            interfaceMetric: 5,
          ),
        ],
      );

      expect(result, const lan.LanShareLocalAddressSelected(wifi));
    });

    test(
      'requires manual selection for multiple IPs on selected interface',
      () {
        final result = selectLanShareWindowsIpv4Candidate(
          candidates: const [otherEthernetAddress, ethernet, wifi],
          defaultRoutes: const [
            LanShareWindowsDefaultRouteMetric(
              interfaceIndex: 3,
              routeMetric: 2,
              interfaceMetric: 5,
            ),
            LanShareWindowsDefaultRouteMetric(
              interfaceIndex: 7,
              routeMetric: 2,
              interfaceMetric: 20,
            ),
          ],
        );

        expect(result, isA<lan.LanShareLocalAddressAmbiguous>());
        expect(
          (result as lan.LanShareLocalAddressAmbiguous).candidates,
          containsAll([ethernet, otherEthernetAddress]),
        );
      },
    );

    test(
      'uses sole candidate only after successful route query with no match',
      () {
        final selected = selectLanShareWindowsIpv4Candidate(
          candidates: const [wifi],
          defaultRoutes: const [],
        );
        final ambiguous = selectLanShareWindowsIpv4Candidate(
          candidates: const [wifi, ethernet],
          defaultRoutes: const [],
        );

        expect(selected, const lan.LanShareLocalAddressSelected(wifi));
        expect(ambiguous, isA<lan.LanShareLocalAddressAmbiguous>());
        expect(
          selectLanShareWindowsIpv4Candidate(
            candidates: const [],
            defaultRoutes: const [],
          ),
          isA<lan.LanShareLocalAddressUnavailable>(),
        );
      },
    );

    test('input order does not change selected interface or ambiguity', () {
      const routes = [
        LanShareWindowsDefaultRouteMetric(
          interfaceIndex: 7,
          routeMetric: 1,
          interfaceMetric: 10,
        ),
        LanShareWindowsDefaultRouteMetric(
          interfaceIndex: 3,
          routeMetric: 1,
          interfaceMetric: 30,
        ),
      ];

      expect(
        selectLanShareWindowsIpv4Candidate(
          candidates: const [wifi, ethernet],
          defaultRoutes: routes,
        ),
        const lan.LanShareLocalAddressSelected(wifi),
      );
      expect(
        selectLanShareWindowsIpv4Candidate(
          candidates: const [ethernet, wifi],
          defaultRoutes: routes,
        ),
        const lan.LanShareLocalAddressSelected(wifi),
      );
    });
  });

  test(
    'raw route reader releases a table once when interface lookup fails',
    () {
      final table = _FakeForwardTable(const [
        LanShareWindowsRouteRow(interfaceIndex: 3, routeMetric: 5),
      ]);
      final reader = LanShareWindowsRouteSnapshotReader(
        api: _FakeIpHelperApi(table: table, failInterfaceIndex: 3),
      );

      expect(() => reader.readDefaultRoutes({3}), throwsStateError);
      expect(table.releaseCount, 1);
    },
  );

  test(
    'native route-table failure does not trigger single-candidate fallback',
    () async {
      final selector = LanShareWindowsLocalAddressSelectionPort(
        routeReader: LanShareWindowsRouteSnapshotReader(
          api: _FakeIpHelperApi(
            table: _FakeForwardTable(const []),
            failTableQuery: true,
          ),
        ),
      );

      expect(
        await selector.selectPreferredIpv4(const [wifi]),
        isA<lan.LanShareLocalAddressUnavailable>(),
      );
    },
  );

  test('successful route snapshots release the returned table once', () {
    final table = _FakeForwardTable(const [
      LanShareWindowsRouteRow(interfaceIndex: 7, routeMetric: 5),
    ]);
    final reader = LanShareWindowsRouteSnapshotReader(
      api: _FakeIpHelperApi(table: table),
    );

    expect(reader.readDefaultRoutes({7}), hasLength(1));
    expect(table.releaseCount, 1);
  });

  test('production selector factory assigns platform choice to App root', () {
    final reader = LanShareWindowsRouteSnapshotReader(
      api: _FakeIpHelperApi(table: _FakeForwardTable(const [])),
    );

    expect(
      createLanShareLocalAddressSelectionPort(
        isWindows: true,
        windowsRouteReader: reader,
      ),
      isA<LanShareWindowsLocalAddressSelectionPort>(),
    );
    expect(
      createLanShareLocalAddressSelectionPort(isWindows: false),
      isA<lan.LanShareSingleCandidateLocalAddressSelection>(),
    );
  });
}

final class _FakeForwardTable implements LanShareWindowsForwardTableLease {
  _FakeForwardTable(this.rows);

  @override
  final List<LanShareWindowsRouteRow> rows;
  int releaseCount = 0;

  @override
  void release() => releaseCount++;
}

final class _FakeIpHelperApi implements LanShareWindowsIpHelperApi {
  _FakeIpHelperApi({
    required this.table,
    this.failInterfaceIndex,
    this.failTableQuery = false,
  });

  final _FakeForwardTable table;
  final int? failInterfaceIndex;
  final bool failTableQuery;

  @override
  LanShareWindowsForwardTableLease getIpv4ForwardTable() {
    if (failTableQuery) throw StateError('native route-table query failed');
    return table;
  }

  @override
  int getIpv4InterfaceMetric(int interfaceIndex) {
    if (interfaceIndex == failInterfaceIndex) {
      throw StateError('native interface query failed');
    }
    return 3;
  }
}
