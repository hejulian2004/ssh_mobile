import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:realtime_media/realtime_media.dart';
import 'screen_share_session_lease.dart';
import 'screen_share_peer_arbitration.dart';

/// Media role selected by the App Shell screen-share route.
enum AppScreenShareRouteMode { send, receive }

/// Strongly typed arguments for the App Shell screen-share route.
///
/// The caller supplies the App-owned Realtime session and the local peer
/// identity. A capture source is required only when the route is used to send
/// a screen; incoming-only routes can omit it.
final class AppScreenShareRouteArguments {
  const AppScreenShareRouteArguments({
    required this.session,
    required this.localPeerId,
    this.sessionLease,
    this.operationId,
    this.initialIncomingRequest,
    this.source,
    this.sourceOption,
    this.mode = AppScreenShareRouteMode.receive,
    this.startOutgoing = false,
    this.acceptIncomingOnOpen = false,
    this.codecMode = RealtimeMediaCodecMode.hardware,
    this.arbitration,
  });

  final RealtimeSession session;
  final AppScreenShareSessionLease? sessionLease;
  final String localPeerId;
  final String? operationId;
  final RealtimeConsent? initialIncomingRequest;
  final ScreenCaptureSource? source;
  final ScreenShareSourceOption? sourceOption;
  final AppScreenShareRouteMode mode;
  final bool startOutgoing;
  final bool acceptIncomingOnOpen;
  final RealtimeMediaCodecMode codecMode;
  final AppScreenSharePeerArbitrationRegistry? arbitration;
}
