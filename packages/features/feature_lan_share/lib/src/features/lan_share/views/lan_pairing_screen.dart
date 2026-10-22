// 消费类型化握手与配对结果的 V2 LAN 配对页面。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/lan_share_ports.dart';
import '../../../domain/lan_device_strings.dart';
import '../../../services/lan_share/lan_pairing_reciprocal.dart';
import '../../../services/lan_share/lan_share_models.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:app_ui/app_ui.dart';
import '../lan_share_feature_scope.dart';
import '../viewmodels/lan_share_viewmodel.dart';
import 'lan_chat_screen.dart';

part 'widgets/lan_pairing_content.dart';

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
  LanShareViewModel? _viewModel;
  int _attemptGeneration = 0;
  bool _terminated = false;
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
      _viewModel = vm;
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
    if (!mounted || _hasOpenedChat || _terminated) return;
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
    _attemptGeneration++;
    if (_isLoading) _viewModel?.cancelPairingAuthentication(_targetDeviceId);
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
    if (_isLoading) return;
    final generation = ++_attemptGeneration;
    _terminated = false;
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
      if (!mounted || generation != _attemptGeneration) return;
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
      if (!mounted || generation != _attemptGeneration) return;
      setState(() {
        _isLoading = false;
        _errorMessage = strings.isEnglish
            ? 'Network connection failed. Check that both devices are on the same Wi-Fi.'
            : '网络连接失败，请检查两端设备是否在同一 Wi-Fi。';
      });
    }
  }

  void _terminatePairing(LanShareViewModel vm) {
    _attemptGeneration++;
    _terminated = true;
    vm.cancelPairingAuthentication(_targetDeviceId);
    setState(() => _isLoading = false);
    Navigator.maybePop(context);
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

  @override
  Widget build(BuildContext context) => _buildPairingContent(context);
}
