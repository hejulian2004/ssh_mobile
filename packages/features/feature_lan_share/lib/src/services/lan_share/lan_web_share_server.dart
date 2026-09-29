// V2 WebShare HTTPS 请求路由与上传会话状态。
// WebShare 固定使用 HTTPS，不保留明文 HTTP 降级路径。

part of 'lan_discovery_service.dart';

LanMessage _toLanMessage(LanWebShareMessage message) {
  return LanMessage(
    id: message.id,
    senderId: message.senderId,
    senderAlias: message.senderAlias,
    receiverId: message.receiverId,
    payloadType: LanPayloadType.file,
    fileName: message.fileName,
    localPath: message.localPath,
    fileSize: message.fileSize,
    bytesTransferred: message.bytesTransferred,
    status: switch (message.status) {
      LanWebShareMessageStatus.pending => LanTransferStatus.pending,
      LanWebShareMessageStatus.completed => LanTransferStatus.completed,
      LanWebShareMessageStatus.failed => LanTransferStatus.failed,
    },
    createdAt: message.createdAt,
    isIncoming: true,
  );
}

extension _LanWebShareServerOperations on LanDiscoveryService {
  /// 启动 WebShare，并尝试候选端口直到绑定成功。
  Future<String?> _startWebShareServer({
    int port = 53319,
    required String hostIp,
    required LanSecurityService securityService,
    required LanStorageService storageService,
    required LanTransferService transferService,
  }) async {
    if (_isWebShareActive) return _webShareUrl;

    final candidates = [port, 53322, 53327, 53332, 53337]..remove(port);
    candidates.insert(0, port); // 确保首选端口位于第一位。

    HttpServer? bound;
    int boundPort = port;
    for (final candidate in candidates) {
      try {
        final securityContext = await securityService
            .getOrCreateSecurityContext(currentDeviceId);
        bound = await HttpServer.bindSecure(
          InternetAddress.anyIPv4,
          candidate,
          securityContext,
          requestClientCertificate: false,
        );
        if (_closing || _closed) {
          await bound.close(force: true);
          throw StateError('Web Share service is shutting down.');
        }
        boundPort = bound.port;
        break;
      } catch (e) {
        if (_closing || _closed) rethrow;
        debugPrint(
          '[LanDiscoveryService] WebShare HTTPS port $candidate unavailable: $e — trying next',
        );
      }
    }

    if (bound == null) {
      // 最后的端口策略：HTTPS 使用临时端口，不降级到明文 HTTP。
      final securityContext = await securityService.getOrCreateSecurityContext(
        currentDeviceId,
      );
      bound = await HttpServer.bindSecure(
        InternetAddress.anyIPv4,
        0,
        securityContext,
        requestClientCertificate: false,
      );
      if (_closing || _closed) {
        await bound.close(force: true);
        throw StateError('Web Share service is shutting down.');
      }
      boundPort = bound.port;
      debugPrint(
        '[LanDiscoveryService] WebShare using ephemeral port $boundPort',
      );
    }
    LanWebShareRequestHandler? requestHandler;
    try {
      final pubKeyBytes = await securityService.getStaticX25519PublicKeyBytes();
      final pubKeyB64 = base64.encode(pubKeyBytes);
      final certFingerprint = await securityService
          .getLocalCertificateFingerprint(currentDeviceId);
      final webShareToken = _generateWebShareToken();
      if (_closing || _closed) {
        await bound.close(force: true);
        throw StateError('Web Share service is shutting down.');
      }
      const scheme = 'https';

      _webShareToken = webShareToken;
      _webShareServer = bound;
      _isWebShareActive = true;
      requestHandler = LanWebShareRequestHandler(
        currentDeviceId: currentDeviceId,
        webShareToken: webShareToken,
        decryptPayload: securityService.decryptE2E,
        hasSufficientSpace: storageService.hasSufficientSpace,
        createTargetFile: storageService.getSandboxTargetFile,
        deleteFile: (path) async {
          await storageService.deleteSandboxFile(path);
        },
        onIncomingMessage: (message) {
          transferService.handleIncomingMessageFromWeb(_toLanMessage(message));
        },
        onMessageProgress: (message) {
          transferService.handleMessageProgressFromWeb(_toLanMessage(message));
        },
        isActive: () =>
            !_closing &&
            !_closed &&
            _isWebShareActive &&
            identical(_webShareRequestHandler, requestHandler) &&
            _webShareToken == webShareToken,
        buildHtml: () => _buildWebShareHtml(
          appPubKeyB64: pubKeyB64,
          webShareToken: webShareToken,
        ),
        logger: debugPrint,
      );
      _webShareRequestHandler = requestHandler;
      final handlerForServer = requestHandler;
      _webShareUrl = Uri(
        scheme: scheme,
        host: hostIp,
        port: boundPort,
        queryParameters: {
          'deviceId': currentDeviceId,
          'lanPort': transferService.activePort.toString(),
          if (transferService.activeNativeTransferPort case final port?)
            'nativePort': port.toString(),
          'access': webShareToken,
          'certFingerprint': certFingerprint,
        },
      ).toString();

      _webShareServer!.listen((HttpRequest request) {
        late final Future<void> operation;
        operation = handlerForServer
            .handleRequest(request)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {})
            .whenComplete(() {
              _webShareRequestOperations.remove(operation);
            });
        _webShareRequestOperations.add(operation);
      });

      debugPrint(
        '[LanDiscoveryService] Web Share server running on $scheme://$hostIp:$boundPort',
      );
      return _webShareUrl;
    } catch (_) {
      await bound.close(force: true);
      await requestHandler?.close();
      _webShareRequestHandler = null;
      _webShareServer = null;
      _isWebShareActive = false;
      _webShareUrl = null;
      _webShareToken = null;
      rethrow;
    }
  }

  /// 停止 WebShare 服务并清除所有待处理上传。
  Future<void> _stopWebShareServer() async {
    final server = _webShareServer;
    final requestHandler = _webShareRequestHandler;
    _webShareRequestHandler = null;
    _webShareServer = null;
    _isWebShareActive = false;
    _webShareUrl = null;
    _webShareToken = null;
    if (server != null) await server.close(force: true);
    final requestOperations = _webShareRequestOperations.toList();
    if (requestOperations.isNotEmpty) {
      await Future.wait(requestOperations);
    }
    _webShareRequestOperations.clear();
    await requestHandler?.close();
  }

  /// 生成密码学安全的随机 WebShare bearer token。
  String _generateWebShareToken() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 将用户可控文本嵌入生成 HTML 前进行转义。
  static String _escapeHtml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// 使用 V2 端点值构建静态 WebShare HTML 客户端。
  String _buildWebShareHtml({
    required String appPubKeyB64,
    required String webShareToken,
  }) {
    final escapedAlias = _escapeHtml(currentDeviceAlias);
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SSH Mobile — 局域网快传 Web 版</title>
  <style>
    :root {
      --bg-gradient: linear-gradient(135deg, #0f172a 0%, #1e1b4b 100%);
      --card-bg: rgba(30, 41, 59, 0.7);
      --border-color: rgba(255, 255, 255, 0.08);
      --glow-color: #38bdf8;
      --text-main: #f8fafc;
      --text-muted: #94a3b8;
    }
    body {
      font-family: 'Outfit', system-ui, -apple-system, sans-serif;
      background: var(--bg-gradient);
      color: var(--text-main);
      margin: 0;
      padding: 20px;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 95vh;
      overflow-x: hidden;
    }
    .card {
      background: var(--card-bg);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border-radius: 24px;
      padding: 32px;
      max-width: 500px;
      width: 100%;
      box-sizing: border-box;
      border: 1px solid var(--border-color);
      box-shadow: 0 20px 40px rgba(0, 0, 0, 0.4), inset 0 1px 1px rgba(255, 255, 255, 0.1);
      text-align: center;
      transition: transform 0.3s ease, box-shadow 0.3s ease;
    }
    .card:hover {
      transform: translateY(-2px);
      box-shadow: 0 25px 50px rgba(0, 0, 0, 0.5), 0 0 15px rgba(56, 189, 248, 0.1);
    }
    h1 {
      font-size: 24px;
      font-weight: 700;
      background: linear-gradient(to right, #38bdf8, #818cf8);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      margin-top: 0;
      margin-bottom: 8px;
    }
    .desc {
      font-size: 14px;
      color: var(--text-muted);
      margin-bottom: 24px;
      line-height: 1.5;
    }
    .desc strong {
      color: var(--glow-color);
    }
    .drop-zone {
      border: 2px dashed rgba(56, 189, 248, 0.3);
      border-radius: 18px;
      padding: 40px 20px;
      margin: 20px 0;
      background: rgba(56, 189, 248, 0.02);
      cursor: pointer;
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
      position: relative;
    }
    .drop-zone.dragover {
      border-color: var(--glow-color);
      background: rgba(56, 189, 248, 0.08);
      box-shadow: 0 0 20px rgba(56, 189, 248, 0.15);
      transform: scale(1.02);
    }
    .drop-zone svg {
      width: 48px;
      height: 48px;
      fill: none;
      stroke: var(--glow-color);
      stroke-width: 1.5;
      margin-bottom: 12px;
      transition: transform 0.3s ease;
    }
    .drop-zone:hover svg {
      transform: translateY(-4px);
    }
    .drop-zone p {
      font-size: 15px;
      margin: 0;
      color: var(--text-main);
    }
    .drop-zone span {
      font-size: 12px;
      color: var(--text-muted);
      display: block;
      margin-top: 6px;
    }
    .encrypt-panel {
      background: rgba(15, 23, 42, 0.4);
      border-radius: 16px;
      padding: 16px;
      margin: 20px 0;
      border: 1px solid rgba(255, 255, 255, 0.03);
      text-align: left;
    }
    .encrypt-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .encrypt-label {
      font-size: 14px;
      font-weight: 600;
      color: var(--text-main);
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .encrypt-label svg {
      width: 16px;
      height: 16px;
      fill: none;
      stroke: var(--glow-color);
      stroke-width: 2;
    }
    /* Switch Style */
    .switch {
      position: relative;
      display: inline-block;
      width: 44px;
      height: 24px;
    }
    .switch input {
      opacity: 0;
      width: 0;
      height: 0;
    }
    .slider {
      position: absolute;
      cursor: pointer;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background-color: #475569;
      transition: .3s;
      border-radius: 24px;
    }
    .slider:before {
      position: absolute;
      content: "";
      height: 18px;
      width: 18px;
      left: 3px;
      bottom: 3px;
      background-color: white;
      transition: .3s;
      border-radius: 50%;
    }
    input:checked + .slider {
      background-color: #0ea5e9;
      box-shadow: 0 0 8px rgba(14, 165, 233, 0.5);
    }
    input:checked + .slider:before {
      transform: translateX(20px);
    }
    input:disabled + .slider {
      opacity: 0.4;
      cursor: not-allowed;
    }
    .encrypt-tip {
      font-size: 11px;
      color: var(--text-muted);
      margin-top: 10px;
      line-height: 1.4;
    }
    .encrypt-tip.warning {
      color: #fb923c;
    }
    .btn {
      background: linear-gradient(135deg, #0ea5e9 0%, #2563eb 100%);
      color: white;
      border: none;
      padding: 14px 28px;
      border-radius: 12px;
      font-weight: 600;
      font-size: 15px;
      cursor: pointer;
      width: 100%;
      box-shadow: 0 4px 12px rgba(14, 165, 233, 0.25);
      transition: all 0.2s ease;
    }
    .btn:hover {
      transform: translateY(-1px);
      box-shadow: 0 6px 20px rgba(14, 165, 233, 0.35);
    }
    .btn:active {
      transform: translateY(1px);
    }
    .btn:disabled {
      background: #475569;
      box-shadow: none;
      cursor: not-allowed;
    }
    /* Progress Card */
    .progress-card {
      background: rgba(15, 23, 42, 0.5);
      border-radius: 16px;
      padding: 16px;
      margin-top: 24px;
      text-align: left;
      border: 1px solid rgba(255, 255, 255, 0.05);
      display: none;
    }
    .file-info {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 8px;
    }
    .file-name {
      font-size: 14px;
      font-weight: 600;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      max-width: 70%;
    }
    .file-size {
      font-size: 12px;
      color: var(--text-muted);
    }
    .bar-container {
      width: 100%;
      height: 6px;
      background: #334155;
      border-radius: 3px;
      overflow: hidden;
      margin-bottom: 8px;
    }
    .bar {
      width: 0%;
      height: 100%;
      background: linear-gradient(90deg, #38bdf8, #818cf8);
      transition: width 0.1s ease;
    }
    .status-row {
      display: flex;
      justify-content: space-between;
      font-size: 12px;
    }
    .status-text {
      color: var(--glow-color);
      font-weight: 500;
    }
    .status-percent {
      color: var(--text-muted);
    }
    .success-icon {
      color: #4ade80;
      fill: none;
      stroke: currentColor;
      stroke-width: 2;
      width: 24px;
      height: 24px;
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>🚀 SSH Mobile 局域网快传</h1>
    <div class="desc">
      正在与设备 <strong>$escapedAlias</strong> 进行文件传输<br>
      <span style="font-size: 11px; opacity: 0.7;">当前连接: 🔐 安全加密 (HTTPS)</span>
    </div>

    <div class="drop-zone" id="dropZone" onclick="document.getElementById('fileInput').click()">
      <svg viewBox="0 0 24 24">
        <path d="M12 16V8M12 8L9 11M12 8L15 11M20 16.5C20 18.9853 17.9853 21 15.5 21H8.5C6.01472 21 4 18.9853 4 16.5C4 14.3649 5.48514 12.5768 7.48161 12.1158C7.17066 11.2829 7 10.3887 7 9.45833C7 6.44378 9.44378 4 12.4583 4C14.9392 4 17.0371 5.65656 17.6974 7.9177C19.0069 8.35824 20 9.5898 20 11.0417C20 11.4704 19.8989 11.8755 19.7188 12.2355C19.8974 12.3168 20 12.3927 20 12.5V16.5Z" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
      <p>点击或拖拽文件到此处发送</p>
      <span>支持任意大小与类型的文件</span>
      <input type="file" id="fileInput" style="display:none">
    </div>

    <!-- E2E 加密配置面板 -->
    <div class="encrypt-panel">
      <div class="encrypt-row">
        <div class="encrypt-label">
          <svg viewBox="0 0 24 24">
            <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>
            <path d="M7 11V7a5 5 0 0 1 10 0v4"/>
          </svg>
          启用端到端加密 (E2E)
        </div>
        <label class="switch">
          <input type="checkbox" id="encryptSwitch" checked>
          <span class="slider"></span>
        </label>
      </div>
      <div class="encrypt-tip" id="encryptTip">
        正在评估浏览器安全性...
      </div>
    </div>

    <button class="btn" id="sendBtn" onclick="document.getElementById('fileInput').click()">选择本地文件</button>

    <!-- 进度条面板 -->
    <div class="progress-card" id="progressCard">
      <div class="file-info">
        <span class="file-name" id="pFileName">filename.bin</span>
        <span class="file-size" id="pFileSize">0 KB</span>
      </div>
      <div class="bar-container">
        <div class="bar" id="pBar"></div>
      </div>
      <div class="status-row">
        <span class="status-text" id="pStatus">准备发送...</span>
        <span class="status-percent" id="pPercent">0%</span>
      </div>
    </div>
  </div>

  <script>
    const APP_PUBLIC_KEY_B64 = ${jsonEncode(appPubKeyB64)};
    const APP_RECEIVER_ID = ${jsonEncode(currentDeviceId)};
    const WEB_SHARE_TOKEN = ${jsonEncode(webShareToken)};
    const MAX_WEB_UPLOAD_BYTES = ${LanTransferProtocolGuard.maxAdvertisedFileBytes};
    const MAX_WEB_ENCRYPTED_UPLOAD_BYTES = ${LanTransferProtocolGuard.maxEncryptedUploadBytes};

    // 检查加密兼容性
    const isSecure = window.isSecureContext;
    const hasWebCrypto = !!(window.crypto && window.crypto.subtle);
    const canEncrypt = isSecure && hasWebCrypto;

    const encryptSwitch = document.getElementById('encryptSwitch');
    const encryptTip = document.getElementById('encryptTip');
    const dropZone = document.getElementById('dropZone');
    const fileInput = document.getElementById('fileInput');
    const sendBtn = document.getElementById('sendBtn');

    const progressCard = document.getElementById('progressCard');
    const pFileName = document.getElementById('pFileName');
    const pFileSize = document.getElementById('pFileSize');
    const pBar = document.getElementById('pBar');
    const pStatus = document.getElementById('pStatus');
    const pPercent = document.getElementById('pPercent');

    if (canEncrypt) {
      encryptSwitch.checked = true;
      encryptTip.className = "encrypt-tip";
      encryptTip.innerHTML = "✨ 您的浏览器支持 E2E 加密。传输前将在前端使用 X25519 + AES-256-GCM 高强度加密。";
    } else {
      // 不支持安全上下文或 WebCrypto 时禁止发送，避免静默降级为明文。
      encryptSwitch.checked = true;
      encryptSwitch.disabled = true;
      sendBtn.disabled = true;
      dropZone.style.pointerEvents = 'none';
      encryptTip.className = "encrypt-tip warning";
      encryptTip.innerHTML = "⚠️ 当前浏览器不支持 HTTPS 安全上下文或 X25519 WebCrypto，无法启动 WebShare 传输。";
    }

    // 拖拽文件动效
    ['dragenter', 'dragover'].forEach(eventName => {
      dropZone.addEventListener(eventName, (e) => {
        e.preventDefault();
        dropZone.classList.add('dragover');
      }, false);
    });

    ['dragleave', 'drop'].forEach(eventName => {
      dropZone.addEventListener(eventName, (e) => {
        e.preventDefault();
        dropZone.classList.remove('dragover');
      }, false);
    });

    dropZone.addEventListener('drop', (e) => {
      const dt = e.dataTransfer;
      const files = dt.files;
      if (files.length > 0) {
        handleUpload(files[0]);
      }
    }, false);

    fileInput.addEventListener('change', (e) => {
      if (fileInput.files.length > 0) {
        handleUpload(fileInput.files[0]);
      }
    });

    // UUID 生成器。
    function generateUUID() {
      return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
      });
    }

    // 格式化文件大小
    function formatBytes(bytes) {
      if (bytes === 0) return '0 Bytes';
      const k = 1024;
      const sizes = ['Bytes', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    }

    // 核心加密方法：使用与 Dart LanSecurityService 完全兼容的 X25519 + AES-GCM-256。
    async function encryptBlob(arrayBuffer, appPubKeyB64) {
      // 1. 解码 App 公钥。
      const appPubKeyBytes = Uint8Array.from(atob(appPubKeyB64), c => c.charCodeAt(0));
      const appKey = await window.crypto.subtle.importKey(
        "raw",
        appPubKeyBytes,
        { name: "X25519" },
        true,
        []
      );

      // 2. 生成网页端的临时私钥和公钥
      const webKeyPair = await window.crypto.subtle.generateKey(
        { name: "X25519" },
        true,
        ["deriveBits"]
      );

      // 3. 导出临时公钥的 32 字节原始数据。
      const webPubKeyBytes = await window.crypto.subtle.exportKey(
        "raw",
        webKeyPair.publicKey
      );

      // 4. 使用 ECDH 计算共享秘密。
      const sharedSecret = await window.crypto.subtle.deriveBits(
        { name: "X25519", public: appKey },
        webKeyPair.privateKey,
        256 // 256 位（32 字节）。
      );

      // 5. 将共享秘密导入为 AES-GCM 密钥。
      const aesKey = await window.crypto.subtle.importKey(
        "raw",
        sharedSecret,
        { name: "AES-GCM" },
        false,
        ["encrypt"]
      );

      // 6. 生成 12 字节随机 iv（nonce）。
      const iv = window.crypto.getRandomValues(new Uint8Array(12));

      // 7. 使用 AES-GCM-256 加密数据（密文末尾自动附加 16 字节认证标签）。
      const ciphertext = await window.crypto.subtle.encrypt(
        { name: "AES-GCM", iv: iv },
        aesKey,
        arrayBuffer
      );

      // 8. 组合封包：[32B webPubKey] + [12B iv] + [ciphertext+tag]。
      const finalBlob = new Uint8Array(32 + 12 + ciphertext.byteLength);
      finalBlob.set(new Uint8Array(webPubKeyBytes), 0);
      finalBlob.set(iv, 32);
      finalBlob.set(new Uint8Array(ciphertext), 44);

      return finalBlob;
    }

    // 上传文件流程
    async function handleUpload(file) {
      if (!canEncrypt) {
        pStatus.innerText = "❌ 当前浏览器不满足 WebShare 安全要求。";
        pStatus.style.color = '#f87171';
        return;
      }

      // 禁用控件
      dropZone.style.pointerEvents = 'none';
      sendBtn.disabled = true;
      encryptSwitch.disabled = true;

      // 展示进度
      progressCard.style.display = 'block';
      pFileName.innerText = file.name;
      pFileSize.innerText = formatBytes(file.size);
      pBar.style.width = '0%';
      pPercent.innerText = '0%';

      const useE2E = encryptSwitch.checked;
      const messageId = generateUUID();

      try {
        if (file.size > MAX_WEB_UPLOAD_BYTES) {
          throw new Error("文件超过 Web 快传允许的最大大小。");
        }
        if (useE2E && file.size > MAX_WEB_ENCRYPTED_UPLOAD_BYTES) {
          throw new Error("端到端加密文件最大支持 64 MiB，请关闭 E2E 后重试。");
        }

        // 步骤 1：发送 Meta 元数据
        pStatus.innerText = "准备协商连接...";
        const meta = {
          id: messageId,
          senderId: 'web-browser',
          senderAlias: '网页端浏览器',
          receiverId: APP_RECEIVER_ID,
          payloadType: 'file',
          fileName: file.name,
          fileSize: file.size,
          createdAt: new Date().toISOString(),
          status: 'pending',
          bytesTransferred: 0,
          isIncoming: true
        };

        const metaJson = JSON.stringify(meta);
        const encoder = new TextEncoder();
        const metaBytes = encoder.encode(metaJson);

        let metaBody, metaHeaders = {
          'x-web-share-token': WEB_SHARE_TOKEN
        };
        if (useE2E) {
          pStatus.innerText = "端到端加密协商中...";
          const encryptedMeta = await encryptBlob(metaBytes.buffer, APP_PUBLIC_KEY_B64);
          metaBody = encryptedMeta;
          metaHeaders['x-e2e-pubkey'] = '1';
        } else {
          metaBody = metaJson;
          metaHeaders['Content-Type'] = 'application/json';
        }

        // 提交 Meta
        const metaResponse = await fetch('/api/web/meta', {
          method: 'POST',
          body: metaBody,
          headers: metaHeaders
        });

        if (!metaResponse.ok) {
          if (metaResponse.status === 507) {
            throw new Error("App端存储空间不足！");
          }
          throw new Error("连接握手失败: " + metaResponse.statusText);
        }

        // 步骤 2：上传文件数据
        pStatus.innerText = "正在传输数据...";
        let uploadBody, uploadHeaders = {
          'x-message-id': messageId,
          'x-file-name': encodeURIComponent(file.name),
          'x-web-share-token': WEB_SHARE_TOKEN
        };

        if (useE2E) {
          pStatus.innerText = "正在加密文件数据...";
          const fileBuffer = await file.arrayBuffer();
          const encryptedFile = await encryptBlob(fileBuffer, APP_PUBLIC_KEY_B64);
          uploadBody = new Blob([encryptedFile]);
          uploadHeaders['x-e2e-pubkey'] = '1';
        } else {
          // 普通上传保持浏览器 File/Blob 流式实现，
          // 不要将整个文件复制到 JavaScript 内存。
          uploadBody = file;
        }

        // 使用 XMLHttpRequest 来捕获流上传的真实进度
        await new Promise((resolve, reject) => {
          const xhr = new XMLHttpRequest();
          xhr.open('POST', '/api/web/upload');
          for (const key in uploadHeaders) {
            xhr.setRequestHeader(key, uploadHeaders[key]);
          }

          xhr.upload.onprogress = (e) => {
            if (e.lengthComputable) {
              const pct = Math.floor((e.loaded / e.total) * 100);
              pBar.style.width = pct + '%';
              pPercent.innerText = pct + '%';
              pStatus.innerText = useE2E ? "端到端加密传输中..." : "正在传输数据...";
            }
          };

          xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
              resolve();
            } else {
              reject(new Error("上传数据失败: " + xhr.statusText));
            }
          };

          xhr.onerror = () => reject(new Error("网络传输发生异常！"));
          xhr.send(uploadBody);
        });

        pStatus.innerText = "🎉 传输成功！";
        pStatus.style.color = '#4ade80';
        pPercent.innerHTML = '<svg class="success-icon" viewBox="0 0 24 24"><path d="M5 13l4 4L19 7" stroke-linecap="round" stroke-linejoin="round"/></svg>';

      } catch (err) {
        console.error(err);
        pStatus.innerText = "❌ 传输失败: " + err.message;
        pStatus.style.color = '#f87171';
      } finally {
        // 恢复控件状态
        dropZone.style.pointerEvents = canEncrypt ? 'auto' : 'none';
        sendBtn.disabled = !canEncrypt;
        if (canEncrypt) {
          encryptSwitch.disabled = false;
        }
      }
    }
  </script>
</body>
</html>
''';
  }
}
