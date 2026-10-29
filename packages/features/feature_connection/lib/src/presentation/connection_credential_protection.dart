import 'package:connection_core/connection_core.dart';
import 'package:flutter/material.dart';

import '../application/connection_credential_editor.dart';
import 'connection_protection_strings.dart';

/// 编辑页现有认证分组内的保护控件，只向路由控制器发送显式用户操作。
final class ConnectionCredentialProtection extends StatelessWidget {
  const ConnectionCredentialProtection({
    super.key,
    required this.editor,
    required this.isEnglish,
    this.hasUnsavedCredentials = false,
    this.isSaving = false,
  });
  final ConnectionCredentialEditor editor;
  final bool isEnglish;
  final bool hasUnsavedCredentials;
  final bool isSaving;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: editor,
    builder: (context, _) {
      final strings = ConnectionProtectionStrings(isEnglish: isEnglish);
      if (!editor.supportsProtection &&
          !editor.isProtected &&
          editor.error == null) {
        return const SizedBox.shrink();
      }
      final unlocked = editor.credentials != null;
      // 保存中的 original → staged 结构变化由 VM 拥有，UI 不重新判作外部变更。
      final current = isSaving || editor.isAccessCurrent;
      final error = current ? editor.error : CredentialProtectionError.stale;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('credential-protection-switch'),
            contentPadding: EdgeInsets.zero,
            title: Text(strings.title),
            subtitle: Text(strings.help),
            value: editor.isProtected,
            onChanged:
                isSaving ||
                    editor.isBusy ||
                    !current ||
                    !editor.supportsProtection ||
                    hasUnsavedCredentials
                ? null
                : editor.setProtection,
          ),
          if (hasUnsavedCredentials) Text(strings.saveFirst),
          if (editor.isProtected) ...[
            Text(unlocked ? strings.unlocked : strings.locked),
            const SizedBox(height: 8),
            if (!unlocked)
              FilledButton.tonalIcon(
                key: const ValueKey('credential-unlock'),
                onPressed:
                    isSaving ||
                        editor.isBusy ||
                        !current ||
                        !editor.supportsProtection
                    ? null
                    : editor.unlock,
                icon: const Icon(Icons.fingerprint),
                label: Text(editor.isBusy ? strings.busy : strings.unlock),
              )
            else
              TextButton.icon(
                key: const ValueKey('credential-lock'),
                onPressed: isSaving || editor.isBusy ? null : editor.lock,
                icon: const Icon(Icons.lock_outline),
                label: Text(strings.lock),
              ),
            const SizedBox(height: 8),
            Text(strings.savePrompt),
          ],
          if (!editor.supportsProtection)
            Text(strings.error(CredentialProtectionError.unsupported)),
          if (error != null)
            Text(
              strings.error(error),
              key: const ValueKey('credential-protection-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
