import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:app_ui/app_ui.dart';
import 'package:connection_core/connection_core.dart';

import '../application/connection_ports.dart';
import '../application/connection_view_model.dart';
import 'connection_strings.dart';
import 'connection_credential_protection.dart';
import '../application/connection_credential_editor.dart';
import '../widgets/connection_layout.dart';
import '../widgets/connection_surface.dart';
import '../widgets/connection_ui_tokens.dart';

part 'add_edit_form_fields.dart';
part 'add_edit_advanced_fields.dart';
part 'add_edit_actions.dart';
part 'add_edit_credentials.dart';

class AddEditScreen extends StatefulWidget {
  final String? editId;

  const AddEditScreen({super.key, this.editId});

  @override
  State<AddEditScreen> createState() => _AddEditScreenState();
}

class _AddEditScreenState extends State<AddEditScreen>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(
    text: ConnectionUiTokens.defaultPortText,
  );
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _jumpHostController = TextEditingController();
  final _jumpPortController = TextEditingController(
    text: ConnectionUiTokens.defaultPortText,
  );
  final _jumpUsernameController = TextEditingController();
  final _tmuxAutoDeleteController = TextEditingController(
    text: ConnectionUiTokens.defaultTmuxDeleteMinutesText,
  );

  AuthMethod _authMethod = AuthMethod.password;
  TerminalLaunchMode _launchMode = TerminalLaunchMode.ssh;
  ServerPlatform _serverPlatform = ServerPlatform.linux;
  bool _keepAlive = true;
  bool _obscurePassword = true;
  bool _isLoadingSecrets = false;
  bool _jumpHostExpanded = false;
  bool _advancedOptionsExpanded = false;
  ConnectionCredentialEditor? _credentialEditor;
  CredentialPair? _appliedCredentials;

  bool get isEditing => widget.editId != null;

  /// 让 library part 中的表单扩展安全地更新 State，避免直接暴露
  /// Flutter State 的 protected setState 成员。
  void _updateState(VoidCallback callback) => setState(callback);

  int _secondsToDisplayMinutes(int seconds) {
    return ((seconds + 59) ~/ 60).clamp(
      ConnectionUiTokens.minTmuxDeleteMinutes,
      ConnectionUiTokens.maxTmuxDeleteMinutes,
    );
  }

  int _tmuxAutoDeleteSecondsFromInput() {
    final minutes = int.tryParse(_tmuxAutoDeleteController.text.trim()) ?? 10;
    return minutes.clamp(
          ConnectionUiTokens.minTmuxDeleteMinutes,
          ConnectionUiTokens.maxTmuxDeleteMinutes,
        ) *
        60;
  }

  ConnectionStrings _strings(BuildContext context) {
    return context.watch<ConnectionStrings?>() ?? ConnectionStrings();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isEditing) _loadExistingConfig();
  }

  void _loadExistingConfig() {
    final connectionViewModel = context.read<ConnectionViewModel>();
    final config = connectionViewModel.getConnection(widget.editId!);
    if (config == null) return;

    _nameController.text = config.name;
    _hostController.text = config.host;
    _portController.text = config.port.toString();
    _usernameController.text = config.username;
    _authMethod = config.authMethod;
    _launchMode = config.launchMode;
    _serverPlatform = config.serverPlatform;
    if (_serverPlatform == ServerPlatform.windows &&
        _launchMode == TerminalLaunchMode.tmux) {
      _launchMode = TerminalLaunchMode.ssh;
    }
    _keepAlive = config.keepAlive;
    _tmuxAutoDeleteController.text = _secondsToDisplayMinutes(
      config.tmuxAutoDeleteSeconds,
    ).toString();
    _jumpHostController.text = config.jumpHost ?? '';
    _jumpPortController.text = config.jumpPort?.toString() ?? '22';
    _jumpUsernameController.text = config.jumpUsername ?? '';

    _jumpHostExpanded = config.jumpHost != null && config.jumpHost!.isNotEmpty;
    final minutes = _secondsToDisplayMinutes(config.tmuxAutoDeleteSeconds);
    _advancedOptionsExpanded =
        config.serverPlatform != ServerPlatform.linux ||
        config.launchMode != TerminalLaunchMode.tmux ||
        !config.keepAlive ||
        minutes != 10;

    _loadSecrets(config.id);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _credentialEditor?.removeListener(_credentialStateChanged);
    _credentialEditor?.dispose();
    _appliedCredentials = null;
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _privateKeyController.dispose();
    _jumpHostController.dispose();
    _jumpPortController.dispose();
    _jumpUsernameController.dispose();
    _tmuxAutoDeleteController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((_credentialEditor?.isProtected == true ||
            _credentialEditor?.isBusy == true) &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached)) {
      _credentialEditor?.lock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings(context);
    final colorScheme = Theme.of(context).colorScheme;
    final isSaving = context.select<ConnectionViewModel, bool>(
      (vm) => vm.isSaving,
    );

    final isDesktop = connectionIsDesktopLayout(context);
    final mobileMetrics = connectionMobileUiMetricsOf(context);
    final layoutScale = isDesktop ? 1.0 : mobileMetrics.controlScale;
    final outerPadding = isDesktop
        ? ConnectionUiTokens.pagePadding
        : 16 * mobileMetrics.chromeScale;
    final cardPadding = EdgeInsets.all(20 * layoutScale);
    final sectionGap = 14 * layoutScale;

    final portAndUserRow = isDesktop
        ? Row(
            children: [
              Expanded(flex: 2, child: _buildPortField(strings)),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: _buildUsernameField(strings)),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPortField(strings),
              const SizedBox(height: 12),
              _buildUsernameField(strings),
            ],
          );

    final jumpPortAndUserRow = isDesktop
        ? Row(
            children: [
              Expanded(flex: 2, child: _buildJumpPortField(strings)),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: _buildJumpUsernameField(strings)),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildJumpPortField(strings),
              const SizedBox(height: 12),
              _buildJumpUsernameField(strings),
            ],
          );

    final stickyActionBar = Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.8),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            outerPadding,
            10 * layoutScale,
            outerPadding,
            12 * layoutScale,
          ),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  key: const ValueKey('connection-save-button'),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        ConnectionUiTokens.radiusSmall,
                      ),
                    ),
                    elevation: 0,
                  ),
                  onPressed:
                      isSaving ||
                          _isLoadingSecrets ||
                          _credentialsLocked ||
                          _credentialEditor?.canSubmit == false
                      ? null
                      : _save,
                  icon: isSaving
                      ? const AppLoadingIndicator(
                          size: 18,
                          strokeWidth: 2,
                          color: Colors.white,
                        )
                      : const Icon(Icons.verified_outlined, size: 20),
                  label: Text(
                    isSaving ? strings.saving : strings.verifyAndSave,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final jumpHostSubtitle = !_jumpHostExpanded
        ? (_jumpHostController.text.isNotEmpty
              ? _jumpHostController.text
              : strings.notConfigured)
        : null;

    final advancedOptionsSubtitle = !_advancedOptionsExpanded
        ? strings.advancedOptionsSummary
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? strings.editConnection : strings.addConnection),
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: stickyActionBar,
      ),
      body: ConnectionPageSurface(
        child: Form(
          key: _formKey,
          child: AppSkeletonizer(
            enabled: _isLoadingSecrets,
            semanticsLabel: isEditing
                ? strings.editConnection
                : strings.addConnection,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView(
                  physics: _isLoadingSecrets
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  padding: EdgeInsets.fromLTRB(
                    outerPadding,
                    14 * layoutScale,
                    outerPadding,
                    24 * layoutScale,
                  ),
                  children: [
                    // 顶部 Header Banner
                    Padding(
                      padding: EdgeInsets.only(bottom: sectionGap + 2),
                      child: ConnectionPageHeader(
                        title: isEditing
                            ? strings.editConnection
                            : strings.addConnection,
                        subtitle: isEditing
                            ? strings.editSubtitle
                            : strings.addSubtitle,
                        icon: isEditing
                            ? Icons.edit_note_rounded
                            : Icons.dns_rounded,
                      ),
                    ),

                    // 基础信息分组
                    Padding(
                      padding: EdgeInsets.only(bottom: sectionGap),
                      child: ConnectionSectionCard(
                        title: strings.basicInfo,
                        icon: Icons.badge_outlined,
                        padding: cardPadding,
                        contentGap: 12 * layoutScale,
                        child: _buildNameField(strings),
                      ),
                    ),

                    // 连接信息分组
                    Padding(
                      padding: EdgeInsets.only(bottom: sectionGap),
                      child: ConnectionSectionCard(
                        title: strings.connectionInfo,
                        icon: Icons.lan_outlined,
                        padding: cardPadding,
                        contentGap: 12 * layoutScale,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildHostField(strings),
                            const SizedBox(height: 12),
                            portAndUserRow,
                          ],
                        ),
                      ),
                    ),

                    // 认证信息分组
                    Padding(
                      padding: EdgeInsets.only(bottom: sectionGap),
                      child: ConnectionSectionCard(
                        title: strings.authMethod,
                        icon: Icons.shield_outlined,
                        padding: cardPadding,
                        contentGap: 12 * layoutScale,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!_credentialsLocked) ...[
                              _buildAuthMethodSelector(strings, colorScheme),
                              const SizedBox(height: 12),
                              if (_authMethod == AuthMethod.password ||
                                  _authMethod == AuthMethod.both) ...[
                                _buildPasswordField(strings),
                                const SizedBox(height: 12),
                              ],
                              if (_authMethod == AuthMethod.privateKey ||
                                  _authMethod == AuthMethod.both) ...[
                                _buildPrivateKeyField(strings),
                                const SizedBox(height: 12),
                              ],
                            ],
                            if (_credentialEditor != null)
                              _buildCredentialProtection(
                                strings,
                                isSaving: isSaving,
                              ),
                          ],
                        ),
                      ),
                    ),

                    // 跳板机分组（默认折叠）
                    Padding(
                      padding: EdgeInsets.only(bottom: sectionGap),
                      child: ConnectionSectionCard(
                        title: strings.jumpHostOptional,
                        subtitle: jumpHostSubtitle,
                        icon: Icons.hub_outlined,
                        padding: cardPadding,
                        contentGap: 12 * layoutScale,
                        expanded: _jumpHostExpanded,
                        onHeaderTap: () => setState(
                          () => _jumpHostExpanded = !_jumpHostExpanded,
                        ),
                        child: _jumpHostExpanded
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildJumpHostField(strings),
                                  const SizedBox(height: 12),
                                  jumpPortAndUserRow,
                                ],
                              )
                            : null,
                      ),
                    ),

                    // 高级选项分组（默认折叠）
                    Padding(
                      padding: EdgeInsets.only(bottom: sectionGap),
                      child: ConnectionSectionCard(
                        title: strings.advancedOptions,
                        subtitle: advancedOptionsSubtitle,
                        icon: Icons.tune_rounded,
                        padding: cardPadding,
                        contentGap: 12 * layoutScale,
                        expanded: _advancedOptionsExpanded,
                        onHeaderTap: () => setState(
                          () => _advancedOptionsExpanded =
                              !_advancedOptionsExpanded,
                        ),
                        child: _advancedOptionsExpanded
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildServerPlatformSelector(strings),
                                  const SizedBox(height: 16),
                                  _buildLaunchModeSelector(strings),
                                  if (_launchMode ==
                                      TerminalLaunchMode.tmux) ...[
                                    const SizedBox(height: 12),
                                    _buildTmuxAutoDeleteField(strings),
                                  ],
                                  const SizedBox(height: 12),
                                  _buildKeepAliveSwitch(strings),
                                ],
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
