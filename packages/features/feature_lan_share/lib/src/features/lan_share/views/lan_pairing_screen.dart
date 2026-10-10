// 消费类型化握手与配对结果的 V2 LAN 配对页面。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/lan_share_ports.dart';
import '../../../services/lan_share/lan_pairing_reciprocal.dart';
import '../../../services/lan_share/lan_share_models.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:app_ui/app_ui.dart';
import '../lan_share_feature_scope.dart';
import '../viewmodels/lan_share_viewmodel.dart';
import 'lan_chat_screen.dart';

/// 展示 V2 LAN 配对 PIN 流程。
class LanPairingScreen extends StatefulWidget {
  final String targetDeviceId;
  final String initialAlias;
  final String sessionId;
  final LanDiscoveredPeer? initialPeer;
  final bool isIncomingRequest;

  /// 为一个目标设备和会话创建配对页面。
  const LanPairingScreen({
    super.key,
    required this.targetDeviceId,
    required this.initialAlias,
    required this.sessionId,
    this.initialPeer,
    this.isIncomingRequest = false,
  });

  /// 创建可变的配对页面状态。
  @override
  State<LanPairingScreen> createState() => _LanPairingScreenState();
}

class _LanPairingScreenState extends State<LanPairingScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _pinController = TextEditingController();
  late AnimationController _radarController;

  bool _isLoading = false;
  String? _errorMessage;
  String _localPin = '------';
  int _pinCountdown = 60;
  Timer? _countdownTimer;
  bool _hasOpenedChat = false;
  late bool _isIncomingRequest;
  late String _targetDeviceId;
  late String _targetAlias;
  LanDiscoveredPeer? _targetPeer;
  LanPairingDirectionNotice? _directionNotice;
  StreamSubscription? _handshakeSubscription;
  StreamSubscription<LanPairingDirectionNotice>? _directionSubscription;
  StreamSubscription<LanPairingRequest>? _pairingRequestSubscription;

  /// 订阅配对更新并启动本地 PIN 倒计时。
  @override
  void initState() {
    super.initState();
    _isIncomingRequest = widget.isIncomingRequest;
    _targetDeviceId = widget.targetDeviceId;
    _targetAlias = widget.initialAlias;
    _targetPeer = widget.initialPeer;
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    // Load or generate the local PIN
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final vm = context.read<LanShareViewModel>();
      _directionNotice = vm.transferService.pairingDirectionFor(
        _targetDeviceId,
      );
      _refreshLocalPin();
      _handshakeSubscription = vm.transferService.handshakeSuccessPeerStream
          .listen((peer) {
            if (peer.deviceId == _targetDeviceId && mounted) {
              _openChat();
            }
          });
      _directionSubscription = vm.transferService.pairingDirectionStream.listen(
        _applyDirectionNotice,
      );
      _pairingRequestSubscription = vm.pairingRequestStream.listen(
        _handlePairingRequest,
      );
      final latestRequest = vm.pairingRequestForSession(widget.sessionId);
      if (latestRequest != null) {
        _handlePairingRequest(latestRequest);
      }
    });
  }

  /// 应用变更后的目标设备或请求方向。
  @override
  void didUpdateWidget(covariant LanPairingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _targetDeviceId = widget.targetDeviceId;
    _targetAlias = widget.initialAlias;
    _isIncomingRequest = widget.isIncomingRequest;
    if (oldWidget.targetDeviceId != widget.targetDeviceId) {
      _targetPeer = widget.initialPeer;
      _directionNotice = context
          .read<LanShareViewModel>()
          .transferService
          .pairingDirectionFor(widget.targetDeviceId);
    } else if (widget.initialPeer != null) {
      _targetPeer = widget.initialPeer;
    }
  }

  /// 记录对端的 PIN 进度，并保留已经输入的 PIN。
  void _applyDirectionNotice(LanPairingDirectionNotice notice) {
    if (!mounted || notice.peerId != _targetDeviceId) return;
    setState(() {
      _directionNotice = notice.outboundVerified || notice.inboundVerified
          ? notice
          : null;
    });
  }

  /// 将匹配的配对请求应用到当前页面状态。
  void _handlePairingRequest(LanPairingRequest request) {
    if (!mounted || request.isExpired) return;
    final matchesSession = request.sessionId == widget.sessionId;
    final matchesDevice = request.peer.peerId == _targetDeviceId;
    if (!matchesSession && !matchesDevice) return;

    setState(() {
      _targetDeviceId = request.peer.peerId;
      _targetAlias = request.peer.displayAlias;
      _targetPeer = request.peer.discovery ?? _targetPeer;
      if (request.isIncoming) {
        _isIncomingRequest = true;
      }
    });
  }

  /// 只导航到已配对聊天页面一次。
  void _openChat() {
    if (!mounted || _hasOpenedChat) return;
    _hasOpenedChat = true;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => LanShareFeatureScope(
          child: LanChatScreen(
            targetDeviceId: _targetDeviceId,
            initialAlias: _targetAlias,
          ),
        ),
      ),
    );
  }

  /// 刷新本地 PIN，并重新启动过期倒计时。
  void _refreshLocalPin() {
    final vm = context.read<LanShareViewModel>();
    final pin = vm.securityService.getOrGenerate6DigitPin();
    if (!mounted) return;
    setState(() {
      _localPin = pin;
      _pinCountdown = vm.securityService.pinSecondsRemaining;
    });
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final remaining = context
          .read<LanShareViewModel>()
          .securityService
          .pinSecondsRemaining;
      setState(() => _pinCountdown = remaining);
      if (remaining <= 0) {
        _countdownTimer?.cancel();
        _refreshLocalPin();
      }
    });
  }

  /// 取消定时器、订阅、控制器和动画。
  @override
  void dispose() {
    _countdownTimer?.cancel();
    _handshakeSubscription?.cancel();
    _directionSubscription?.cancel();
    _pairingRequestSubscription?.cancel();
    _radarController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  /// 通过类型化 ViewModel 结果契约提交输入的 PIN。
  Future<void> _submitPin(LanShareViewModel vm, LanShareStrings strings) async {
    final pin = _pinController.text.trim();
    if (pin.length != 6) {
      setState(() {
        _errorMessage = '请输入完整的6位PIN码';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Find the device in viewmodel
    final targetDevice =
        vm.peerStateFor(_targetDeviceId)?.discovery ?? _targetPeer;

    if (targetDevice == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = strings.lanShareOffline;
      });
      return;
    }

    try {
      final result = await vm.authenticateDevice(
        targetDevice,
        pin,
        isInitiator: !_isIncomingRequest,
      );
      if (!mounted) return;
      if (result is NetworkSuccess<LanPairingHandshakeProgress> &&
          result.data == LanPairingHandshakeProgress.paired) {
        _openChat();
        return;
      }
      setState(() {
        _isLoading = false;
        if (result is NetworkSuccess<LanPairingHandshakeProgress>) {
          _errorMessage = null;
          _directionNotice =
              vm.transferService.pairingDirectionFor(_targetDeviceId) ??
              _directionNotice;
        } else if (result is NetworkFailure<LanPairingHandshakeProgress>) {
          _errorMessage = _pairingFailureMessage(result.error, strings);
        } else {
          _errorMessage = strings.lanSharePinMismatch;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = strings.isEnglish
            ? 'Network connection failed. Check that both devices are on the same Wi-Fi.'
            : '网络连接失败，请检查两端设备是否在同一 Wi-Fi。';
      });
    }
  }

  String _pairingFailureMessage(NetworkError error, LanShareStrings strings) {
    if (error.code == NetworkErrorCode.authenticationFailed) {
      return strings.lanSharePinMismatch;
    }
    if (error.code == NetworkErrorCode.identityConflict) {
      return strings.isEnglish
          ? 'Device identity changed. Unpair it and try pairing again.'
          : '设备身份已变化，请先解除配对后重试。';
    }
    if (error.code == NetworkErrorCode.timeout) {
      return strings.isEnglish
          ? 'Pairing timed out. Check that both devices are on the same Wi-Fi.'
          : '配对请求超时，请检查两端设备是否在同一 Wi-Fi。';
    }
    if (error.code == NetworkErrorCode.noRoute ||
        error.code == NetworkErrorCode.peerOffline) {
      return strings.isEnglish
          ? 'The device is unreachable. Check its address and Wi-Fi connection.'
          : '无法连接到设备，请检查设备地址和 Wi-Fi 连接。';
    }
    if (error.code == NetworkErrorCode.invalidArgument) {
      return strings.isEnglish
          ? 'The pairing request is invalid. Enter the current 6-digit PIN.'
          : '配对请求无效，请输入当前显示的 6 位 PIN 码。';
    }
    return strings.isEnglish
        ? 'Pairing failed: ${error.message}'
        : '配对失败：${error.message}';
  }

  /// 构建配对 UI 和当前审批状态。
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<LanShareViewModel>();
    final settings = context.read<LanShareSettingsPort>();
    final strings = settings.strings;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.lanSharePinPairing),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: AppPageSurface(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 16.0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Beautiful Pulsing Radar Animation
                SizedBox(
                  width: 220,
                  height: 220,
                  child: Stack(
                    alignment: Alignment.center,
                    children:
                        List.generate(3, (index) {
                          return AnimatedBuilder(
                            animation: _radarController,
                            builder: (context, child) {
                              final progress =
                                  (_radarController.value + index / 3) % 1.0;
                              return Container(
                                width: 100 + (progress * 120),
                                height: 100 + (progress * 120),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.primary.withValues(
                                    alpha: (1.0 - progress) * 0.25,
                                  ),
                                ),
                              );
                            },
                          );
                        })..add(
                          Container(
                            width: 90,
                            height: 90,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.primaryContainer,
                              boxShadow: [
                                BoxShadow(
                                  color: colors.primary.withValues(alpha: 0.3),
                                  blurRadius: 16,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Icon(
                              Icons.security_rounded,
                              size: 40,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ),
                  ),
                ),
                const SizedBox(height: 48),

                Text(
                  _isIncomingRequest ? '安全配对请求' : '准备连接至$_targetAlias',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _isIncomingRequest
                      ? '设备$_targetAlias请求与您配对连接…'
                      : '正在建立安全连接，请输入对方设备上显示的PIN码…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                if (pairingDirectionHint(
                      _directionNotice,
                      english: strings.isEnglish,
                    )
                    case final hint?) ...[
                  const SizedBox(height: 12),
                  Text(
                    hint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 20),

                // Local PIN display card
                Builder(
                  builder: (context) {
                    final isExpiring = _pinCountdown <= 10;
                    final countdownColor = isExpiring
                        ? colors.error
                        : colors.primary;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20.0,
                        vertical: 14.0,
                      ),
                      decoration: BoxDecoration(
                        color: isExpiring
                            ? colors.errorContainer.withValues(alpha: 0.25)
                            : colors.primaryContainer.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: countdownColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '本机PIN码',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: countdownColor.withValues(alpha: 0.75),
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _localPin,
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 10.0,
                                  color: countdownColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 20),
                          // Circular countdown indicator
                          GestureDetector(
                            onTap: _refreshLocalPin,
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  AppLoadingIndicator(
                                    value: _pinCountdown / 60.0,
                                    size: 44,
                                    strokeWidth: 3,
                                    backgroundColor: countdownColor.withValues(
                                      alpha: 0.15,
                                    ),
                                    color: countdownColor,
                                  ),
                                  Text(
                                    '$_pinCountdown',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: countdownColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),

                // Glassmorphic Style PIN Form Container
                Container(
                  padding: const EdgeInsets.all(24.0),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLowest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        strings.lanSharePinPrompt,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Custom 6-Digit PIN Field
                      TextField(
                        controller: _pinController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 8.0,
                        ),
                        decoration: InputDecoration(
                          hintText: '••••••',
                          hintStyle: TextStyle(
                            color: colors.onSurfaceVariant.withValues(
                              alpha: 0.3,
                            ),
                            letterSpacing: 4.0,
                          ),
                          counterText: '',
                          errorText: _errorMessage,
                          errorMaxLines: 2,
                          filled: true,
                          fillColor: colors.surfaceContainer,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 16.0,
                            horizontal: 8.0,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        enabled: !_isLoading,
                      ),
                      const SizedBox(height: 24),

                      // Submit Button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colors.primary,
                            foregroundColor: colors.onPrimary,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: _isLoading
                              ? null
                              : () => _submitPin(vm, strings),
                          child: _isLoading
                              ? const AppLoadingIndicator(
                                  size: 24,
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                )
                              : const Text(
                                  '确认配对',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Cancel button
                TextButton(
                  onPressed: _isLoading ? null : () => Navigator.pop(context),
                  child: Text(
                    strings.cancel,
                    style: TextStyle(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
