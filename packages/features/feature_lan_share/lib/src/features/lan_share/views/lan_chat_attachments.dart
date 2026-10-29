part of 'lan_chat_screen.dart';

/// Owns attachment selection, document handoff, and send failure presentation.
extension _LanChatAttachments on _LanChatScreenState {
  LanDocumentAccessPort? _documentPort(BuildContext context) {
    try {
      return Provider.of<LanDocumentAccessPort>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _pickAndSend({
    required BuildContext sheetContext,
    required BuildContext context,
    required LanShareStrings strings,
    required LanShareViewModel vm,
    required String peerId,
    required LanDiscoveredPeer? device,
    required String mimeType,
    required FileType? fileType,
    required String englishFailure,
    required String chineseFailure,
  }) async {
    Navigator.pop(sheetContext);
    final documents = _documentPort(context);
    if (documents != null && documents.usesSystemDocuments) {
      try {
        final source = await documents.openForRead(
          mimeType: mimeType,
          maxBytes: LanDocumentLimits.maxSendBytes,
        );
        if (source == null) return;
        if (!context.mounted) {
          await source.close();
          return;
        }
        final result = await lanUiIgnored(
          vm.sendDocument(peerId: peerId, source: source, discovery: device),
        );
        if (result.failure != null && context.mounted) {
          _showAttachmentFailure(
            context,
            strings,
            result.failure!,
            englishFailure,
            chineseFailure,
          );
        }
      } catch (_) {
        if (!context.mounted) return;
        _showAttachmentFailureMessage(
          context,
          strings,
          englishFailure,
          chineseFailure,
        );
      }
      return;
    }

    final file = fileType == null
        ? await FilePicker.pickFile()
        : await FilePicker.pickFile(type: fileType);
    if (file == null || file.path == null || !context.mounted) return;
    final result = await lanUiIgnored(
      vm.sendFile(peerId: peerId, filePath: file.path!, discovery: device),
    );
    if (result.failure != null && context.mounted) {
      _showAttachmentFailure(
        context,
        strings,
        result.failure!,
        englishFailure,
        chineseFailure,
      );
    }
  }

  void _showAttachmentFailure(
    BuildContext context,
    LanShareStrings strings,
    LanUiFailure failure,
    String englishFailure,
    String chineseFailure,
  ) {
    if (failure.kind == LanUiFailureKind.authenticationFailed) {
      _showE2ENotSupportedError(context, strings);
      return;
    }
    _showAttachmentFailureMessage(
      context,
      strings,
      englishFailure,
      chineseFailure,
      failure.message,
    );
  }

  void _showAttachmentFailureMessage(
    BuildContext context,
    LanShareStrings strings,
    String englishFailure,
    String chineseFailure, [
    String? detail,
  ]) {
    final suffix = detail == null || detail.isEmpty ? '' : ': $detail';
    final chineseSuffix = detail == null || detail.isEmpty ? '' : '：$detail';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          strings.isEnglish
              ? '$englishFailure$suffix'
              : '$chineseFailure$chineseSuffix',
        ),
      ),
    );
  }

  void _showAttachmentOptions(
    BuildContext context,
    LanShareStrings strings,
    LanShareViewModel vm,
    String peerId,
    LanDiscoveredPeer? device,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(strings.lanShareSelectImage),
              onTap: () => _pickAndSend(
                sheetContext: ctx,
                context: context,
                strings: strings,
                vm: vm,
                peerId: peerId,
                device: device,
                mimeType: 'image/*',
                fileType: FileType.image,
                englishFailure: 'Failed to send image',
                chineseFailure: '发送图片失败',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_rounded),
              title: Text(strings.lanShareSelectVideo),
              onTap: () => _pickAndSend(
                sheetContext: ctx,
                context: context,
                strings: strings,
                vm: vm,
                peerId: peerId,
                device: device,
                mimeType: 'video/*',
                fileType: FileType.video,
                englishFailure: 'Failed to send video',
                chineseFailure: '发送视频失败',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_rounded),
              title: Text(strings.lanShareSelectFile),
              onTap: () => _pickAndSend(
                sheetContext: ctx,
                context: context,
                strings: strings,
                vm: vm,
                peerId: peerId,
                device: device,
                mimeType: '*/*',
                fileType: null,
                englishFailure: 'Failed to send file',
                chineseFailure: '发送文件失败',
              ),
            ),

            ListTile(
              leading: const Icon(Icons.content_paste_rounded),
              title: Text(strings.lanShareClipboard),
              onTap: () async {
                Navigator.pop(ctx);
                if (device == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        strings.isEnglish
                            ? 'Clipboard sync requires direct local network.'
                            : '剪贴板同步暂不支持中继传输，需处于同一局域网。',
                      ),
                    ),
                  );
                  return;
                }
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data != null &&
                    data.text != null &&
                    data.text!.isNotEmpty) {
                  final result = await lanUiIgnored(
                    vm.sendClipboard(device, data.text!),
                  );
                  if (result.failure?.kind ==
                          LanUiFailureKind.authenticationFailed &&
                      context.mounted) {
                    _showE2ENotSupportedError(context, strings);
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
