// Terminal 会话交互 ViewModel。
//
// 负责 xterm Controller、输出节流、键盘输入和页面级 SSH Capability 调用。
// SSH 连接由注入的 SshSessionManager 统一拥有；dispose 只释放本页面资源。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart';
import 'package:xterm/xterm.dart';

import '../domain/terminal_keyboard_models.dart';
import '../domain/terminal_models.dart';
import '../domain/terminal_secret_policy.dart';
import 'terminal_text_buffer.dart';
import 'terminal_window_snapshot.dart';

part 'terminal_session_windows.dart';

/// 终端交互页面状态。
final class TerminalSessionViewModel extends ChangeNotifier {
  /// 创建会话 ViewModel；只注入 App Scope SSH Manager。
  TerminalSessionViewModel({
    required this._sshSessionManager,
    required this.sessionId,
    required this.connectionId,
  }) {
    _bindSession();
  }

  /// 从 Scope 中已注入的 SSH Manager 创建会话 ViewModel。
  factory TerminalSessionViewModel.fromContext(
    BuildContext context, {
    required String sessionId,
    required String connectionId,
  }) {
    return TerminalSessionViewModel(
      sshSessionManager: context.read<SshSessionManager>(),
      sessionId: sessionId,
      connectionId: connectionId,
    );
  }

  void _bindSession() {
    _changesSubscription = _terminal.changes.listen(
      (_) => _onSshServiceChanged(),
    );

    final initialFontSize =
        _terminal.getSession(sessionId)?.fontSize ??
        SshSession.defaultTerminalFontSize;
    _fontSize = initialFontSize;

    terminal = Terminal(
      maxLines: _terminalScrollbackLines,
      onOutput: _handleTerminalInput,
    );
    terminalController = TerminalController();
    terminalFocusNode = FocusNode();
    commandInputFocusNode = FocusNode(
      debugLabel: 'Windows terminal command input',
    );
    complexInputController = TextEditingController();
    commandInputController = TextEditingController();

    _attachExistingSession();
  }

  final SshSessionManager _sshSessionManager;
  final String sessionId;
  final String connectionId;
  StreamSubscription<void>? _changesSubscription;

  bool _ctrlActive = false;
  bool _altActive = false;
  double _fontSize = 13.0;
  final List<String> _commandInputHistory = <String>[];
  int? _commandInputHistoryIndex;
  String _commandInputHistoryDraft = '';

  late final Terminal terminal;
  late final TerminalController terminalController;
  late final FocusNode terminalFocusNode;
  late final FocusNode commandInputFocusNode;
  late final TextEditingController complexInputController;
  late final TextEditingController commandInputController;

  bool _reconnectInProgress = false;
  bool _loadingBufferedOutput = false;
  bool _loadedBufferedOutput = false;
  bool _hasShownDisconnectMessage = false;
  StreamSubscription<String>? _outputSubscription;
  String? _subscribedSessionId;
  final TerminalTextBuffer _pendingTerminalWrites = TerminalTextBuffer(
    maxChars: _maxPendingTerminalWriteChars,
  );
  bool _terminalWriteScheduled = false;
  DateTime _lastFlushTime = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _throttleTimer;
  bool _disposed = false;

  /// 页面字号下限，与 SSH 会话字号边界一致。
  static const double minFontSize = SshSession.minTerminalFontSize;

  /// 页面字号上限，与 SSH 会话字号边界一致。
  static const double maxFontSize = SshSession.maxTerminalFontSize;
  static const int _baseTerminalFlushChars = 12000;
  static const int _highTerminalFlushChars = 40000;
  static const int _terminalScrollbackLines = 4000;
  static const int _commandInputHistoryLimit = 100;
  static const int _maxPendingTerminalWriteChars = 200000;
  static const int _maxHistoryLoadLiveOutputChars = 200000;
  static final TerminalSecretPolicy _secretPolicy = TerminalSecretPolicy();

  SshTerminalCapability get _terminal =>
      _sshSessionManager.terminalCapability ??
      (throw StateError('SSH Manager has no Terminal capability.'));

  @override
  void dispose() {
    _disposed = true;
    _changesSubscription?.cancel();
    _outputSubscription?.cancel();
    _throttleTimer?.cancel();
    _pendingTerminalWrites.clear();
    terminalController.dispose();
    terminalFocusNode.dispose();
    commandInputFocusNode.dispose();
    complexInputController.dispose();
    commandInputController.dispose();
    super.dispose();
  }

  void _onSshServiceChanged() {
    if (_disposed) return;
    final current = _terminal.getSession(sessionId);
    if (current?.isConnected == true) {
      _setupOutputStream();
    } else if (current?.state == SshConnectionState.disconnected ||
        current?.state == SshConnectionState.error) {
      _showDisconnected(current?.errorMessage);
    }
    notifyListeners();
  }

  bool get ctrlActive => _ctrlActive;
  bool get altActive => _altActive;
  double get fontSize => _fontSize;
  bool get reconnectInProgress => _reconnectInProgress;
  bool get loadingBufferedOutput => _loadingBufferedOutput;
  SshTerminalSession? get session => _terminal.getSession(sessionId);
  bool get isConnected => session?.isConnected ?? false;
  TerminalLinkState get connectionState =>
      terminalLinkStateOf(session?.state ?? SshConnectionState.disconnected);
  String? get connectionError =>
      session?.errorMessage ?? _terminal.errorMessage;
  String? get displayName => session?.displayName;

  bool get isWindowsTarget =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  void toggleCtrl() {
    _ctrlActive = !_ctrlActive;
    notifyListeners();
  }

  void toggleAlt() {
    _altActive = !_altActive;
    notifyListeners();
  }

  void setCtrlActive(bool active) {
    if (_ctrlActive == active) return;
    _ctrlActive = active;
    notifyListeners();
  }

  void setAltActive(bool active) {
    if (_altActive == active) return;
    _altActive = active;
    notifyListeners();
  }

  void setFontSize(double size) {
    final nextSize = size.clamp(minFontSize, maxFontSize);
    if ((nextSize - _fontSize).abs() < 0.05) return;
    _fontSize = nextSize;
    _terminal.setSessionFontSize(sessionId, nextSize);
    notifyListeners();
  }

  void changeFontSize(double delta) => setFontSize(_fontSize + delta);

  void sendData(String data) => _terminal.sendData(sessionId, data);

  bool sendTerminalKeyboardStroke(TerminalKeyboardStroke stroke) {
    if (_ctrlActive) setCtrlActive(false);
    if (_altActive) setAltActive(false);

    final key = stroke.key;
    if (key != null) {
      return terminal.keyInput(
        key,
        ctrl: stroke.ctrl,
        alt: stroke.alt,
        shift: stroke.shift,
      );
    }
    final text = stroke.text;
    if (text == null || text.isEmpty) return false;
    var output = text;
    if (stroke.ctrl && text.length == 1) {
      final code = text.codeUnitAt(0);
      if (code == 32) {
        output = '\x00';
      } else if (code >= 64 && code <= 95) {
        output = String.fromCharCode(code - 64);
      } else if (code >= 96 && code <= 127) {
        output = String.fromCharCode(code - 96);
      }
    }
    if (stroke.alt) output = '\x1b$output';
    terminal.textInput(output);
    return true;
  }

  bool submitCommandInput() {
    final text = commandInputController.text;
    if (text.isEmpty) return terminal.keyInput(TerminalKey.enter);
    final submitted = submitCommandText(text);
    if (submitted) commandInputController.clear();
    return submitted;
  }

  bool submitCommandText(String text) {
    if (text.isEmpty) return false;
    final normalizedText = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    terminal.paste(normalizedText);
    terminal.keyInput(TerminalKey.enter);
    _rememberCommandInput(normalizedText);
    resetCommandInputHistoryNavigation();
    return true;
  }

  void insertCommandInputText(String text) {
    if (text.isEmpty) return;
    final value = commandInputController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    commandInputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
    resetCommandInputHistoryNavigation();
  }

  Future<bool> pasteClipboardIntoCommandInput() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return false;
    insertCommandInputText(text);
    return true;
  }

  void clearCommandInput() {
    commandInputController.clear();
    resetCommandInputHistoryNavigation();
  }

  void resetCommandInputHistoryNavigation() {
    _commandInputHistoryIndex = null;
    _commandInputHistoryDraft = '';
  }

  bool showPreviousCommandInput() {
    if (_commandInputHistory.isEmpty) return false;
    final currentIndex = _commandInputHistoryIndex;
    if (currentIndex == null) {
      _commandInputHistoryDraft = commandInputController.text;
      _commandInputHistoryIndex = _commandInputHistory.length - 1;
    } else if (currentIndex > 0) {
      _commandInputHistoryIndex = currentIndex - 1;
    }
    _showCommandInputHistoryValue(
      _commandInputHistory[_commandInputHistoryIndex!],
    );
    return true;
  }

  bool showNextCommandInput() {
    final currentIndex = _commandInputHistoryIndex;
    if (currentIndex == null) return false;
    if (currentIndex < _commandInputHistory.length - 1) {
      _commandInputHistoryIndex = currentIndex + 1;
      _showCommandInputHistoryValue(
        _commandInputHistory[_commandInputHistoryIndex!],
      );
    } else {
      _commandInputHistoryIndex = null;
      _showCommandInputHistoryValue(_commandInputHistoryDraft);
      _commandInputHistoryDraft = '';
    }
    return true;
  }

  void _rememberCommandInput(String text) {
    if (_commandInputHistory.isNotEmpty && _commandInputHistory.last == text) {
      return;
    }
    _commandInputHistory.add(text);
    if (_commandInputHistory.length > _commandInputHistoryLimit) {
      _commandInputHistory.removeAt(0);
    }
  }

  void _showCommandInputHistoryValue(String text) {
    commandInputController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void syncTerminalSize(int width, int height) {
    if (width > 0 && height > 0) {
      _terminal.resizeTerminal(sessionId, width, height);
    }
  }

  Future<void> reconnect() async {
    if (_reconnectInProgress) return;
    _reconnectInProgress = true;
    if (!_disposed) notifyListeners();
    final connected = await _terminal.ensureSessionConnected(
      sessionId,
      connectionId,
    );
    if (connected) {
      _setupOutputStream();
      _hasShownDisconnectMessage = false;
    } else {
      _showDisconnected(_terminal.errorMessage);
    }
    _reconnectInProgress = false;
    if (!_disposed) notifyListeners();
  }

  void _handleTerminalInput(String data) {
    if (_ctrlActive) {
      setCtrlActive(false);
      if (data.length == 1) {
        final charCode = data.codeUnitAt(0);
        if ((charCode >= 97 && charCode <= 122) ||
            (charCode >= 65 && charCode <= 90)) {
          final ctrlCode = charCode >= 97 ? charCode - 96 : charCode - 64;
          _terminal.sendData(sessionId, String.fromCharCode(ctrlCode));
          return;
        }
      }
      _terminal.sendData(sessionId, data);
      return;
    }
    if (_altActive) {
      setAltActive(false);
      _terminal.sendData(sessionId, data.length == 1 ? '\x1b$data' : data);
      return;
    }
    _terminal.sendData(sessionId, data);
  }

  void _attachExistingSession() {
    final current = session;
    if (current?.isConnected == true) {
      _setupOutputStream();
      _hasShownDisconnectMessage = false;
    } else if (current != null) {
      _setupOutputStream();
      if (current.state == SshConnectionState.disconnected ||
          current.state == SshConnectionState.error) {
        _showDisconnected(current.errorMessage);
      }
    }
  }

  Future<void> _setupOutputStream() async {
    final current = session;
    if (current == null || _subscribedSessionId == current.id) return;
    await _outputSubscription?.cancel();
    _subscribedSessionId = current.id;
    final pendingOutput = TerminalTextBuffer(
      maxChars: _maxHistoryLoadLiveOutputChars,
    );
    var queueLiveOutput = !_loadedBufferedOutput;
    _outputSubscription = current.output.listen(
      (data) {
        if (queueLiveOutput) {
          pendingOutput.add(data);
        } else {
          _queueTerminalWrite(data);
        }
      },
      onError: (error) => _queueTerminalWrite(
        '\r\n\x1b[31m[Error: ${_secretPolicy.previewText(error.toString())}]'
        '\x1b[0m\r\n',
      ),
      onDone: () =>
          _queueTerminalWrite('\r\n\x1b[33m[Connection closed]\x1b[0m\r\n'),
    );

    if (!_loadedBufferedOutput && !_loadingBufferedOutput) {
      _loadingBufferedOutput = true;
      if (!_disposed) notifyListeners();
      try {
        final bufferedOutput = current.outputText;
        final initialOutput = bufferedOutput.isNotEmpty
            ? bufferedOutput
            : await _terminal.loadSessionHistoryText(current.id);
        if (_disposed || _subscribedSessionId != current.id) return;
        if (initialOutput.isNotEmpty) _queueTerminalWrite(initialOutput);
        final pending = pendingOutput.takeAll();
        if (pending.isNotEmpty && !initialOutput.endsWith(pending)) {
          _queueTerminalWrite(pending);
        }
        _loadedBufferedOutput = true;
      } finally {
        _loadingBufferedOutput = false;
        if (!_disposed) notifyListeners();
        queueLiveOutput = false;
      }
    } else {
      queueLiveOutput = false;
    }
  }

  void _showDisconnected(String? reason) {
    if (_hasShownDisconnectMessage) return;
    _hasShownDisconnectMessage = true;
    _queueTerminalWrite(
      '\r\n\x1b[31m[Disconnected: '
      '${_secretPolicy.previewText(reason ?? 'unknown')}]\x1b[0m\r\n',
    );
  }

  void _queueTerminalWrite(String data) {
    if (_disposed || data.isEmpty) return;
    _pendingTerminalWrites.add(data);
    if (_terminalWriteScheduled) return;
    final elapsed = DateTime.now().difference(_lastFlushTime).inMilliseconds;
    final isHighFrequency =
        elapsed < 50 || _pendingTerminalWrites.charCount > 2000;
    _terminalWriteScheduled = true;
    if (isHighFrequency) {
      _throttleTimer = Timer(const Duration(milliseconds: 25), () {
        _throttleTimer = null;
        _flushTerminalWrites();
      });
    } else {
      try {
        WidgetsBinding.instance.scheduleFrameCallback(
          (_) => _flushTerminalWrites(),
        );
      } catch (_) {
        // The ViewModel also runs in headless/unit-test owners where no Flutter
        // frame binding exists. A microtask retains batching without requiring
        // UI initialization.
        scheduleMicrotask(_flushTerminalWrites);
      }
    }
  }

  void _flushTerminalWrites() {
    if (_disposed) {
      _terminalWriteScheduled = false;
      _pendingTerminalWrites.clear();
      return;
    }
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _terminalWriteScheduled = false;
    _lastFlushTime = DateTime.now();
    if (_pendingTerminalWrites.isEmpty) return;
    _clearTerminalSelection();
    final buffer = StringBuffer();
    final flushLimit = _pendingTerminalWrites.charCount > 15000
        ? _highTerminalFlushChars
        : _baseTerminalFlushChars;
    final next = _pendingTerminalWrites.takeUpTo(flushLimit);
    buffer.write(next);
    final text = buffer.toString();
    if (text.isNotEmpty) {
      try {
        terminal.write(text);
      } catch (_) {}
    }
    if (_pendingTerminalWrites.isNotEmpty) {
      _terminalWriteScheduled = true;
      _throttleTimer = Timer(const Duration(milliseconds: 25), () {
        _throttleTimer = null;
        _flushTerminalWrites();
      });
    }
  }

  void _clearTerminalSelection() {
    try {
      if (terminalController.selection == null) return;
      terminalController.clearSelection();
    } catch (_) {}
  }

  void selectWordAtPosition(
    Offset globalPos,
    GlobalKey<TerminalViewState> viewKey,
  ) {
    final terminalView = viewKey.currentState;
    if (terminalView == null) return;
    try {
      final renderTerminal = terminalView.renderTerminal;
      final offset = renderTerminal.getCellOffset(
        renderTerminal.globalToLocal(globalPos),
      );
      final boundary = terminal.buffer.getWordBoundary(offset);
      if (boundary == null) {
        _clearTerminalSelection();
        return;
      }
      terminalController.setSelection(
        terminal.buffer.createAnchorFromOffset(boundary.begin),
        terminal.buffer.createAnchorFromOffset(boundary.end),
      );
    } catch (_) {
      _clearTerminalSelection();
    }
  }

  void selectAllText() {
    try {
      terminalController.setSelection(
        terminal.buffer.createAnchor(
          0,
          terminal.buffer.height - terminal.viewHeight,
        ),
        terminal.buffer.createAnchor(
          terminal.viewWidth,
          terminal.buffer.height - 1,
        ),
      );
    } catch (_) {
      _clearTerminalSelection();
    }
  }

  void clearSelection() => _clearTerminalSelection();

  String getSelectedText() {
    try {
      final selection = terminalController.selection;
      if (selection == null) return '';
      return terminal.buffer.getText(selection);
    } catch (_) {
      _clearTerminalSelection();
      return '';
    }
  }

  Future<void> copySelectedText() async {
    final text = getSelectedText();
    if (text.isNotEmpty) await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> pasteClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) sendData(text);
  }
}
