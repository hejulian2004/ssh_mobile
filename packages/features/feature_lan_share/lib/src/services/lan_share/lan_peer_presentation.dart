import 'package:network_sdk/network_sdk.dart';

import 'lan_peer_trust.dart';

const Object _lanPeerUnset = Object();

/// Device type enumeration.
enum LanDeviceType {
  mobile,
  desktop,
  webBrowser;

  String toJson() => name;

  static LanDeviceType fromJson(String value) {
    return LanDeviceType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => LanDeviceType.mobile,
    );
  }
}

/// A point-in-time observation received from LAN discovery.
///
/// This type deliberately contains only dynamic discovery data.  In
/// particular, it has no certificate, access token, public-key, or `trusted`
/// field.  Those values belong to [LanPeerTrustRecord] and are never inferred
/// from mDNS/UDP advertisements.
final class LanDiscoveredPeer {
  const LanDiscoveredPeer({
    required this.deviceId,
    required this.alias,
    required this.ip,
    required this.controlPort,
    this.advertisedNativePort,
    required this.os,
    this.deviceType = LanDeviceType.desktop,
    required this.lastSeen,
  });

  final String deviceId;
  final String alias;
  final String ip;
  final int controlPort;
  final int? advertisedNativePort;
  final LanDeviceType deviceType;
  final String os;
  final DateTime lastSeen;

  LanDiscoveredPeer copyWith({
    String? deviceId,
    String? alias,
    String? ip,
    int? controlPort,
    Object? advertisedNativePort = _lanPeerUnset,
    LanDeviceType? deviceType,
    String? os,
    DateTime? lastSeen,
  }) {
    return LanDiscoveredPeer(
      deviceId: deviceId ?? this.deviceId,
      alias: alias ?? this.alias,
      ip: ip ?? this.ip,
      controlPort: controlPort ?? this.controlPort,
      advertisedNativePort: identical(advertisedNativePort, _lanPeerUnset)
          ? this.advertisedNativePort
          : advertisedNativePort as int?,
      deviceType: deviceType ?? this.deviceType,
      os: os ?? this.os,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'deviceId': deviceId,
    'alias': alias,
    'ip': ip,
    'controlPort': controlPort,
    if (advertisedNativePort != null)
      'advertisedNativePort': advertisedNativePort,
    'deviceType': deviceType.toJson(),
    'os': os,
    'lastSeen': lastSeen.toIso8601String(),
  };

  factory LanDiscoveredPeer.fromJson(Map<String, dynamic> json) {
    final deviceId = json['deviceId'];
    final alias = json['alias'];
    final ip = json['ip'];
    final controlPort = json['controlPort'];
    final os = json['os'];
    final deviceType = json['deviceType'];
    final lastSeen = json['lastSeen'];
    if (deviceId is! String || deviceId.trim().isEmpty) {
      throw const FormatException('Missing V2 LAN peer deviceId.');
    }
    if (alias is! String || ip is! String || os is! String) {
      throw const FormatException('Invalid V2 LAN peer discovery fields.');
    }
    if (controlPort is! num ||
        controlPort.toInt() < 1 ||
        controlPort.toInt() > 65535) {
      throw const FormatException('Invalid V2 LAN peer controlPort.');
    }
    if (deviceType is! String ||
        !LanDeviceType.values.any((value) => value.name == deviceType)) {
      throw const FormatException('Invalid V2 LAN peer deviceType.');
    }
    if (lastSeen is! String) {
      throw const FormatException('Missing V2 LAN peer lastSeen.');
    }
    final parsedLastSeen = DateTime.tryParse(lastSeen);
    if (parsedLastSeen == null) {
      throw const FormatException('Invalid V2 LAN peer lastSeen.');
    }
    return LanDiscoveredPeer(
      deviceId: deviceId,
      alias: alias,
      ip: ip,
      controlPort: controlPort.toInt(),
      advertisedNativePort: (json['advertisedNativePort'] as num?)?.toInt(),
      deviceType: LanDeviceType.fromJson(deviceType),
      os: os,
      lastSeen: parsedLastSeen,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LanDiscoveredPeer &&
      other.deviceId == deviceId &&
      other.alias == alias &&
      other.ip == ip &&
      other.controlPort == controlPort &&
      other.advertisedNativePort == advertisedNativePort &&
      other.deviceType == deviceType &&
      other.os == os &&
      other.lastSeen == lastSeen;

  @override
  int get hashCode => Object.hash(
    deviceId,
    alias,
    ip,
    controlPort,
    advertisedNativePort,
    deviceType,
    os,
    lastSeen,
  );
}

/// Reachability is an observation and is independent from trust.
enum LanPeerReachability { unknown, online, offline }

/// Route availability presented by the network layer for one peer.
///
/// This is intentionally separate from [LanPeerTrustRecord.authorization]:
/// authorization says what is allowed, while this type says what is currently
/// available.  A route can be unavailable while its authorization remains
/// persisted, for example when a peer leaves the LAN or the Relay disconnects.
final class LanPeerRouteState {
  const LanPeerRouteState({
    this.directAvailable = false,
    this.relayAvailable = false,
    this.activeRoute,
    this.endpoint,
    this.updatedAt,
  });

  final bool directAvailable;
  final bool relayAvailable;
  final NetworkRouteType? activeRoute;
  final String? endpoint;
  final DateTime? updatedAt;

  bool get isAvailable => directAvailable || relayAvailable;

  /// Presentation aliases make the authorization/availability distinction
  /// explicit at call sites while keeping the model compact.
  bool get localDirectAvailable => directAvailable;
  bool get relayRouteAvailable => relayAvailable;

  LanPeerRouteState copyWith({
    bool? directAvailable,
    bool? relayAvailable,
    Object? activeRoute = _lanPeerUnset,
    Object? endpoint = _lanPeerUnset,
    Object? updatedAt = _lanPeerUnset,
  }) => LanPeerRouteState(
    directAvailable: directAvailable ?? this.directAvailable,
    relayAvailable: relayAvailable ?? this.relayAvailable,
    activeRoute: identical(activeRoute, _lanPeerUnset)
        ? this.activeRoute
        : activeRoute as NetworkRouteType?,
    endpoint: identical(endpoint, _lanPeerUnset)
        ? this.endpoint
        : endpoint as String?,
    updatedAt: identical(updatedAt, _lanPeerUnset)
        ? this.updatedAt
        : updatedAt as DateTime?,
  );
}

/// Presentation projection of the independent LAN peer state domains.
///
/// `trust != null && discovery == null` is a valid, first-class trusted
/// offline state.  Discovery records may disappear without deleting trust;
/// route availability can also disappear without changing either one.
final class LanPeerViewState {
  LanPeerViewState({
    String? peerId,
    this.trust,
    this.discovery,
    this.savedAlias,
    this.savedDeviceType,
    DateTime? lastOnlineAt,
    LanPeerReachability? reachability,
    this.route = const LanPeerRouteState(),
  }) : lastOnlineAt = lastOnlineAt ?? discovery?.lastSeen,
       peerId = peerId ?? trust?.deviceId ?? discovery?.deviceId ?? '',
       reachability =
           reachability ??
           (discovery != null
               ? LanPeerReachability.online
               : trust != null
               ? LanPeerReachability.offline
               : LanPeerReachability.unknown);

  final String peerId;
  final LanPeerTrustRecord? trust;
  final LanDiscoveredPeer? discovery;
  final LanPeerReachability reachability;
  final LanPeerRouteState route;
  final String? savedAlias;
  final LanDeviceType? savedDeviceType;
  final DateTime? lastOnlineAt;

  String get deviceId => peerId;
  bool get isTrusted => trust != null;
  bool get isDiscovered => discovery != null;
  bool get isOnline => reachability == LanPeerReachability.online;
  bool get isOffline => reachability == LanPeerReachability.offline;
  bool get isTrustedOffline => isTrusted && isOffline;
  bool get canUseRoute => route.isAvailable;

  String get displayAlias => discovery?.alias ?? savedAlias ?? peerId;
  LanDeviceType get deviceType =>
      discovery?.deviceType ?? savedDeviceType ?? LanDeviceType.desktop;
  String? get ip => discovery?.ip;
  int? get controlPort => discovery?.controlPort;
  int? get advertisedNativePort => discovery?.advertisedNativePort;

  LanPeerViewState copyWith({
    Object? peerId = _lanPeerUnset,
    Object? trust = _lanPeerUnset,
    Object? discovery = _lanPeerUnset,
    LanPeerReachability? reachability,
    LanPeerRouteState? route,
    Object? savedAlias = _lanPeerUnset,
    Object? savedDeviceType = _lanPeerUnset,
    Object? lastOnlineAt = _lanPeerUnset,
  }) => LanPeerViewState(
    peerId: identical(peerId, _lanPeerUnset) ? this.peerId : peerId as String?,
    trust: identical(trust, _lanPeerUnset)
        ? this.trust
        : trust as LanPeerTrustRecord?,
    discovery: identical(discovery, _lanPeerUnset)
        ? this.discovery
        : discovery as LanDiscoveredPeer?,
    reachability: reachability ?? this.reachability,
    route: route ?? this.route,
    savedAlias: identical(savedAlias, _lanPeerUnset)
        ? this.savedAlias
        : savedAlias as String?,
    savedDeviceType: identical(savedDeviceType, _lanPeerUnset)
        ? this.savedDeviceType
        : savedDeviceType as LanDeviceType?,
    lastOnlineAt: identical(lastOnlineAt, _lanPeerUnset)
        ? this.lastOnlineAt
        : lastOnlineAt as DateTime?,
  );
}

/// A short-lived navigation and protocol request for pairing two LAN devices.
class LanPairingRequest {
  final LanPeerViewState peer;
  final String sessionId;
  final bool isIncoming;
  final DateTime expiresAt;

  const LanPairingRequest({
    required this.peer,
    required this.sessionId,
    required this.isIncoming,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
