// Network Transfer copy used by the LAN page. Defaults to Chinese.

import 'package:feature_lan_share/feature_lan_share.dart';

/// LAN strings for the network-transfer app.
final class NetworkLanStrings implements LanShareStrings {
  /// Creates the copy for [language].
  const NetworkLanStrings(this.language);

  /// Language selected by the app settings.
  final LanShareLanguage language;

  bool get _en => language == LanShareLanguage.en;

  @override
  bool get isEnglish => _en;

  @override
  String get accept => _en ? 'Accept' : '接收';
  @override
  String get cancel => _en ? 'Cancel' : '取消';
  @override
  String get close => _en ? 'Close' : '关闭';
  @override
  String get connected => _en ? 'Connected' : '已连接';
  @override
  String get copy => _en ? 'Copy' : '复制';
  @override
  String get disconnected => _en ? 'Disconnected' : '已断开';
  @override
  String get delete => _en ? 'Delete' : '删除';
  @override
  String get deleteConnectionConfirm => _en ? 'Delete' : '删除';
  @override
  String get externalPreviewContentBlocked =>
      _en ? 'External preview content is blocked' : '已阻止预览中的外部内容';
  @override
  String get filePreviewRenderFailed =>
      _en ? 'Could not display this preview' : '无法显示此文件预览';
  @override
  String get filePreviewRenderFailedHint => _en
      ? 'The file may be damaged or use an unsupported format. Try loading it again.'
      : '文件可能已损坏或使用了不支持的格式，请重新加载。';
  @override
  String get filePreviewResourceLimit =>
      _en ? 'This file is too complex to preview safely' : '文件复杂度过高，无法安全预览';
  @override
  String get filePreviewResourceLimitHint => _en
      ? 'Complexity exceeds in-app rendering budget. Download to view.'
      : '图片尺寸或动画复杂度超出应用内渲染预算。请下载后使用其他应用查看。';
  @override
  String get filePreviewTooLarge =>
      _en ? 'This file is too large to preview' : '文件过大，无法预览';

  @override
  String filePreviewTooLargeHint(int maxBytes) {
    final limit = _fileSizeLimitLabel(maxBytes);
    return _en
        ? 'File exceeds $limit preview limit. Return and download file.'
        : '安全预览上限为 $limit。请返回文件列表，下载后再查看。';
  }

  @override
  String get hostAddress => _en ? 'Host address' : '主机地址';
  @override
  String get htmlPreviewUnavailable =>
      _en ? 'HTML preview is unavailable here' : '当前平台无法渲染 HTML';
  @override
  String get htmlPreviewUnavailableHint => _en
      ? 'Rendered HTML preview is available on Android, iOS, and macOS. You can still inspect the source safely.'
      : 'HTML 渲染预览支持 Android、iOS 和 macOS；你仍可安全查看源码。';
  @override
  String get imagePreviewLabel => _en ? 'Image preview' : '图片预览';
  @override
  String get invalidPort => _en ? 'Invalid port' : '无效端口';
  @override
  String get loadingFilePreview => _en ? 'Loading file preview…' : '正在加载文件预览…';
  @override
  String get moreActions => _en ? 'More actions' : '更多操作';

  @override
  String networkIncomingTransferDescription(
    String senderId,
    String fileName,
    String fileSize,
  ) => _en
      ? '$senderId wants to send “$fileName” ($fileSize). Accept this file?'
      : '设备 $senderId 希望发送“$fileName”（$fileSize）。是否接收？';

  @override
  String get networkIncomingTransferTitle =>
      _en ? 'Incoming network transfer' : '收到网络传输请求';
  @override
  String get port => _en ? 'Port' : '端口';
  @override
  String get reject => _en ? 'Reject' : '拒绝';
  @override
  String get retry => _en ? 'Retry' : '重试';
  @override
  String get save => _en ? 'Save' : '保存';
  @override
  String get unknown => _en ? 'Unknown' : '未知';
  @override
  String get unsupportedPreview => _en
      ? 'Unsupported preview file type. Download to open.'
      : '暂不支持预览这种文件类型。可以下载后用其他应用打开。';
  @override
  String get unsupportedPreviewTitle => _en ? 'No preview available' : '暂不支持预览';
  @override
  String get lanCameraPermission =>
      _en ? 'Camera permission (scan QR code)' : '相机权限（扫描二维码）';
  @override
  String get lanDeviceAlias => _en ? 'Device alias / name' : '设备昵称 / 名称';
  @override
  String get lanDeviceId => _en ? 'Persistent device identifier' : '固定设备标识符';
  @override
  String get lanNotificationPermission =>
      _en ? 'Background notification permission' : '后台通知权限';
  @override
  String get lanPermissions => _en ? 'Permissions' : '权限';
  @override
  String get lanRelayClear => _en ? 'Clear enrollment' : '清除注册';
  @override
  String get lanRelayConnect => _en ? 'Connect' : '连接';
  @override
  String get lanRelayConnecting => _en ? 'Connecting…' : '连接中…';
  @override
  String get lanRelayDisconnect => _en ? 'Disconnect' : '断开连接';
  @override
  String get lanRelayEnrollmentRequired => _en ? 'Enrollment required' : '需要注册';
  @override
  String get lanRelayEnrollmentToken =>
      _en ? 'Temporary enrollment token' : '临时注册 Token';
  @override
  String get lanRelayEnrollmentTokenHint =>
      _en ? 'Required for first enrollment; never saved' : '首次注册需要；不会保存';
  @override
  String get lanRelayFailed => _en ? 'Connection failed' : '连接失败';
  @override
  String get lanRelayServer => _en ? 'Public relay server' : '公网中继服务器';
  @override
  String get lanRouteDirect => _en ? 'Direct' : '直连';
  @override
  String get lanRouteRelay => _en ? 'Relay' : '中继';
  @override
  String get lanRouteUnknown => _en ? 'Route pending' : '路线待定';
  @override
  String get lanShare => _en ? 'Network Transfer' : '网络传输';
  @override
  String get lanShareChatInputHint => _en ? 'Type a message...' : '输入消息...';
  @override
  String get lanShareClearChatHistory => _en ? 'Clear Chat History' : '清空聊天记录';
  @override
  String get lanShareClipboard => _en ? 'Clipboard' : '粘贴板';
  @override
  String get lanShareCopyAll => _en ? 'Copy All' : '全文复制';
  @override
  String get lanShareDeleteMessage => _en ? 'Delete Message' : '删除消息';
  @override
  String get lanShareDeviceList => _en ? 'Devices' : '设备列表';
  @override
  String get lanShareDeviceOfflineHint => _en
      ? 'Device is offline. You can view history, but cannot send new messages.'
      : '设备处于离线状态，可查看历史记录，但无法发送新消息。';
  @override
  String get lanShareDragDropHint =>
      _en ? 'Drop files or folders here to send' : '拖拽文件或文件夹到此处直接发送';
  @override
  String get lanShareExport => _en ? 'Save to Device' : '保存到本地';
  @override
  String get lanShareFileExpired =>
      _en ? 'Expired (Auto-deleted after 7 days)' : '已过期 (7天自动销毁)';
  @override
  String get lanShareForgetConfirm => _en ? 'Unpair Device' : '解除配对';
  @override
  String get lanShareForgetConfirmMessage => _en
      ? 'Unpairing prevents sending new messages until re-authenticated. History is kept.'
      : '解除配对后将无法发消息直到重新认证。历史记录会保留。';
  @override
  String get lanShareForgetDevice => _en ? 'Forget Device' : '忘记设备';
  @override
  String get lanShareInitializationFailed =>
      _en ? 'LAN Quick Share failed to initialize.' : '局域网快传初始化失败。';
  @override
  String get lanShareInvalidAddress => _en ? 'Invalid IP address' : '无效的 IP 地址';
  @override
  String get lanShareAddressAmbiguous => _en
      ? 'Multiple LAN addresses are available. Select one manually.'
      : '检测到多个局域网地址，请手动选择。';
  @override
  String get lanShareAddressUnavailable =>
      _en ? 'No usable LAN address is currently available.' : '当前没有可用的局域网地址。';
  @override
  String get lanShareAddressOverrideStale => _en
      ? 'The selected IP is no longer assigned to this device.'
      : '所选 IP 已不属于本机网络接口，请重新选择。';
  @override
  String get lanShareNoDevices => _en ? 'No nearby devices found' : '未找到附近设备';
  @override
  String get lanShareNoDevicesRefreshHint => _en
      ? 'No devices found. Tap refresh icon to scan again.'
      : '未找到附近设备，请点击右上角图标重新刷新';
  @override
  String get lanShareNoHistory => _en ? 'No transfer history yet' : '暂无传输历史';
  @override
  String get lanShareOffline => _en ? 'Offline' : '离线';
  @override
  String get lanShareOfflineReauthHint =>
      _en ? 'Offline. Re-authenticate when online.' : '对方已离线，恢复在线后可重新认证。';
  @override
  String get lanShareOnline => _en ? 'Online' : '在线';
  @override
  String get lanShareOpenBrowser => _en ? 'Open Link' : '打开链接';
  @override
  String get lanSharePinMismatch => _en ? 'Incorrect PIN code' : 'PIN 码不正确';
  @override
  String get lanSharePinPairing => _en ? 'PIN Verification' : 'PIN 码安全配对';
  @override
  String get lanSharePinPrompt => _en
      ? 'Enter the 6-digit PIN shown on target device:'
      : '请输入目标设备上显示的 6 位 PIN 码：';
  @override
  String get lanShareRadarHint =>
      _en ? 'Scanning nearby devices...' : '正在雷达扫描附近设备…';
  @override
  String get lanShareRadarStoppedHint => _en ? 'Scanning paused' : '扫描已暂停';
  @override
  String get lanShareReauthenticate => _en ? 'Re-authenticate' : '重新发起认证';
  @override
  String get lanShareRecall => _en ? 'Recall' : '撤回';
  @override
  String get lanShareRecalled => _en ? 'Recalled' : '已撤回';
  @override
  String get lanShareSavedToDownloads =>
      _en ? 'Saved to Downloads' : '已保存至下载目录';
  @override
  String get lanShareSavedToGallery =>
      _en ? 'Saved to Photo Gallery' : '已保存至系统相册';
  @override
  String get lanShareSaveFailed => _en ? 'Failed to save file' : '保存文件失败';
  @override
  String get lanShareScan => _en ? 'Scan for nearby devices' : '扫描附近设备';
  @override
  String get lanShareScanning =>
      _en ? 'Scanning for nearby devices' : '正在扫描附近设备';
  @override
  String get lanShareScanOrAdd => _en ? 'Scan/Add Device' : '扫码/手动添加';
  @override
  String get lanShareScanQrCode => _en ? 'Scan QR Code' : '扫码连接';
  @override
  String get lanShareSelectFile => _en ? 'Select File' : '选择文件';
  @override
  String get lanShareSelectImage => _en ? 'Select Image' : '选择图片';
  @override
  String get lanShareSelectToCopy => _en ? 'Select to Copy' : '选择复制';
  @override
  String get lanShareSelectVideo => _en ? 'Select Video' : '选择视频';
  @override
  String get lanShareSendToNearby => _en ? 'Send to nearby device' : '发送至附近设备';
  @override
  String get lanShareSettings => _en ? 'LAN Share Settings' : '局域网共享设置';
  @override
  String get lanShareTransferHistory => _en ? 'Transfer History' : '传输历史';
  @override
  String get lanShareWebShare => _en ? 'Web Share' : '网页快传';
  @override
  String get lanShareWebShareHint => _en
      ? 'Scan QR code from any browser to transfer files'
      : '无须安装 App，任意浏览器扫码即可收发文件';

  static String _fileSizeLimitLabel(int maxBytes) {
    const bytesPerMegabyte = 1024 * 1024;
    return maxBytes >= bytesPerMegabyte
        ? '${(maxBytes / bytesPerMegabyte).toStringAsFixed(maxBytes % bytesPerMegabyte == 0 ? 0 : 1)} MB'
        : '${(maxBytes / 1024).ceil()} KB';
  }
}
