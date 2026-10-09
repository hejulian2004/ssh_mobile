// Short-lived control-plane HTTP. The native runtime owns the data plane.

import 'dart:io';
import 'dart:typed_data';

import 'package:network_sdk/network_sdk.dart';

/// Executes one bootstrap request on a temporary [HttpClient].
final class NetworkControlExecutor implements SdkRequestExecutor {
  /// Creates an executor that rejects oversized control responses.
  const NetworkControlExecutor({this.maxResponseBytes = 64 * 1024});

  /// Maximum accepted response body size.
  final int maxResponseBytes;

  @override
  Future<SdkResponse> execute(SdkRequest request) async {
    final client = HttpClient();
    try {
      final ioRequest = await client.openUrl(request.method, request.uri);
      request.headers.forEach((name, value) {
        if (name.toLowerCase() == 'content-length') return;
        ioRequest.headers.set(name, value);
      });
      final body = request.body;
      if (body != null && body.isNotEmpty) ioRequest.add(body);
      final response = await ioRequest.close();
      final responseBody = await _readBounded(response);
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(',');
      });
      return SdkResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: responseBody,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _readBounded(Stream<List<int>> source) async {
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      if (total > maxResponseBytes) {
        throw const FormatException('SDK response is too large.');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
