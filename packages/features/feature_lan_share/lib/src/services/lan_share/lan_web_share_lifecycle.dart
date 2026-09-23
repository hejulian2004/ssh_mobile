// WebShare address selection and serialized HTTPS-session commands.

part of 'lan_discovery_service.dart';

extension LanWebShareLifecycleOperations on LanDiscoveryService {
  /// Starts the WebShare HTTPS session with a currently eligible local IPv4.
  Future<NetworkResult<String>> startWebShareServer({
    int port = 53319,
    required LanSecurityService securityService,
    required LanStorageService storageService,
    required LanTransferService transferService,
  }) {
    return _enqueueWebShareLifecycle(
      () => _startWebShareServerResult(
        port: port,
        securityService: securityService,
        storageService: storageService,
        transferService: transferService,
      ),
    );
  }

  /// Updates the explicit address override and revalidates the active session.
  Future<NetworkResult<void>> updateWebShareAddressOverride(String? ip) {
    return _enqueueWebShareLifecycle(() async {
      if (_closing || _closed) {
        return _closedFailure<void>(NetworkOperation.startWebShare);
      }

      _customIp = ip;
      final selection = await _localAddressResolver.resolve(override: ip);
      _webShareAddressSelectionResult = selection;
      if (selection is! LanShareLocalAddressSelected) {
        if (_isWebShareActive ||
            _webShareServer != null ||
            _webShareUrl != null) {
          try {
            await _LanWebShareServerOperations(this)._stopWebShareServer();
          } on Object {
            return NetworkFailure<void>(
              const NetworkError(
                code: NetworkErrorCode.ioError,
                message: 'WebShare session could not be stopped.',
                operation: NetworkOperation.stopWebShare,
              ),
            );
          }
        }
        return _localAddressFailure<void>(
          selection,
          NetworkOperation.startWebShare,
        );
      }

      if (_isWebShareActive && _webShareServer != null) {
        final currentUrl = Uri.tryParse(_webShareUrl ?? '');
        if (currentUrl == null || currentUrl.host.isEmpty) {
          await _LanWebShareServerOperations(this)._stopWebShareServer();
          return NetworkFailure<void>(
            const NetworkError(
              code: NetworkErrorCode.invalidState,
              message: 'WebShare endpoint is no longer valid.',
              operation: NetworkOperation.startWebShare,
            ),
          );
        }
        _webShareUrl = currentUrl
            .replace(host: selection.candidate.address)
            .toString();
      }
      return const NetworkSuccess<void>(null);
    });
  }

  /// Stops only the WebShare HTTPS session, leaving LAN Control untouched.
  Future<NetworkResult<void>> stopWebShareServer() {
    return _enqueueWebShareLifecycle(() async {
      try {
        await _LanWebShareServerOperations(this)._stopWebShareServer();
        return const NetworkSuccess<void>(null);
      } on Object {
        return NetworkFailure<void>(
          const NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'WebShare stop failed.',
            operation: NetworkOperation.stopWebShare,
          ),
        );
      }
    });
  }

  Future<NetworkResult<String>> _startWebShareServerResult({
    required int port,
    required LanSecurityService securityService,
    required LanStorageService storageService,
    required LanTransferService transferService,
  }) async {
    if (_closing || _closed) {
      return _closedFailure<String>(NetworkOperation.startWebShare);
    }

    final selection = await _localAddressResolver.resolve(override: _customIp);
    _webShareAddressSelectionResult = selection;
    if (selection is! LanShareLocalAddressSelected) {
      if (_isWebShareActive ||
          _webShareServer != null ||
          _webShareUrl != null) {
        try {
          await _LanWebShareServerOperations(this)._stopWebShareServer();
        } on Object {
          return NetworkFailure<String>(
            const NetworkError(
              code: NetworkErrorCode.ioError,
              message: 'WebShare session could not be stopped.',
              operation: NetworkOperation.stopWebShare,
            ),
          );
        }
      }
      return _localAddressFailure<String>(
        selection,
        NetworkOperation.startWebShare,
      );
    }
    final candidate = selection.candidate;

    if (_isWebShareActive && _webShareServer != null) {
      final currentUrl = Uri.tryParse(_webShareUrl ?? '');
      if (currentUrl == null || currentUrl.host.isEmpty) {
        await _LanWebShareServerOperations(this)._stopWebShareServer();
      } else {
        final updatedUrl = currentUrl
            .replace(host: candidate.address)
            .toString();
        _webShareUrl = updatedUrl;
        return NetworkSuccess<String>(updatedUrl);
      }
    }

    try {
      final url = await _LanWebShareServerOperations(this)._startWebShareServer(
        port: port,
        hostIp: candidate.address,
        securityService: securityService,
        storageService: storageService,
        transferService: transferService,
      );
      if (_closing || _closed) {
        await _LanWebShareServerOperations(this)._stopWebShareServer();
        return _closedFailure<String>(NetworkOperation.startWebShare);
      }
      if (url == null || url.isEmpty) {
        return NetworkFailure<String>(
          const NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'WebShare did not provide an endpoint.',
            operation: NetworkOperation.startWebShare,
          ),
        );
      }
      return NetworkSuccess<String>(url);
    } on Object {
      return NetworkFailure<String>(
        const NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'WebShare start failed.',
          operation: NetworkOperation.startWebShare,
        ),
      );
    }
  }

  NetworkFailure<T> _localAddressFailure<T>(
    LanShareLocalAddressSelectionResult result,
    NetworkOperation operation,
  ) {
    final code = switch (result) {
      LanShareLocalAddressStaleOverride() => NetworkErrorCode.invalidState,
      _ => NetworkErrorCode.configuration,
    };
    return NetworkFailure<T>(
      NetworkError(
        code: code,
        message: 'No unambiguous eligible LAN IPv4 address is available.',
        operation: operation,
      ),
    );
  }

  Future<T> _enqueueWebShareLifecycle<T>(Future<T> Function() operation) {
    final next = _webShareLifecycle.then((_) => operation());
    _webShareLifecycle = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }
}
