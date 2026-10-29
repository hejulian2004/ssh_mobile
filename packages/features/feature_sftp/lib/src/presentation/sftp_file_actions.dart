part of 'sftp_screen.dart';

extension _SftpFilePaneActions on _FilePane {
  Future<void> _uploadFile(BuildContext context) async {
    final sftp = context.read<SftpViewModel>();
    final settings = context.read<SftpSettingsPort>();
    final strings = SftpStrings(settings.language);
    final messenger = ScaffoldMessenger.of(context);
    final documents = _systemDocuments(context);
    if (documents != null && documents.usesSystemDocuments) {
      await _uploadSystemDocument(context, sftp, strings, messenger, documents);
      return;
    }

    final file = await FilePicker.pickFile();
    if (file == null) return;

    if (file.size > SftpService.maxUploadBytes) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            strings.uploadFailed(
              strings.uploadFileTooLarge(
                _formatBytes(SftpService.maxUploadBytes),
              ),
            ),
          ),
        ),
      );
      return;
    }

    final localPath = file.path;
    if (localPath == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(strings.uploadFailed(strings.uploadFileNoAccess)),
        ),
      );
      return;
    }

    final filename = file.name.isNotEmpty ? file.name : p.basename(localPath);

    try {
      await sftp.uploadLocalFile(
        localPath: localPath,
        filename: filename,
        sizeBytes: file.size,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.uploadComplete)));
    } catch (e) {
      if (!context.mounted) return;
      if (e is SftpTransferCancelledException) {
        messenger.showSnackBar(
          SnackBar(content: Text(strings.uploadCancelled)),
        );
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text(strings.uploadFailed(e))));
    }
  }

  Future<void> _handleEntryAction(
    BuildContext context,
    String action,
    SftpEntry entry,
  ) async {
    switch (action) {
      case 'view':
        await _viewFile(context, entry);
        break;
      case 'edit':
        await _editFile(context, entry);
        break;
      case 'download':
        await _downloadFile(context, entry);
        break;
      case 'delete':
        await _confirmDelete(context, entry);
        break;
      case 'send_to_nearby':
        await _sendToNearby(context, entry);
        break;
    }
  }

  Future<void> _sendToNearby(BuildContext context, SftpEntry entry) async {
    final settings = context.read<SftpSettingsPort>();
    final strings = SftpStrings(settings.language);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.lanShareSendToNearby)));
  }

  Future<void> _viewFile(BuildContext context, SftpEntry entry) async {
    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) =>
            SharedAxisTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              transitionType: SharedAxisTransitionType.scaled,
              child: SftpFileViewerScreen(entry: entry),
            ),
      ),
    );
  }

  Future<void> _downloadFile(BuildContext context, SftpEntry entry) async {
    final settings = context.read<SftpSettingsPort>();
    final strings = SftpStrings(settings.language);
    final sftp = context.read<SftpViewModel>();
    final messenger = ScaffoldMessenger.of(context);

    if (entry.size != null && entry.size! > settings.sftpDownloadLimitBytes) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            strings.downloadFailed(
              strings.downloadFileTooLarge(
                _formatBytes(settings.sftpDownloadLimitBytes),
              ),
            ),
          ),
        ),
      );
      return;
    }

    final documents = _systemDocuments(context);
    if (documents != null && documents.usesSystemDocuments) {
      await _downloadSystemDocument(
        context,
        entry,
        sftp,
        strings,
        messenger,
        documents,
        settings.sftpDownloadLimitBytes,
      );
      return;
    }

    try {
      final savedPath = await FilePicker.saveFile(
        dialogTitle: strings.downloadFile,
        fileName: entry.name,
        bytes: Uint8List(0),
      );
      if (savedPath == null) return;

      await sftp.downloadToLocalFile(
        entry: entry,
        localPath: savedPath,
        maxBytes: settings.sftpDownloadLimitBytes,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.downloadComplete)));
    } catch (e) {
      if (!context.mounted) return;
      if (e is SftpTransferCancelledException) {
        messenger.showSnackBar(
          SnackBar(content: Text(strings.downloadCancelled)),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(strings.downloadFailed(e))),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, SftpEntry entry) async {
    final settings = context.read<SftpSettingsPort>();
    final strings = SftpStrings(settings.language);
    final sftp = context.read<SftpViewModel>();
    final nameController = TextEditingController();
    String? errorText;
    final confirmedName = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(strings.deleteRemoteEntry),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(strings.deleteRemoteEntryContent(entry.name)),
                const SizedBox(height: 14),
                Text(
                  strings.deleteRemoteEntryConfirmPrompt,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  entry.name,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: strings.deleteRemoteEntryConfirmLabel,
                    errorText: errorText,
                  ),
                  onChanged: (_) {
                    if (errorText != null) {
                      setDialogState(() => errorText = null);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(strings.cancel),
            ),
            TextButton(
              onPressed: () {
                final typedName = nameController.text;
                if (typedName != entry.name && typedName.trim() != entry.name) {
                  setDialogState(() {
                    errorText = strings.deleteRemoteEntryConfirmMismatch;
                  });
                  return;
                }
                Navigator.pop(ctx, typedName);
              },
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(strings.delete),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    if (confirmedName != null) {
      await sftp.deleteEntry(entry, confirmedName: confirmedName);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.deleteComplete)));
    }
  }

  Future<void> _editFile(BuildContext context, SftpEntry entry) async {
    await Navigator.push<bool>(
      context,
      PageRouteBuilder<bool>(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) =>
            SharedAxisTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              transitionType: SharedAxisTransitionType.scaled,
              child: SftpEditorScreen(entry: entry),
            ),
      ),
    );
  }

  Future<void> _uploadSystemDocument(
    BuildContext context,
    SftpViewModel sftp,
    SftpStrings strings,
    ScaffoldMessengerState messenger,
    SftpDocumentAccessPort documents,
  ) async {
    try {
      final target = sftp.documentUploadTarget;
      final source = await documents.openForRead(
        maxBytes: SftpService.maxUploadBytes,
      );
      if (source == null) return;
      if (!context.mounted) {
        await source.close();
        return;
      }
      await sftp.uploadFromDocument(
        source: source,
        filename: source.displayName,
        target: target,
        maxBytes: SftpService.maxUploadBytes,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.uploadComplete)));
    } on SftpFileSizeLimitException {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            strings.uploadFailed(
              strings.uploadFileTooLarge(
                _formatBytes(SftpService.maxUploadBytes),
              ),
            ),
          ),
        ),
      );
    } on SftpDocumentMissingException {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(strings.uploadFailed(strings.uploadFileNoAccess)),
        ),
      );
    } on SftpTransferCancelledException {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.uploadCancelled)));
    } catch (error) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.uploadFailed(error))),
      );
    }
  }

  Future<void> _downloadSystemDocument(
    BuildContext context,
    SftpEntry entry,
    SftpViewModel sftp,
    SftpStrings strings,
    ScaffoldMessengerState messenger,
    SftpDocumentAccessPort documents,
    int maxBytes,
  ) async {
    try {
      final sink = await documents.createForWrite(suggestedName: entry.name);
      if (sink == null) return;
      if (!context.mounted) {
        await sink.abort();
        return;
      }
      await sftp.downloadToDocument(
        entry: entry,
        sink: sink,
        maxBytes: maxBytes,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.downloadComplete)));
    } on SftpFileSizeLimitException {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            strings.downloadFailed(
              strings.downloadFileTooLarge(_formatBytes(maxBytes)),
            ),
          ),
        ),
      );
    } on SftpDocumentMissingException {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(strings.downloadFailed(strings.uploadFileNoAccess)),
        ),
      );
    } on SftpTransferCancelledException {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.downloadCancelled)),
      );
    } catch (error) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.downloadFailed(error))),
      );
    }
  }

  SftpDocumentAccessPort? _systemDocuments(BuildContext context) {
    try {
      return Provider.of<SftpDocumentAccessPort>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  String _entryMeta(SftpStrings strings, SftpEntry entry) {
    final parts = <String>[];
    parts.add(entry.isDirectory ? strings.directory : entry.sizeLabel);
    final modifiedLabel = entry.modifiedLabel;
    if (modifiedLabel != null) parts.add(modifiedLabel);
    return parts.join(' | ');
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return '-';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
  }

  void _showPathHistorySheet(
    BuildContext context,
    SftpViewModel sftp,
    String currentPath,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SftpPathHistorySheet(
        strings: strings,
        sftp: sftp,
        currentPath: currentPath,
      ),
    );
  }
}
