part of 'add_edit_screen.dart';

extension _AddEditActions on _AddEditScreenState {
  Future<void> _save() async {
    final editor = _credentialEditor;
    if (_isLoadingSecrets || editor?.canSubmit == false) {
      if (editor?.isAccessCurrent == false) editor?.lock();
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final accessLease = editor?.captureSubmissionAccess();

    final connectionViewModel = context.read<ConnectionViewModel>();
    final uiAdapter = context.read<ConnectionUiAdapter?>();

    ConnectionConfig? config;
    try {
      final effectiveLaunchMode = _serverPlatform == ServerPlatform.windows
          ? TerminalLaunchMode.ssh
          : _launchMode;
      final existing = isEditing
          ? connectionViewModel.getConnection(widget.editId!)
          : null;
      final host = _hostController.text.trim();
      final port = int.parse(_portController.text.trim());
      final keepHostKeyTrust =
          existing != null && existing.host == host && existing.port == port;
      config = ConnectionConfig(
        id: isEditing ? widget.editId! : const Uuid().v4(),
        name: _nameController.text.trim(),
        host: host,
        port: port,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        privateKey: _privateKeyController.text,
        authMethod: _authMethod,
        launchMode: effectiveLaunchMode,
        serverPlatform: _serverPlatform,
        tmuxAutoDeleteSeconds: _tmuxAutoDeleteSecondsFromInput(),
        keepAlive: _keepAlive,
        hostKeyFingerprint: keepHostKeyTrust
            ? existing.hostKeyFingerprint
            : null,
        hostKeyAlgorithm: keepHostKeyTrust ? existing.hostKeyAlgorithm : null,
        hostKeyTrustedAt: keepHostKeyTrust ? existing.hostKeyTrustedAt : null,
        jumpHost: _jumpHostController.text.isNotEmpty
            ? _jumpHostController.text.trim()
            : null,
        jumpPort: _jumpPortController.text.isNotEmpty
            ? int.tryParse(_jumpPortController.text.trim())
            : null,
        jumpUsername: _jumpUsernameController.text.isNotEmpty
            ? _jumpUsernameController.text.trim()
            : null,
      );

      final success = await connectionViewModel.verifyAndSaveConnection(
        config: config,
        isEditing: isEditing,
        rawPassword: _passwordController.text,
        rawPrivateKey: _privateKeyController.text,
        expectedCredentialRevision: _credentialEditor?.revision,
        isCredentialAccessCurrent: () =>
            mounted && (accessLease?.call() ?? true),
        confirmDisconnectCallback: _confirmDisconnectActiveWindows,
        onUnknownHostKey: uiAdapter == null
            ? null
            : (request) => uiAdapter.confirmHostKey(context, request),
      );

      if (success && mounted) {
        Navigator.pop(context, config.id);
      }
    } catch (e, stackTrace) {
      uiAdapter?.logSaveFailure(
        error: e,
        stackTrace: stackTrace,
        config: config,
      );
      if (mounted) {
        await _showSaveError(e);
      }
    }
  }

  Future<void> _showSaveError(Object error) async {
    final strings = _strings(context);
    final guidance = strings.saveFailedGuidance;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.save),
        content: Text(
          '${strings.saveFailed(error)}\n\n'
          '$guidance',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDisconnectActiveWindows(int windowCount) async {
    final strings = _strings(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.saveWillCloseWindowsTitle),
        content: Text(strings.saveWillCloseWindowsContent(windowCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(strings.saveAndDisconnect),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
