part of 'add_edit_screen.dart';

/// 路由只管理编辑明文与监听；保护状态和认证由注入控制器处理。
extension _AddEditCredentials on _AddEditScreenState {
  Future<void> _loadSecrets(String id) async {
    _updateState(() => _isLoadingSecrets = true);
    final editor = context.read<ConnectionViewModel>().createCredentialEditor(
      id,
    );
    _credentialEditor = editor;
    editor.addListener(_credentialStateChanged);
    await editor.initialize();
    if (!mounted) return;
    _updateState(() => _isLoadingSecrets = false);
  }

  void _credentialStateChanged() {
    if (!mounted) return;
    final editor = _credentialEditor!;
    final pair = editor.credentials;
    if (pair == null) {
      // 锁定和失败都清除路由明文，不依赖 pair 身份或保护状态是否刚改变。
      _appliedCredentials = null;
      _passwordController.clear();
      _privateKeyController.clear();
    } else if (!identical(pair, _appliedCredentials)) {
      _appliedCredentials = pair;
      _passwordController.text = pair.password ?? '';
      _privateKeyController.text = pair.privateKey ?? '';
    }
    _updateState(() {});
  }

  bool get _credentialsLocked =>
      _credentialEditor?.isProtected == true &&
      _credentialEditor?.credentials == null;

  Widget _buildCredentialProtection(
    ConnectionStrings strings, {
    required bool isSaving,
  }) {
    final editor = _credentialEditor!;
    return AnimatedBuilder(
      animation: Listenable.merge([_passwordController, _privateKeyController]),
      builder: (context, _) {
        final pair = editor.credentials;
        final dirty =
            pair != null &&
            (_passwordController.text != (pair.password ?? '') ||
                _privateKeyController.text != (pair.privateKey ?? ''));
        return ConnectionCredentialProtection(
          editor: editor,
          isEnglish: strings.isEnglish,
          isSaving: isSaving,
          hasUnsavedCredentials: dirty,
        );
      },
    );
  }
}
