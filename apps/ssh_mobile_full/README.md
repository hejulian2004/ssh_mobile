最新更新时间：2026-10-29

# ssh_mobile_full

## 职责

Full App 是 SSH Mobile 的完整 App Shell 和组合根，负责启动协调、`AppRuntime`
生命周期、路由聚合、App Port 适配器以及兼容清单中明确保留的 App Scope 后端。

Network V2 的组合根约束：`AppRuntimeFactory` 创建 App-owned `AppNetworkResources`，
首次网络操作才加载/创建 `NetworkIdentityBundle` 并 exactly-once 配置原生
`NetworkRuntime` 和共享 `NetworkFacade`；事件订阅和诊断不触发初始化。LAN、SSH、
SFTP、Realtime 和 Relay 只借用这些 App Scope 资源；Feature
或 Route Scope 不得创建第二个 runtime/facade，也不得在 deactivate/reactivate 时
停止、销毁或重新配置它们。局域网运行时经 `LanShareNetworkRuntimePort` 注入：
`ensureRuntime` 映射为 `NetworkCapability.runtime`，`ensureWebSocketRelay`
映射为 `NetworkCapability.webSocketRelay`。`feature_lan_share` 不依赖
`network_transport`。进程仍在运行时，后台的局域网文字、文件申请和传入传输终态可以显示脱敏系统通知；点击只恢复应用或打开已有聊天。

Android 的 SFTP 与局域网文件出入口可以通过 `ssh_mobile/document_access` 使用系统文档选择器。授权只覆盖用户选中的一个 content URI，以及这次请求的读或写模式，并可以持久化后释放。取消选择不会改变授权，也不会开始传输。非 Android 仍使用路径选择器。这里不把远程目录挂进系统文件管理器。

`AndroidSystemDocuments` 将原生能力适配为两个 Feature 的公开文档 Port，
`android_document_cache.dart` 负责单次缓存、分块和迟到结果清理。读关闭后不能
重新打开；写入只有原生复制完成才算成功，重复关闭保留同一次提交结果。单文件
授权可并存，释放只影响本次借用；Activity 销毁会结束未完成请求并清理本次原生资源。
取消或失败的外部保存目标可能仍由文档提供方保留空文件或部分内容，界面不报告成功。

App 层文档桥接回归入口为 `test/app/android_system_documents_test.dart` 和
`test/app/android_document_cache_test.dart`；真实系统选择、云端文档提供方、授权撤销
和 Activity 销毁场景按 `docs/security_manual_regression.md` 的 SAF 清单验收。

Android 原生授权、复制、缓存归属与取消策略位于 `DocumentAccess.kt`，独立 JVM
回归入口为 Android 工程的 `:app:testDebugUnitTest --tests '*Document*Test'`。
`:app:verifyDocumentAccessCoverage` 生成 JaCoCo 报告并强制该核心源文件至少 90%
行覆盖率。`DocumentAccessSession.kt` 是 Activity、ContentResolver、
ParcelFileDescriptor 和 MethodChannel 的平台绑定，按平台胶水例外不纳入纯 JVM
行覆盖门禁；其真实 Android 回调、文档流、取消与销毁由测试 APK 中的
`DocumentAccessInstrumentation` 验证，不能用 JVM 行覆盖代替设备结果。

模拟器验收先构建并安装 `:app:assembleDebug` 和 `:app:assembleDebugAndroidTest`
的两个 APK，再针对选定模拟器运行 `adb -s <emulator> shell am instrument -w
com.example.ssh_mobile.test/com.example.ssh_mobile.DocumentAccessInstrumentation`。
测试只使用测试 APK 自有的公开固定文档，检查选择/取消回调、PFD 分块读写和
截断、大小限制、错误映射、按操作取消及资源清理。它不自动操作真实系统选择器，
不代替云端提供方、持久化权限或进程重建的系统验收；提供方不能响应系统取消或
文件描述符关闭时，也不能承诺立即终止其阻塞 I/O。

Android 凭据保护通过 `ssh_mobile/credential_protection` 提供 `capability`、`seal`、
`open`、`removeKey` 和按 `operationId` 取消。平台实现支持 Android 11/API 30+
且不提高 App 的最低系统版本；旧版本返回不支持，不降级为普通认证弹框或明文。
能力查询只检查平台/Keystore 能力，录入状态和暂时锁定在每次敏感操作时重新检查。
系统认证弹框按 Android 系统语言显示。

每个连接的每个 revision 独占一个 Android Keystore AES-256/GCM 密钥，alias 使用
域、连接 ID 和 revision 的不可歧义编码摘要；同一编码也作为 AAD。密钥不可导出、
每次操作只接受强生物认证，生物录入变化使其失效。真正的 Cipher 通过
`BiometricPrompt.CryptoObject` 认证，成功回调必须返回同一实例才执行 AAD 绑定和
加解密。缺失/失效密钥绝不在解锁时重建，取消、后台和 Activity 结束不返回明文。
单次明文预算为 512 KiB，GCM IV 为 12 字节，认证标签为 16 字节；原生层不写入
凭据、URI、密钥别名或平台异常正文日志，临时明文字节在使用后清零。

`CredentialProtection.kt` 的绑定、预算与一次终态策略通过独立 JVM 测试验证，
`:app:verifyCredentialProtectionCoverage` 强制文件行覆盖率至少 90%。
`CredentialProtectionSession.kt` 的 Activity、AndroidKeyStore、BiometricPrompt
和 MethodChannel 绑定属于平台胶水例外，不以纯 JVM 行覆盖替代真实设备验证。
测试 APK 的 `CredentialProtectionInstrumentation` 验证能力、缺失密钥不重建与
后台拒绝；`CredentialCryptoInstrumentation` 使用独立公开测试标识验证真实
Keystore 不可导出/逐次认证、CryptoObject 封装与解锁、篡改拒绝、取消和后台终态。

已录入专用测试指纹的模拟器可运行
`adb -s <emulator> shell am instrument -w -r com.example.ssh_mobile.test/com.example.ssh_mobile.CredentialCryptoInstrumentation`。
分别收到 `await_seal_authentication`、`await_open_authentication` 和
`await_tamper_authentication` 阶段后，使用模拟器的固定测试手指事件认证；测试
不显示或导出秘密内容。临时锁屏/指纹、通知权限隔离标记和测试 alias 必须随测试
清理。低 API、真实硬件、录入变更、永久锁定和进程重建仍需对应设备专项验收。

受保护凭据仍由 `connection_core.SecureCredentialRepository` 唯一管理。
App 工厂注入 `AndroidCredentialCrypto`，能力查询最多等待两秒且不生成凭据密钥。
Connection 编辑路由直接借用其可选保护接口，避免普通转发适配器隐藏该能力。
显式 SSH/SFTP 连接一次解锁完整凭据，随后重新核验目标与 revision；Socket 就绪、
Host Key 确认和密码认证回调也保留核验。普通后台/工具读取不自动弹出认证或
使用旧明文键。已建立会话继续由原 SSH Owner 管理，不提供全局“已解锁”缓存。

## 不负责什么

新的 Feature 业务实现、跨 Feature 的 `/src/` 调用和第二套全局 SSH/Network Owner
不应继续放入本 App；新能力应进入对应的 Core、Infrastructure 或 Feature Package。

## Public API

App Shell 的稳定组合入口是 `lib/main.dart`、`lib/app/app_bootstrap.dart`、
`lib/app/app_runtime.dart` 和 `lib/app/navigation/`。外部调用方不得把旧
`lib/screens/`、`lib/models/` 或兼容 Service 当作新模块 API。

`AppBootstrap` 立即挂载 Logo 启动壳，并在后续 microtask 开始 Runtime 装配，
不等待首帧绘制或栅格化；异步 I/O 与首帧重叠，并保留同一个加载动画。
`SshMobileApp.onStartupReady` 在初始首页或电源引导完成首帧布局后通知启动壳移除
遮罩；准备期间 App 隐藏且暂停 Ticker，异步数据读取继续执行。该回调不转移 Runtime
资源所有权。

LAN 接收在首次打开快传页面时激活，随后由 Module 保持接收；启动时全局配对宿主
仅订阅事件。遥测只准备独立的 Relay enrollment 门禁，不初始化接收器。网络密钥
推导和 TLS 证书首次生成在工作 isolate 执行，安全存储读写仍使用平台 isolate。
首次网络激活完成后，组合根为 Realtime 接收适配器接入同一原生运行时的借用
gateway，确保从未主动共享过屏幕的设备也能收到邀请；冷启动订阅仍不初始化网络。
Realtime 命令以原生 `CommandResultV2` 的终态完成关联，并核对目标设备；入队成功
不能替代命令完成或 native-authoritative 会话状态。

Windows 屏幕选择使用原生目录绑定的源标识；接受邀请后直接交给原生采集 Owner
核验目标是否仍有效，不重新枚举并替换已选择的目录。媒体失败日志只记录阶段和
类型化错误码，不记录屏幕内容、源标签或会话标识。
路由在媒体端点完成绑定后低频读取发送、接收、解码和渲染计数，并报告原生采集/
解码线程的后续故障；统计暂时不可用时继续观察，不将其当作媒体失败。监控在
停止、路由释放或代际失效后取消，迟到结果不能影响新共享，也不记录帧内容。
接收视图使用这些尺寸元数据保持视频原始比例，竖屏不再被拉伸为窗口的宽高比。
接收视图支持按直角旋转画面和系统全屏；切换保留同一视频组件与原生媒体端点，
不重新申请录屏权限。Windows 全屏覆盖当前显示器并保留进入前的窗口位置与样式；
Android 隐藏系统栏，退出时恢复先前的状态栏、导航栏可见性和交互方式。
接受共享后，接收端在画面端点就绪时默认进入系统全屏；发送端不自动切换。
每次打开接收页面只自动进入一次，用户手动退出后不会因画面刷新再次强制全屏。
返回键或 Escape 先退出全屏，全屏中仍提供停止共享入口。原生切换期间禁用重复
点击；路由关闭或共享结束会恢复窗口，迟到的进入结果也按原租约补偿。
恢复失败保留原始快照并提供重试提示；没有原生能力时报告失败并允许正常返回。
Android 接收端只有在共享页正处于最前、画面尺寸有效且共享未结束时，用户离开
应用才会进入系统画中画。其他页面盖住共享页时会取消进入资格，但不停止共享、
媒体端点或涂鸦。回到该页后按同一画面重新发布资格。小窗只保留同一个 Flutter
纹理，隐藏控制条、涂鸦和全屏按钮，不新建 WebRTC 会话或解码器。共享停止后展开
原页面。Activity 销毁或引擎重建只清除资格，不会再次启动应用。后打开的共享页
拥有画中画通道，先打开的页面不能清掉它。后打开的页面关闭后，重新展示的页面
取回通道并发布自己的画面。取回前还没返回的发布不算已经生效，同时读取
Activity 是否仍在画中画，不再沿用页面记住的旧小窗状态。关闭小窗不会结束 Activity。发送端和
Windows 不进入画中画。

窗口租约控制与 Android 快照仲裁分别有独立 Dart/JVM 回归；Win32 生命周期测试
使用隐藏的固定测试窗口，检查全显示器范围、原样恢复与迟到释放保护。
`test/windows/CMakeLists.txt` 可用 Windows CMake 构建后运行对应测试程序；Android
App 的宿主入口是 `:app:testDebugUnitTest`。Android 系统栏适配与 Win32 API 包装
属于平台调用，不以 JVM/Dart 行覆盖率替代真实系统验收；跨显示器/DPI、最大化
恢复和 Android 设备实际交互仍需平台验收。

App Scope 保留交叉发起的按设备仲裁；邀请宿主同一时间只展示一个待处理请求，
其余可信请求收到正式 REJECT，不替换正在等待用户决定的邀请。已认领/启动媒体的
操作全局独占，关闭页面后占用仍保持；媒体和会话清理结束后才释放精确操作的占用。
清理未确认时保留原 Owner 并允许重试停止。初始化失败同样清理占用。邀请宿主销毁后，
迟到的认领结果只补偿停止对应会话，不再导航；宿主和发起入口释放时也会取消身份等待。

传输终止或会话身份变化会结束尚未就绪的已接受共享；媒体清理使用原先准备的代际
身份，即使当前令牌已被清除，也能释放旧端点。明确停止或 App 退出会先释放已取得的
端点，主动取消原生接收就绪等待，再等待迟到绑定收尾。准备阶段同样区分当前请求
与其他操作的取消；显式排队的新请求仍遵循既有替换和停止规则。
共享由 `ScreenShareEntryCoordinator` 持有的 `AppScreenShareSessions` 管理；页面只借用
操作和画面。返回、关闭页面或切到后台不发送 CANCEL，也不释放端点；后台入口可以
重新打开同一个共享，或明确停止。点击停止时为 CANCEL 保留最多五秒的发送机会，
随后清理媒体和会话；对端停止、系统撤销录屏、源/传输故障和 App 退出也会结束操作。
App 退出先关闭共享 Owner，再释放 AppRuntime；不会把页面隐藏当作进程销毁。
默认优先使用硬件 H.264，硬件不可用时由原生 Owner 自动降级为 CPU 编解码；
不展示模式开关。全部候选失败时显示有界错误码，资源释放未确认时不继续尝试。
共享路由关闭过渡快照，避免将正在播放的原生纹理转成页面截图；导航仍使用实时画面。

接收端从 H.264 SPS 读取有效尺寸（含编码块裁剪），后续帧保留该尺寸，避免把
手机竖屏或不同分辨率显示器误当作默认横屏尺寸。

设备级验证入口为 `test/device/screen_share_device_probe.dart`，通过
`flutter run -t test/device/screen_share_device_probe.dart` 在 Windows 和 Android
模拟器分别启动。测试使用隔离临时目录与固定测试身份，自动邀请和接受，检查
发送、解码和渲染计数；模拟器运行前设置 `adb forward tcp:47831 tcp:47831`。
Windows 发送默认只匹配公共测试记事本窗口，未找到唯一窗口时停止测试；不自动
选择整个桌面。可用 `SCREEN_PROBE_WINDOW_TITLE` 指定公共测试窗口；探针自身窗口
可在 Windows 使用 `--dart-entrypoint-args=self-window`。接收视图提供实际旋转和全屏
控件，`SCREEN_PROBE_HOLD_SECONDS` 控制有限的持续采样时长。
两端使用 `--dart-define=SCREEN_PROBE_REVERSE=true` 可验证 Android → Windows；
模拟器通过 `10.0.2.2` 访问主机，仍需完成 Android 系统录屏授权。
两端增加 `--dart-define=SCREEN_PROBE_CPU=true` 可强制验证 CPU 编解码路径；
未开启时保留硬件模式，缺少所选编解码器会报告能力失败，不能计作视频验收通过。
同一已构建探针也可通过 SDK 启动参数 `reverse` 切换方向；Windows 使用
`--dart-entrypoint-args=reverse`，Android 使用标准 `dart_entrypoint_args` Intent 参数。
Windows 接收端参数 `verify-window` 会检查原生全屏尺寸、恢复尺寸与 surface 连续性。
探针结束尝试发送正式 CANCEL，最多等待五秒；发送失败明确报告，随后仍释放
原生会话，并输出 `cleanup_finished` 供设备测试确认清理已完成。
此入口只用于设备测试，不进入正式应用；模拟器验证不能替代真机硬件能力验收。

`test/device/screen_share_session_probe.dart` 则通过正式 App 的操作 Owner 和页面
验证生命周期，固定使用 CPU 模式。两端运行此入口；增加启动参数 `reverse` 可验证
Android → Windows，否则验证 Windows → Android。Windows 发送只选择探针自身的
唯一 `SSH Mobile` 窗口，Android 发送仍需系统整屏录制授权。探针检查真实视频进度、
关闭页面后继续传帧、重新打开复用端点，以及明确停止和对端停止后的清理。
增加启动参数 `annotate`，或 `--dart-define=SCREEN_PROBE_ANNOTATE=true` 时，
接收端在正式操作上画一条公开测试笔迹，发送端确认收到，并在清理前保留约二十五秒供截图；
探针不记录坐标。方向同样接受 `--dart-define=SCREEN_PROBE_REVERSE=true`。
Android 上以 dart-define 为准。
测试期间可将 Android 退到公开的模拟器桌面，验证原生录屏服务继续运行；测试不读取
或导出帧内容。仅使用公开测试画面，沿用上述模拟器端口映射并在完成后清理映射。
接收页面还检查默认全屏、重新打开后的全屏及 Windows 页面关闭后的窗口恢复。

正式共享的源选择和来访邀请不展示编解码选项。发送和接收端分别自动选择硬件
优先、CPU 兜底的 H.264 实现，保持系统录屏授权和端点身份绑定。内部设备探针
仍可强制硬件或 CPU 模式，以分别验证能力；软件降级可能增加 CPU 占用。

启动品牌资源为 `assets/app_icon.svg`：透明边缘、浅蓝面板、蓝色终端提示符和青绿色
光标。`StartupBranding` 使用 SVG 等比显示，按可用短边限制在 64–128 逻辑像素，
保留安全区和大字号滚动空间。Android 原生启动页使用同款 VectorDrawable，日间与
夜间启动底色均为白色。系统图标通过 `dart run tool/generate_app_icons.dart` 生成
各平台 PNG 和包含 16–256 像素图层的 Windows ICO；调整 SVG 形状或配色时须同步
生成器与 Android vector。启动页仍使用白底；iOS 的系统图标按平台要求保持不透明。

## 依赖

屏幕共享支持已配对设备的原生 Direct QUIC/TCP 信令，无需配置 Relay；入口先经
LAN 的身份钉扎能力查询与 peer-policy Owner 准备直连，再创建 Realtime session。
无可用 Direct 时保留 Relay Control 路径。邀请、接受与拒绝仍由用户明确确认，
画面仍走 native WebRTC，不能把共享信令送达当作真实 capture/render 验收。

Windows Full App 在 LAN 广播期间通过注入的 discovery Port 识别本机在线 Android
Emulator。ADB 从已配置 Android SDK、Android Studio 默认 SDK 或 PATH 解析；未安装
或不可用时保留普通 LAN 发现。适配器只创建/释放自己的 console UDP 发现映射、
TCP HTTPS 映射以及独立 TCP/UDP native 映射，不读取配对密钥、不操作已有 ADB
forward、不停止模拟器。Windows 和模拟器内 Android 都需要使用支持来源端口
PONG 的版本；仍需双向 PIN 配对和原生传输接收审批。
模拟器 NAT 可能改写 PONG 的回复源端口，适配器为每台模拟器保留独立的回环
请求/接收 socket，按接收通道绑定其映射，不按回包源端口关联模拟器。
真实设备映射核验入口为 `flutter test --no-pub test/manual/lan_emulator_mapping_smoke.dart`：
需要唯一在线的本地模拟器，使用临时 TCP/UDP 应答器并清理本次映射，不访问 App 数据。

依赖由本 App 的 `pubspec.yaml` 声明，包含 Flutter、Core/Infrastructure/Feature
Package 和 App Shell 直接使用的插件；Feature 实现不得通过 App `/src/` 反向获取依赖。

## 数据库

Android 的 `MonitoringWidgetAdapter` 由 AppRuntime 持有，订阅现有监控服务和
公开的 Connection 目录变化，把四项真实指标与采样时间转换为
`android_server_widgets` 的安全快照。普通样本按通知去重并以至少十五秒间隔
同步，状态变化立即同步；桥接不创建 Timer，不改变监控的显式启动策略。
监控轮次时间和原生 writer session/sequence 防止旧样本或迟到写入恢复已停止状态。
删除连接、修改目标和导入恢复会使相应缓存失效。Runtime 先取消桥接订阅再关闭
监控 Module；Windows 不初始化 Android Widget 通道。

Android 桌面现在可从标准 Widget 选择器添加 SSH Mobile，并在原生配置页选择
服务器。每个实例独立保存选择；紧凑 2×2 和扩展 4×2 布局按桌面实际 dp 响应，
展示 CPU、内存、网络总吞吐、磁盘总 I/O 和绝对采样时间，遵循系统深浅色。
原生看板读取缓存时不需要 Flutter Engine，也不会启动第二套监控或 SSH 连接。
删除一个实例不影响监控服务或其他实例；导入配置会失效旧实例的选择。

点击看板通过 `MonitoringWidgetNavigationHost` 回到现有 Flutter 客户端。
App 等待启动就绪，再核对当前连接目录并打开相应监控详情；连接已删除时回到
首页。点击只导航，不启动监控、SSH 或远程操作。冷启动/热启动的消息归属与
迟到结果由独立通道和 App 路由测试验证。原生设备测试入口和精确证据范围见
基础设施包 README；模拟器固定测试数据不代表真实服务器或两台目标真机验收。

原生最新快照由插件的应用私有 DataStore 保存，不计入 App 日志或 Feature 历史。
目录只含内部 ID 和脱敏名称；完整连接配置、地址、用户名和凭据不进入原生缓存。
纯 JVM 的持久化重建测试不能代替 Android 进程重建与真实监控验收。
桥接回归入口为 `test/app/monitoring_widget_adapter_test.dart`，插件边界和验证命令见
[`android_server_widgets`](../../packages/infrastructure/android_server_widgets/README.md)。

App Shell 只拥有独立的 `app_logs` 日志数据库。Connection、AI、Terminal、SFTP、
Playbook、RAG、MCP 和 LAN Share 数据库分别由对应 Core/Feature Module 拥有；不再创建
统一 `AppDatabase`。

## 生命周期与资源 Owner

`AppRuntimeFactory` 创建 App Scope 资源，`AppRuntime` 按依赖逆序释放 Module → Realtime
→ SFTP → SSH → Network → Database → Logger（适配器与 Route Scope 资源先于 Module
解除）；错误 handler bridge 与结构化 telemetry sink 在 TelemetryClient 关闭前
先恢复/排空。Route Scope 负责 ViewModel、Controller、Timer 与 Subscription。控制面由
`network_sdk` 的 typed client 使用 App Shell 注入的 `SdkRequestExecutor`，LAN 数据面
仍由 AppRuntime-owned native gateway/共享 `NetworkFacade` 负责。LAN Receiver 只关闭
自己的 HTTP/Discovery/Transfer 资源与订阅，不释放 NetworkRuntime/native handle。

LAN Control Protocol V2 和 Native Network Protocol V2 是独立版本域；LAN Control
breaking refactor 不保留旧 pairing schema、`/api/lan/upload` binary fallback 或旧
API compatibility wrapper。按本 ADR 的控制面决定，Feature-facing
`NetworkFacade.sendMessage` 保持 unavailable 边界，text/clipboard 由 Feature 走
authenticated HTTPS + application E2E。

后台 SSH 的平台前台服务与 isolate runtime 分属不同 Owner：
`BackgroundServiceManager` 只负责通知/权限/power lock/服务启停，后台入口点创建的
`_BackgroundSshRuntime` 独占 session registry、SSH/tmux、keepalive 和事件订阅；两者
不得共享 SSH client、shell 或 Timer。

前台 `SshService` 中，`_SshBackgroundEventBridge` 独占后台插件事件订阅，
`_SshSessionProjection` 独占不可变 session 列表与 connection overview 聚合；连接、
会话、命令和 history queue 仍由 `SshService` 拥有。前后台建连在登记到 session
registry 前由 attempt owner 持有，并以 per-session generation 阻止迟到回调覆盖新资源；
`SshService.close()` 会等待 connect/reconnect、后台 isolate 确认、订阅、runtime、history
queue、Session Pool 和 native stream connector 完成释放。Network V2 codec 是窄 facade，命令
编码与 Peer/Transfer/SSH Stream typed decoder 彼此独立；Realtime 使用自己的 native
protocol，不属于当前 V2 event schema。

System Admin 的 App Shell 组合按职责拆为 Port/Route 聚合、设置与本地化投影、
SSH 目标绑定与有界命令执行；后者返回 Route-owned Lease，并在取消、超时、输出超限
或目标代次变化时关闭全部局部 process/client，不关闭 App Scope SSH owner。

## 测试命令

```bash
flutter analyze
flutter test
```

## Local development diagnostics

Runtime output and agent queries follow the [local diagnostic contract](../../docs/agent/runtime-diagnostics.md).
App composition roots inject `app_diagnostics` through public Core logging
contracts; Feature dependencies remain unchanged. Development tools own launched
processes and file queries, and are never imported by runtime packages.
