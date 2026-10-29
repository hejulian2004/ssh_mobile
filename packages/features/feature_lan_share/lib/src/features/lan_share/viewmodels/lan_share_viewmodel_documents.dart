part of 'lan_share_viewmodel.dart';

extension LanShareDocumentCommands on LanShareViewModel {
  /// 先把文档完整复制进沙箱，再调用现有的单文件发送。
  Future<NetworkResult<TransferSession>> sendDocument({
    required String peerId,
    required LanDocumentSource source,
    LanDiscoveredPeer? discovery,
    int maxBytes = LanDocumentLimits.maxSendBytes,
  }) {
    final generation = _lifecycleGeneration;
    final operation = LanDocumentExchange(storageService).sendFromDocument(
      source: source,
      maxBytes: maxBytes,
      peerId: peerId,
      isCancelled: () =>
          _disposed ||
          _shutdownFuture != null ||
          generation != _lifecycleGeneration,
      sendRegularFile: (path) =>
          sendFile(peerId: peerId, filePath: path, discovery: discovery),
    );
    _trackDocumentOperation(operation, source: source);
    return operation;
  }

  /// 把沙箱里已经收到的文件分块写入用户选择的文档。
  Future<void> exportSandboxToDocument({
    required String sandboxPath,
    required LanDocumentSink sink,
  }) {
    final generation = _lifecycleGeneration;
    final operation = LanDocumentExchange(storageService).exportSandboxFile(
      source: File(sandboxPath),
      sink: sink,
      isCancelled: () =>
          _disposed ||
          _shutdownFuture != null ||
          generation != _lifecycleGeneration,
    );
    _trackDocumentOperation(operation, sink: sink);
    return operation;
  }

  void _trackDocumentOperation<T>(
    Future<T> operation, {
    LanDocumentSource? source,
    LanDocumentSink? sink,
  }) {
    if (source != null) _documentSources.add(source);
    if (sink != null) _documentSinks.add(sink);
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _documentOperations.add(settled);
    unawaited(
      settled.then((_) {
        _documentSources.remove(source);
        _documentSinks.remove(sink);
        _documentOperations.remove(settled);
      }),
    );
  }

  Future<void> _cancelDocumentOperations() async {
    Object? firstError;
    Future<void> close(Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        firstError ??= error;
      }
    }

    await Future.wait([
      for (final source in _documentSources.toList()) close(source.close),
      for (final sink in _documentSinks.toList()) close(sink.abort),
    ]);
    await Future.wait(_documentOperations.toList());
    if (firstError != null) throw firstError!;
  }
}
