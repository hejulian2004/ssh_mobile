import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../domain/lan_share_ports.dart';
import '../../../services/lan_share/lan_share_models.dart';
import 'package:app_ui/app_ui.dart';
import '../utils/lan_preview_safety.dart';
import '../viewmodels/lan_share_viewmodel.dart';

typedef LanPreviewFileReader =
    Future<Uint8List> Function(File file, {required int maxBytes});
typedef LanPreviewImageInspector =
    Future<LanPreviewImageMetadata> Function(Uint8List bytes);
typedef LanPreviewHtmlBuilder =
    Widget Function(
      BuildContext context,
      String sandboxedHtml, {
      required Widget loadingWidget,
      required Widget Function(BuildContext context, Object error) onError,
    });
typedef LanPreviewImageProviderBuilder =
    ImageProvider Function(Uint8List bytes, int width, int height);

enum _LanPreviewKind { image, markdown, html, text, unsupported }

class LanPreviewViewerScreen extends StatefulWidget {
  const LanPreviewViewerScreen({super.key, required this.message})
    : readBytesForTesting = null,
      imageInspectorForTesting = null,
      htmlBuilderForTesting = null,
      imageProviderBuilderForTesting = null;

  @visibleForTesting
  const LanPreviewViewerScreen.forTesting({
    super.key,
    required this.message,
    this.readBytesForTesting,
    this.imageInspectorForTesting,
    this.htmlBuilderForTesting,
    this.imageProviderBuilderForTesting,
  });

  final LanMessage message;
  @visibleForTesting
  final LanPreviewFileReader? readBytesForTesting;
  @visibleForTesting
  final LanPreviewImageInspector? imageInspectorForTesting;
  @visibleForTesting
  final LanPreviewHtmlBuilder? htmlBuilderForTesting;
  @visibleForTesting
  final LanPreviewImageProviderBuilder? imageProviderBuilderForTesting;

  @override
  State<LanPreviewViewerScreen> createState() => _LanPreviewViewerScreenState();
}

class _LanPreviewViewerScreenState extends State<LanPreviewViewerScreen> {
  late final _LanPreviewKind _kind;
  late final Future<_LanPreviewPayload> _previewFuture;

  bool get _canCopy =>
      _kind == _LanPreviewKind.text ||
      _kind == _LanPreviewKind.markdown ||
      _kind == _LanPreviewKind.html;

  bool get _supportsHtmlPreview {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  void initState() {
    super.initState();
    _kind = _previewKind(widget.message);
    _previewFuture = _loadPreview();
  }

  Future<_LanPreviewPayload> _loadPreview() async {
    final message = widget.message;
    if (message.payloadType == LanPayloadType.text ||
        message.payloadType == LanPayloadType.clipboard) {
      final text = message.textContent ?? '';
      if (!lanPreviewUtf8WithinLimit(text, lanPreviewTextLimitBytes)) {
        throw const LanPreviewTooLargeException(lanPreviewTextLimitBytes);
      }
      return _LanPreviewPayload.text(text);
    }

    if (_kind == _LanPreviewKind.unsupported) {
      return const _LanPreviewPayload.unsupported();
    }

    final path = message.localPath;
    if (path == null || path.isEmpty) {
      throw const _LanPreviewMissingException();
    }
    final file = File(path);
    if (!await file.exists()) {
      throw const _LanPreviewMissingException();
    }

    final maxBytes = _kind == _LanPreviewKind.image
        ? lanPreviewImageLimitBytes
        : lanPreviewTextLimitBytes;
    if (message.fileSize > maxBytes) {
      throw LanPreviewTooLargeException(maxBytes);
    }

    final bytes =
        await (widget.readBytesForTesting ?? readLanPreviewFileBounded)(
          file,
          maxBytes: maxBytes,
        );
    if (bytes.length > maxBytes) {
      throw LanPreviewTooLargeException(maxBytes);
    }

    if (_kind == _LanPreviewKind.image) {
      final metadata =
          await (widget.imageInspectorForTesting ?? inspectLanPreviewImage)(
            bytes,
          );
      if (!lanPreviewImageMetadataWithinBudget(
        metadata.width,
        metadata.height,
        metadata.frameCount,
      )) {
        throw const LanPreviewResourceLimitException();
      }
      return _LanPreviewPayload.image(bytes, metadata);
    }

    final text = await compute(decodeLanPreviewUtf8, bytes);
    return _LanPreviewPayload.text(text);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<LanShareSettingsPort>();
    final strings = settings.strings;

    return Scaffold(
      body: SafeArea(
        child: AppPageSurface(
          child: Column(
            children: [
              AppPageHeader(
                title: widget.message.fileName ?? strings.lanShare,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.message.localPath?.isNotEmpty == true)
                      IconButton(
                        icon: const Icon(Icons.download_rounded),
                        tooltip: strings.lanShareExport,
                        onPressed: () => _exportFile(context, strings),
                      ),
                    if (_canCopy)
                      IconButton(
                        icon: const Icon(Icons.copy_rounded),
                        tooltip: strings.copy,
                        onPressed: () => _copyPreview(context, strings),
                      ),
                    const CloseButton(),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<_LanPreviewPayload>(
                  future: _previewFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return _PreviewLoading(strings: strings);
                    }
                    if (snapshot.hasError) {
                      return _buildError(strings, snapshot.error!);
                    }
                    return _buildPayload(context, strings, snapshot.data!);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPayload(
    BuildContext context,
    LanShareStrings strings,
    _LanPreviewPayload payload,
  ) {
    switch (_kind) {
      case _LanPreviewKind.image:
        return _LanImagePreview(
          bytes: payload.bytes!,
          metadata: payload.imageMetadata!,
          strings: strings,
          providerBuilderForTesting: widget.imageProviderBuilderForTesting,
        );
      case _LanPreviewKind.markdown:
        return _LanMarkdownPreview(text: payload.text!, strings: strings);
      case _LanPreviewKind.html:
        return _buildHtmlPreview(context, strings, payload.text!);
      case _LanPreviewKind.text:
        return _LanTextPreview(text: payload.text!);
      case _LanPreviewKind.unsupported:
        return AppEmptyState(
          icon: Icons.insert_drive_file_outlined,
          title: strings.unsupportedPreviewTitle,
          message: strings.unsupportedPreview,
        );
    }
  }

  Widget _buildHtmlPreview(
    BuildContext context,
    LanShareStrings strings,
    String html,
  ) {
    if (!_supportsHtmlPreview) {
      return Column(
        children: [
          MaterialBanner(
            content: Text(
              '${strings.htmlPreviewUnavailable}. '
              '${strings.htmlPreviewUnavailableHint}',
            ),
            actions: const [SizedBox.shrink()],
          ),
          Expanded(child: _LanTextPreview(text: html)),
        ],
      );
    }

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final sandboxedHtml = buildLanPreviewSandboxedHtml(
      html,
      brightness: theme.brightness,
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      linkColor: colors.primary,
      codeBackgroundColor: colors.surfaceContainerHighest,
    );
    final loadingWidget = _PreviewLoading(strings: strings);
    Widget errorBuilder(BuildContext context, Object error) {
      return AppEmptyState(
        icon: Icons.broken_image_outlined,
        title: strings.filePreviewRenderFailed,
        message: strings.filePreviewRenderFailedHint,
      );
    }

    final builder = widget.htmlBuilderForTesting;
    return KeyedSubtree(
      key: const ValueKey('lan-preview-html'),
      child: builder == null
          ? _SecureLanHtmlPreview(
              sandboxedHtml: sandboxedHtml,
              backgroundColor: colors.surface,
              loadingWidget: loadingWidget,
              errorBuilder: errorBuilder,
            )
          : builder(
              context,
              sandboxedHtml,
              loadingWidget: loadingWidget,
              onError: errorBuilder,
            ),
    );
  }

  Widget _buildError(LanShareStrings strings, Object error) {
    if (error is LanPreviewTooLargeException) {
      return AppEmptyState(
        key: const ValueKey('lan-preview-too-large'),
        icon: Icons.data_usage_rounded,
        title: strings.filePreviewTooLarge,
        message: strings.filePreviewTooLargeHint(error.maxBytes),
      );
    }
    if (error is LanPreviewResourceLimitException) {
      return AppEmptyState(
        key: const ValueKey('lan-preview-resource-limit'),
        icon: Icons.image_not_supported_outlined,
        title: strings.filePreviewResourceLimit,
        message: strings.filePreviewResourceLimitHint,
      );
    }
    if (error is _LanPreviewMissingException) {
      return AppEmptyState(
        key: const ValueKey('lan-preview-missing'),
        icon: Icons.hourglass_disabled_outlined,
        title: strings.lanShareFileExpired,
        message: strings.unsupportedPreview,
      );
    }
    return AppEmptyState(
      key: const ValueKey('lan-preview-load-failed'),
      icon: Icons.broken_image_outlined,
      title: strings.filePreviewRenderFailed,
      message: strings.filePreviewRenderFailedHint,
    );
  }

  Future<void> _copyPreview(
    BuildContext context,
    LanShareStrings strings,
  ) async {
    try {
      final payload = await _previewFuture;
      final text = payload.text;
      if (text == null || text.isEmpty || !context.mounted) return;
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.copy)));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.filePreviewRenderFailed)));
    }
  }

  Future<void> _exportFile(
    BuildContext context,
    LanShareStrings strings,
  ) async {
    final path = widget.message.localPath;
    if (path == null) return;

    final documents = _documentPort(context);
    if (documents != null && documents.usesSystemDocuments) {
      await _exportSystemDocument(
        context,
        strings,
        path,
        documents,
        fileName: widget.message.fileName,
        payloadType: widget.message.payloadType,
      );
      return;
    }

    final storageService = context.read<LanShareViewModel>().storageService;
    final success = await storageService.exportToPublic(
      path,
      widget.message.payloadType,
    );

    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (success) {
      final message = widget.message.payloadType == LanPayloadType.image
          ? strings.lanShareSavedToGallery
          : strings.lanShareSavedToDownloads;
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(strings.lanShareSaveFailed)),
      );
    }
  }
}

LanDocumentAccessPort? _documentPort(BuildContext context) {
  try {
    return Provider.of<LanDocumentAccessPort>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

Future<void> _exportSystemDocument(
  BuildContext context,
  LanShareStrings strings,
  String path,
  LanDocumentAccessPort documents, {
  required String? fileName,
  required LanPayloadType payloadType,
}) async {
  final mime = switch (payloadType) {
    LanPayloadType.image => 'image/*',
    LanPayloadType.video => 'video/*',
    _ => 'application/octet-stream',
  };
  try {
    final sink = await documents.createForWrite(
      suggestedName: fileName ?? 'download',
      mimeType: mime,
    );
    if (sink == null) return;
    if (!context.mounted) {
      await sink.abort();
      return;
    }
    await context.read<LanShareViewModel>().exportSandboxToDocument(
      sandboxPath: path,
      sink: sink,
    );
    if (!context.mounted) return;
    final saved = LanDocumentStrings(isEnglish: strings.isEnglish).saved;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(saved)));
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.lanShareSaveFailed)));
  }
}

class _LanPreviewPayload {
  const _LanPreviewPayload._({this.bytes, this.text, this.imageMetadata});

  const _LanPreviewPayload.text(String text) : this._(text: text);

  const _LanPreviewPayload.image(
    Uint8List bytes,
    LanPreviewImageMetadata metadata,
  ) : this._(bytes: bytes, imageMetadata: metadata);

  const _LanPreviewPayload.unsupported() : this._();

  final Uint8List? bytes;
  final String? text;
  final LanPreviewImageMetadata? imageMetadata;
}

class _LanPreviewMissingException implements Exception {
  const _LanPreviewMissingException();
}

class _PreviewLoading extends StatelessWidget {
  const _PreviewLoading({required this.strings});

  final LanShareStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppSkeletonizer.zone(
      key: const ValueKey('lan-preview-loading'),
      enabled: true,
      semanticsLabel: strings.loadingFilePreview,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Document Card
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const AppIconBadge(
                      icon: Icons.description_outlined,
                      size: 40,
                      iconSize: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'preview_document.md',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Markdown Document · 8.4 KB',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Document body lines / paragraphs
            Expanded(
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '# Project Documentation & Architecture Overview',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'This document outlines the core architecture components, domain services, and runtime configuration rules for cross-platform network communication.',
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusSmall,
                          ),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '// Initialize local transport socket',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'final transport = await LanTransport.bind(port: 8443);',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'await transport.listenAndServe();',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'The secure peer handshake uses ephemeral certificates signed by local keypairs to guarantee mutual identity authentication.',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanTextPreview extends StatelessWidget {
  const _LanTextPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          fontSize: 14,
          height: 1.5,
        ),
      ),
    );
  }
}

class _LanMarkdownPreview extends StatelessWidget {
  const _LanMarkdownPreview({required this.text, required this.strings});

  final String text;
  final LanShareStrings strings;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const ValueKey('lan-preview-markdown'),
      padding: const EdgeInsets.all(16),
      child: SelectionArea(
        child: GptMarkdown(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
          textDirection: Directionality.of(context),
          inlineComponents: _safeMarkdownInlineComponents,
          imageBuilder: (context, imageUrl, width, height) {
            return Semantics(
              label: strings.externalPreviewContentBlocked,
              child: Tooltip(
                message: strings.externalPreviewContentBlocked,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.image_not_supported_outlined),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

final List<MarkdownComponent> _safeMarkdownInlineComponents =
    List<MarkdownComponent>.unmodifiable(
      MarkdownComponent.inlineComponents.where(
        (component) => component is! ATagMd,
      ),
    );

class _LanImagePreview extends StatelessWidget {
  const _LanImagePreview({
    required this.bytes,
    required this.metadata,
    required this.strings,
    this.providerBuilderForTesting,
  });

  final Uint8List bytes;
  final LanPreviewImageMetadata metadata;
  final LanShareStrings strings;
  final LanPreviewImageProviderBuilder? providerBuilderForTesting;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pixelRatio = MediaQuery.devicePixelRatioOf(context);
        final logicalWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 2048.0;
        final logicalHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 2048.0;
        final targetSize = boundedLanPreviewPixelSize(
          metadata.size,
          maxWidth: math.min(4096, logicalWidth * pixelRatio * 2),
          maxHeight: math.min(4096, logicalHeight * pixelRatio * 2),
        );
        final targetWidth = targetSize.width.round();
        final targetHeight = targetSize.height.round();
        final provider =
            providerBuilderForTesting?.call(bytes, targetWidth, targetHeight) ??
            ResizeImage(
              MemoryImage(bytes),
              width: targetWidth,
              height: targetHeight,
              policy: ResizeImagePolicy.fit,
            );
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            child: Image(
              image: provider,
              semanticLabel: strings.imagePreviewLabel,
              filterQuality: FilterQuality.medium,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => AppEmptyState(
                icon: Icons.broken_image_outlined,
                title: strings.filePreviewRenderFailed,
                message: strings.filePreviewRenderFailedHint,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SecureLanHtmlPreview extends StatefulWidget {
  const _SecureLanHtmlPreview({
    required this.sandboxedHtml,
    required this.backgroundColor,
    required this.loadingWidget,
    required this.errorBuilder,
  });

  final String sandboxedHtml;
  final Color backgroundColor;
  final Widget loadingWidget;
  final Widget Function(BuildContext context, Object error) errorBuilder;

  @override
  State<_SecureLanHtmlPreview> createState() => _SecureLanHtmlPreviewState();
}

class _SecureLanHtmlPreviewState extends State<_SecureLanHtmlPreview> {
  late final Future<WebViewController> _controllerFuture;
  Object? _mainFrameError;

  @override
  void initState() {
    super.initState();
    _controllerFuture = _createController();
  }

  Future<WebViewController> _createController() async {
    final controller = WebViewController(
      onPermissionRequest: (request) => unawaited(request.deny()),
    );
    await controller.setJavaScriptMode(JavaScriptMode.disabled);
    await controller.setBackgroundColor(widget.backgroundColor);
    await controller.enableZoom(true);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) =>
            lanPreviewNavigationAllowed(request.url)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onWebResourceError: (error) {
          if (error.isForMainFrame == false || !mounted) return;
          setState(() => _mainFrameError = error);
        },
      ),
    );
    await controller.loadHtmlString(widget.sandboxedHtml);
    return controller;
  }

  @override
  Widget build(BuildContext context) {
    final mainFrameError = _mainFrameError;
    if (mainFrameError != null) {
      return widget.errorBuilder(context, mainFrameError);
    }
    return FutureBuilder<WebViewController>(
      future: _controllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loadingWidget;
        }
        if (snapshot.hasError) {
          return widget.errorBuilder(context, snapshot.error!);
        }
        return WebViewWidget(controller: snapshot.data!);
      },
    );
  }
}

_LanPreviewKind _previewKind(LanMessage message) {
  if (message.payloadType == LanPayloadType.text ||
      message.payloadType == LanPayloadType.clipboard) {
    return _LanPreviewKind.text;
  }
  if (message.payloadType == LanPayloadType.image) {
    return _LanPreviewKind.image;
  }

  final lower = message.fileName?.toLowerCase() ?? '';
  if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
    return _LanPreviewKind.markdown;
  }
  if (lower.endsWith('.html') || lower.endsWith('.htm')) {
    return _LanPreviewKind.html;
  }
  if (lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp')) {
    return _LanPreviewKind.image;
  }
  if (lower.endsWith('.txt') ||
      lower.endsWith('.log') ||
      lower.endsWith('.json') ||
      lower.endsWith('.yaml') ||
      lower.endsWith('.yml') ||
      lower.endsWith('.toml') ||
      lower.endsWith('.xml') ||
      lower.endsWith('.csv') ||
      lower.endsWith('.ini') ||
      lower.endsWith('.conf') ||
      lower.endsWith('.properties') ||
      lower.endsWith('.sh') ||
      lower.endsWith('.bash') ||
      lower.endsWith('.zsh') ||
      lower.endsWith('.ps1') ||
      lower.endsWith('.bat') ||
      lower.endsWith('.cmd') ||
      lower.endsWith('.py') ||
      lower.endsWith('.rb') ||
      lower.endsWith('.go') ||
      lower.endsWith('.rs') ||
      lower.endsWith('.java') ||
      lower.endsWith('.kt') ||
      lower.endsWith('.swift') ||
      lower.endsWith('.c') ||
      lower.endsWith('.h') ||
      lower.endsWith('.cpp') ||
      lower.endsWith('.hpp') ||
      lower.endsWith('.js') ||
      lower.endsWith('.ts') ||
      lower.endsWith('.css') ||
      lower.endsWith('.sql') ||
      lower.endsWith('.dart')) {
    return _LanPreviewKind.text;
  }
  return _LanPreviewKind.unsupported;
}
