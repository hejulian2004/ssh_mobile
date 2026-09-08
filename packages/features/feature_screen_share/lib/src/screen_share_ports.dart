import 'package:network_sdk/network_sdk.dart';

import 'screen_share_models.dart';

/// Minimal signaling capability borrowed from the App-owned Realtime session.
abstract interface class ScreenShareConsentPort {
  Stream<RealtimeConsent> get consents;

  Future<SdkResult<void>> sendConsent(RealtimeConsent consent);
}

/// Minimal opaque native-media capability borrowed from an App/platform owner.
///
/// The port carries lifecycle metadata only. It deliberately has no frame,
/// codec, SDP, ICE, texture or native-handle method.
abstract interface class ScreenShareMediaPort {
  Stream<ScreenShareMediaEvent> get events;

  Future<void> startCapture({
    required String operationId,
    required String realtimeId,
    required int generation,
  });

  Future<void> startViewer({
    required String operationId,
    required String realtimeId,
    required int generation,
  });

  Future<void> stop({
    required String operationId,
    required String realtimeId,
    required int generation,
  });
}
