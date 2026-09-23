import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/app/lan_share_windows_ffi.dart';

void main() {
  group('FfiLanShareWindowsIpHelperApi', () {
    test('reads IPv4 default rows and releases the native table once', () {
      final fixture = _RouteTableFixture(<_RouteRowSpec>[
        const _RouteRowSpec(
          interfaceIndex: 7,
          family: 2,
          destinationAddress: 0,
          prefixLength: 0,
          metric: 14,
        ),
        const _RouteRowSpec(
          interfaceIndex: 8,
          family: 2,
          destinationAddress: 0,
          prefixLength: 24,
          metric: 1,
        ),
        const _RouteRowSpec(
          interfaceIndex: 9,
          family: 23,
          destinationAddress: 0,
          prefixLength: 0,
          metric: 2,
        ),
        const _RouteRowSpec(
          interfaceIndex: 0,
          family: 2,
          destinationAddress: 0,
          prefixLength: 0,
          metric: 3,
        ),
      ]);
      var releaseCount = 0;
      final api = FfiLanShareWindowsIpHelperApi(
        getIpForwardTable2: (family, tableOut) {
          expect(family, 2);
          tableOut.value = fixture.table;
          return 0;
        },
        getIpInterfaceEntry: (_) => 0,
        freeMibTable: (table) {
          expect(table, fixture.table.cast<Void>());
          releaseCount++;
          fixture.dispose();
        },
      );

      final lease = api.getIpv4ForwardTable();
      expect(
        lease.rows.map((row) => (row.interfaceIndex, row.routeMetric)),
        <(int, int)>[(7, 14)],
      );
      expect(releaseCount, 0);

      lease.release();
      lease.release();
      expect(releaseCount, 1);
    });

    test('frees a returned table when the native route query fails', () {
      final fixture = _RouteTableFixture(const <_RouteRowSpec>[]);
      var releaseCount = 0;
      final api = FfiLanShareWindowsIpHelperApi(
        getIpForwardTable2: (_, tableOut) {
          tableOut.value = fixture.table;
          return 50;
        },
        getIpInterfaceEntry: (_) => 0,
        freeMibTable: (_) {
          releaseCount++;
          fixture.dispose();
        },
      );

      expect(api.getIpv4ForwardTable, throwsStateError);
      expect(releaseCount, 1);
    });

    test('rejects a successful native query with a null table', () {
      final api = FfiLanShareWindowsIpHelperApi(
        getIpForwardTable2: (_, _) => 0,
        getIpInterfaceEntry: (_) => 0,
        freeMibTable: (_) => fail('A null table has no native owner.'),
      );

      expect(api.getIpv4ForwardTable, throwsStateError);
    });

    test('reads interface metrics and reports native lookup failure', () {
      final api = FfiLanShareWindowsIpHelperApi(
        getIpForwardTable2: (_, _) => 0,
        getIpInterfaceEntry: (row) {
          row.ref.metric = 31;
          return 0;
        },
        freeMibTable: (_) {},
      );
      expect(api.getIpv4InterfaceMetric(7), 31);

      final failingApi = FfiLanShareWindowsIpHelperApi(
        getIpForwardTable2: (_, _) => 0,
        getIpInterfaceEntry: (_) => 50,
        freeMibTable: (_) {},
      );
      expect(() => failingApi.getIpv4InterfaceMetric(7), throwsStateError);
    });

    test('attempts dynamic IP Helper loading only on Windows', () {
      if (Platform.isWindows) return;
      final api = FfiLanShareWindowsIpHelperApi();

      expect(api.getIpv4ForwardTable, throwsArgumentError);
    });
  });
}

final class _RouteRowSpec {
  const _RouteRowSpec({
    required this.interfaceIndex,
    required this.family,
    required this.destinationAddress,
    required this.prefixLength,
    required this.metric,
  });

  final int interfaceIndex;
  final int family;
  final int destinationAddress;
  final int prefixLength;
  final int metric;
}

final class _RouteTableFixture {
  _RouteTableFixture(List<_RouteRowSpec> rows)
    : _allocation = calloc<Uint8>(
        sizeOf<LanShareMibIpForwardTableHeader>() +
            rows.length * sizeOf<LanShareMibIpForwardRow2>(),
      ) {
    table = _allocation.cast<Uint8>();
    table.cast<LanShareMibIpForwardTableHeader>().ref.numEntries = rows.length;
    final rowStart = (table + sizeOf<LanShareMibIpForwardTableHeader>())
        .cast<LanShareMibIpForwardRow2>();
    for (var index = 0; index < rows.length; index++) {
      final spec = rows[index];
      final row = (rowStart + index).ref;
      row
        ..interfaceIndex = spec.interfaceIndex
        ..metric = spec.metric;
      row.destinationPrefix.prefix.ipv4
        ..family = spec.family
        ..address = spec.destinationAddress;
      row.destinationPrefix.prefixLength = spec.prefixLength;
    }
  }

  final Pointer<Uint8> _allocation;
  late final Pointer<Uint8> table;

  void dispose() => calloc.free(_allocation);
}
