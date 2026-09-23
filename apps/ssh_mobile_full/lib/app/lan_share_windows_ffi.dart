import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'lan_share_windows_route_models.dart';

typedef LanShareGetIpForwardTable2Native =
    int Function(int family, Pointer<Pointer<Uint8>> table);
typedef LanShareGetIpInterfaceEntryNative =
    int Function(Pointer<LanShareMibIpInterfaceRow> row);
typedef LanShareFreeMibTableNative = void Function(Pointer<Void> table);

/// Minimal local IP Helper bindings for APIs not guaranteed by win32's
/// curated Dart surface. No generated package bindings are modified.
final class FfiLanShareWindowsIpHelperApi
    implements LanShareWindowsIpHelperApi {
  FfiLanShareWindowsIpHelperApi({
    DynamicLibrary? library,
    LanShareGetIpForwardTable2Native? getIpForwardTable2,
    LanShareGetIpInterfaceEntryNative? getIpInterfaceEntry,
    LanShareFreeMibTableNative? freeMibTable,
  }) : _providedLibrary = library,
       _getIpForwardTable2Override = getIpForwardTable2,
       _getIpInterfaceEntryOverride = getIpInterfaceEntry,
       _freeMibTableOverride = freeMibTable;

  final DynamicLibrary? _providedLibrary;
  final LanShareGetIpForwardTable2Native? _getIpForwardTable2Override;
  final LanShareGetIpInterfaceEntryNative? _getIpInterfaceEntryOverride;
  final LanShareFreeMibTableNative? _freeMibTableOverride;
  late final DynamicLibrary _library =
      _providedLibrary ?? DynamicLibrary.open('iphlpapi.dll');

  late final LanShareGetIpForwardTable2Native _getIpForwardTable2 =
      _getIpForwardTable2Override ??
      _library.lookupFunction<
        Uint32 Function(Uint16, Pointer<Pointer<Uint8>>),
        int Function(int, Pointer<Pointer<Uint8>>)
      >('GetIpForwardTable2');
  late final LanShareGetIpInterfaceEntryNative _getIpInterfaceEntry =
      _getIpInterfaceEntryOverride ??
      _library.lookupFunction<
        Uint32 Function(Pointer<LanShareMibIpInterfaceRow>),
        int Function(Pointer<LanShareMibIpInterfaceRow>)
      >('GetIpInterfaceEntry');
  late final LanShareFreeMibTableNative _freeMibTable =
      _freeMibTableOverride ??
      _library.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('FreeMibTable');

  @override
  LanShareWindowsForwardTableLease getIpv4ForwardTable() {
    final tableOut = calloc<Pointer<Uint8>>();
    Pointer<Uint8> table = nullptr;
    var tableOwned = false;
    try {
      final status = _getIpForwardTable2(_afInet, tableOut);
      table = tableOut.value;
      tableOwned = table.address != 0;
      if (status != 0) {
        throw StateError('GetIpForwardTable2 failed with status $status.');
      }
      if (!tableOwned) {
        throw StateError('GetIpForwardTable2 returned no route table.');
      }
      final rows = _readIpv4DefaultRouteRows(table);
      return _FfiLanShareWindowsForwardTableLease(
        rows: rows,
        table: table,
        releaseTable: _freeMibTable,
      );
    } on Object {
      if (tableOwned) _freeMibTable(table.cast<Void>());
      rethrow;
    } finally {
      calloc.free(tableOut);
    }
  }

  List<LanShareWindowsRouteRow> _readIpv4DefaultRouteRows(
    Pointer<Uint8> table,
  ) {
    final count = table.cast<Uint32>().value;
    final rowsStart = (table + sizeOf<LanShareMibIpForwardTableHeader>())
        .cast<LanShareMibIpForwardRow2>();
    final rows = <LanShareWindowsRouteRow>[];
    for (var index = 0; index < count; index++) {
      final row = (rowsStart + index).ref;
      final prefix = row.destinationPrefix;
      if (prefix.prefix.ipv4.family != _afInet ||
          prefix.prefix.ipv4.address != 0 ||
          prefix.prefixLength != 0 ||
          row.interfaceIndex == 0) {
        continue;
      }
      rows.add(
        LanShareWindowsRouteRow(
          interfaceIndex: row.interfaceIndex,
          routeMetric: row.metric,
        ),
      );
    }
    return List.unmodifiable(rows);
  }

  @override
  int getIpv4InterfaceMetric(int interfaceIndex) {
    final row = calloc<LanShareMibIpInterfaceRow>();
    try {
      row.ref
        ..family = _afInet
        ..interfaceIndex = interfaceIndex;
      final status = _getIpInterfaceEntry(row);
      if (status != 0) {
        throw StateError('GetIpInterfaceEntry failed with status $status.');
      }
      return row.ref.metric;
    } finally {
      calloc.free(row);
    }
  }
}

final class _FfiLanShareWindowsForwardTableLease
    implements LanShareWindowsForwardTableLease {
  _FfiLanShareWindowsForwardTableLease({
    required this.rows,
    required this.table,
    required this.releaseTable,
  });

  @override
  final List<LanShareWindowsRouteRow> rows;
  final Pointer<Uint8> table;
  final void Function(Pointer<Void>) releaseTable;
  bool _released = false;

  @override
  void release() {
    if (_released) return;
    _released = true;
    releaseTable(table.cast<Void>());
  }
}

const int _afInet = 2;

final class LanShareMibIpForwardTableHeader extends Struct {
  @Uint32()
  external int numEntries;

  @Uint32()
  external int alignmentPadding;
}

final class LanShareSockaddrIn extends Struct {
  @Uint16()
  external int family;

  @Uint16()
  external int port;

  @Uint32()
  external int address;

  @Array(8)
  external Array<Uint8> zero;
}

final class LanShareSockaddrIn6 extends Struct {
  @Uint16()
  external int family;

  @Uint16()
  external int port;

  @Uint32()
  external int flowInfo;

  @Array(16)
  external Array<Uint8> address;

  @Uint32()
  external int scopeId;
}

final class LanShareSockaddrInet extends Union {
  external LanShareSockaddrIn ipv4;

  external LanShareSockaddrIn6 ipv6;

  @Uint32()
  external int alignment;
}

final class LanShareIpAddressPrefix extends Struct {
  external LanShareSockaddrInet prefix;

  @Uint8()
  external int prefixLength;
}

final class LanShareMibIpForwardRow2 extends Struct {
  @Uint64()
  external int interfaceLuid;

  @Uint32()
  external int interfaceIndex;

  external LanShareIpAddressPrefix destinationPrefix;

  external LanShareSockaddrInet nextHop;

  @Uint8()
  external int sitePrefixLength;

  @Uint32()
  external int validLifetime;

  @Uint32()
  external int preferredLifetime;

  @Uint32()
  external int metric;

  @Uint32()
  external int protocol;

  @Uint8()
  external int loopback;

  @Uint8()
  external int autoconfigureAddress;

  @Uint8()
  external int publish;

  @Uint8()
  external int immortal;

  @Uint32()
  external int age;

  @Uint32()
  external int origin;
}

final class LanShareMibIpInterfaceRow extends Struct {
  @Uint16()
  external int family;

  @Uint64()
  external int interfaceLuid;

  @Uint32()
  external int interfaceIndex;

  @Uint32()
  external int maxReassemblySize;

  @Uint64()
  external int interfaceIdentifier;

  @Uint32()
  external int minRouterAdvertisementInterval;

  @Uint32()
  external int maxRouterAdvertisementInterval;

  @Uint8()
  external int advertisingEnabled;

  @Uint8()
  external int forwardingEnabled;

  @Uint8()
  external int weakHostSend;

  @Uint8()
  external int weakHostReceive;

  @Uint8()
  external int useAutomaticMetric;

  @Uint8()
  external int useNeighborUnreachabilityDetection;

  @Uint8()
  external int managedAddressConfigurationSupported;

  @Uint8()
  external int otherStatefulConfigurationSupported;

  @Uint8()
  external int advertiseDefaultRoute;

  @Int32()
  external int routerDiscoveryBehavior;

  @Uint32()
  external int dadTransmits;

  @Uint32()
  external int baseReachableTime;

  @Uint32()
  external int retransmitTime;

  @Uint32()
  external int pathMtuDiscoveryTimeout;

  @Int32()
  external int linkLocalAddressBehavior;

  @Uint32()
  external int linkLocalAddressTimeout;

  @Array(16)
  external Array<Uint32> zoneIndices;

  @Uint32()
  external int sitePrefixLength;

  @Uint32()
  external int metric;

  @Uint32()
  external int nlMtu;

  @Uint8()
  external int connected;

  @Uint8()
  external int supportsWakeUpPatterns;

  @Uint8()
  external int supportsNeighborDiscovery;

  @Uint8()
  external int supportsRouterDiscovery;

  @Uint32()
  external int reachableTime;

  @Uint8()
  external int transmitOffload;

  @Uint8()
  external int receiveOffload;

  @Uint8()
  external int disableDefaultRoutes;
}
