// LAN Share 的跨边界契约。
//
// 这些 Port 让 Feature 使用 App Scope 的设置、日志、数据保护和网络能力，
// 同时避免把 App Service、SSH 或其他 Feature 的实现带入 Package。

import 'package:flutter/foundation.dart';

import 'package:network_sdk/network_sdk.dart';

import 'lan_relay_ports.dart';

export 'lan_relay_ports.dart';

/// LAN Share 支持的界面语言。
enum LanShareLanguage { zh, en }

/// LAN Share 设置和身份的最小 App Scope 合约。
abstract interface class LanShareSettingsPort
    implements Listenable, LanRelaySettingsPort {
  /// 当前界面语言。
  LanShareLanguage get language;

  /// 当前是否使用英文界面。
  bool get isEnglish;

  /// 当前语言对应的 LAN 文案。
  LanShareStrings get strings;

  /// 本机稳定 LAN 设备标识。
  String get lanDeviceId;

  /// 本机广播和配对使用的显示别名。
  String get lanDeviceAlias;

  /// 已配置的 Relay origin；不包含凭据。
  @override
  String get relayEndpoint;

  /// Relay 主机名，供设置页显示。
  String get relayHost;

  /// Relay 端口，未配置时使用 HTTPS 默认端口。
  int get relayPort;

  /// App 是否要求在后台常驻激活 LAN Receiver。
  bool get receiverEnabled;

  /// 按需加载或生成本机 LAN 身份。
  Future<void> ensureLanIdentity();

  /// 保存显示别名。
  Future<void> setLanDeviceAlias(String alias);

  /// 保存 Relay origin。
  @override
  Future<void> setRelayEndpoint(String endpoint);

  /// 按主机和端口保存 Relay origin。
  Future<void> setRelayServer({required String host, required int port});
}

/// LAN Share UI 所需的最小本地化文案集合。
abstract interface class LanShareStrings {
  bool get isEnglish;

  String get accept;
  String get cancel;
  String get close;
  String get connected;
  String get copy;
  String get disconnected;
  String get delete;
  String get deleteConnectionConfirm;
  String get externalPreviewContentBlocked;
  String get filePreviewRenderFailed;
  String get filePreviewRenderFailedHint;
  String get filePreviewResourceLimit;
  String get filePreviewResourceLimitHint;
  String get filePreviewTooLarge;
  String filePreviewTooLargeHint(int maxBytes);
  String get hostAddress;
  String get htmlPreviewUnavailable;
  String get htmlPreviewUnavailableHint;
  String get imagePreviewLabel;
  String get invalidPort;
  String get loadingFilePreview;
  String get moreActions;
  String networkIncomingTransferDescription(
    String senderId,
    String fileName,
    String fileSize,
  );
  String get networkIncomingTransferTitle;
  String get port;
  String get reject;
  String get retry;
  String get save;
  String get unknown;
  String get unsupportedPreview;
  String get unsupportedPreviewTitle;
  String get lanCameraPermission;
  String get lanDeviceAlias;
  String get lanDeviceId;
  String get lanNotificationPermission;
  String get lanPermissions;
  String get lanRelayClear;
  String get lanRelayConnect;
  String get lanRelayConnecting;
  String get lanRelayDisconnect;
  String get lanRelayEnrollmentRequired;
  String get lanRelayEnrollmentToken;
  String get lanRelayEnrollmentTokenHint;
  String get lanRelayFailed;
  String get lanRelayServer;
  String get lanRouteDirect;
  String get lanRouteRelay;
  String get lanRouteUnknown;
  String get lanShare;
  String get lanShareChatInputHint;
  String get lanShareClearChatHistory;
  String get lanShareClipboard;
  String get lanShareCopyAll;
  String get lanShareDeleteMessage;
  String get lanShareDeviceList;
  String get lanShareDeviceOfflineHint;
  String get lanShareDragDropHint;
  String get lanShareExport;
  String get lanShareFileExpired;
  String get lanShareForgetConfirm;
  String get lanShareForgetConfirmMessage;
  String get lanShareForgetDevice;
  String get lanShareInitializationFailed;
  String get lanShareInvalidAddress;
  String get lanShareNoDevices;
  String get lanShareNoDevicesRefreshHint;
  String get lanShareNoHistory;
  String get lanShareOffline;
  String get lanShareOfflineReauthHint;
  String get lanShareOnline;
  String get lanShareOpenBrowser;
  String get lanSharePinMismatch;
  String get lanSharePinPairing;
  String get lanSharePinPrompt;
  String get lanShareRadarHint;
  String get lanShareRadarStoppedHint;
  String get lanShareReauthenticate;
  String get lanShareRecall;
  String get lanShareRecalled;
  String get lanShareSavedToDownloads;
  String get lanShareSavedToGallery;
  String get lanShareSaveFailed;
  String get lanShareScan;
  String get lanShareScanning;
  String get lanShareScanOrAdd;
  String get lanShareScanQrCode;
  String get lanShareSelectFile;
  String get lanShareSelectImage;
  String get lanShareSelectToCopy;
  String get lanShareSelectVideo;
  String get lanShareSendToNearby;
  String get lanShareSettings;
  String get lanShareTransferHistory;
  String get lanShareWebShare;
  String get lanShareWebShareHint;
}

/// App Scope 日志的最小适配接口。
abstract interface class LanShareLoggerPort implements LanRelayLoggerPort {
  /// 记录普通信息。
  void info(String message, {String? details});

  /// 记录可恢复的降级或安全拒绝。
  @override
  void warning(String message, {String? details});

  /// 记录错误及可选堆栈。
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  });
}

/// LAN 历史中敏感字段的加密适配接口。
abstract interface class LanShareDataProtectionPort {
  /// 加密一项待写入数据库的敏感文本。
  Future<String> encryptString(String value);

  /// 解密数据库中的敏感文本。
  Future<String> decryptString(String value);

  /// 判断字段是否已经由当前保护服务加密。
  bool isEncrypted(String value);
}

/// QUIC 身份材料；私钥只在 App/Network 边界内短暂流转。
final class LanShareNetworkIdentityMaterial {
  /// 创建一份身份材料快照。
  const LanShareNetworkIdentityMaterial({
    required this.privateSeed,
    required this.publicKey,
    required this.x25519PrivateSeed,
    required this.x25519PublicKey,
  });

  /// Ed25519 私钥种子。
  final Uint8List privateSeed;

  /// Ed25519 公钥。
  final Uint8List publicKey;
  final Uint8List x25519PrivateSeed;
  final Uint8List x25519PublicKey;
}

/// App Scope 网络身份加载端口。
abstract interface class LanShareNetworkIdentityPort {
  /// 加载或生成稳定的 QUIC 身份。
  Future<LanShareNetworkIdentityMaterial> loadOrCreate();
}

/// 访问 App 层拥有的共享 [NetworkFacade] 的端口。
///
/// Feature 仅借用共享的 [NetworkFacade]；底层 SessionClient、Realtime 协调器和
/// native runtime 由 App 组合根生命周期完全拥有与管理。
abstract interface class LanShareNetworkAccessPort {
  /// 借用 App 级单例 [NetworkFacade]。
  Future<NetworkFacade?> borrowFacade();
}

/// Narrow App-owned capability for peer-scoped screen-share actions.
///
/// The LAN Feature does not construct Realtime sessions or import the
/// screen-share Feature. The App Shell decides availability and owns the
/// navigation/session lifecycle behind this contract.
abstract interface class LanShareScreenSharePort {
  bool canShareWith(String peerId);

  bool canReceiveScreenShareFrom(String peerId);

  Future<void> startScreenShare(String peerId);
}
