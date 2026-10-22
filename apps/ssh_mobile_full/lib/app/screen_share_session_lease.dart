import 'dart:async';

import 'package:network_sdk/network_sdk.dart';

/// Route-transfer lease for one App-created Realtime session.
///
/// The lease owns only the SDK session. Capture, endpoints, decoder and
/// platform surfaces remain with [AppScreenShareMediaCoordinator].
final class AppScreenShareSessionLease {
  AppScreenShareSessionLease({
    required this.client,
    required this.session,
    this.terminalWait = const Duration(seconds: 15),
  });

  final RealtimeClient client;
  final RealtimeSession session;
  final Duration terminalWait;
  Future<void>? _cleanup;

  Future<void> stopAndRelease() => _cleanup ??= _stopAndRelease();

  Future<void> _stopAndRelease() async {
    try {
      await session.stop();
    } catch (_) {
      // Release remains mandatory even when the command path fails.
    }
    if (session.state != RealtimeSessionState.stopped &&
        session.state != RealtimeSessionState.failed) {
      try {
        await session.snapshots
            .firstWhere(
              (snapshot) =>
                  snapshot.state == RealtimeSessionState.stopped ||
                  snapshot.state == RealtimeSessionState.failed,
            )
            .timeout(terminalWait);
      } catch (_) {
        // Native generation invalidation and exact registry release are the
        // terminal safety fallback when the authoritative event is delayed.
      }
    }
    try {
      await client.releaseSession(session);
    } catch (_) {
      // Route teardown must continue even if the App/SDK owner is already
      // disposing. The exact-object release remains idempotent.
    }
  }
}

/// Waits for native identity without requiring media transport to connect.
Future<void> waitForScreenShareSessionIdentity(
  RealtimeSession session, {
  Future<void>? cancelled,
}) async {
  bool ready(RealtimeSnapshot? snapshot) {
    final state = snapshot?.state ?? session.state;
    return (state == RealtimeSessionState.negotiating ||
            state == RealtimeSessionState.connected) &&
        (snapshot?.generation ?? session.generation) != null &&
        (snapshot?.sharedSessionInstanceId ??
                session.sharedSessionInstanceId) !=
            null;
  }

  if (ready(session.currentSnapshot)) return;
  final completer = Completer<void>();
  late final StreamSubscription<RealtimeSnapshot> subscription;
  subscription = session.snapshots.listen((snapshot) {
    if (!completer.isCompleted && ready(snapshot)) completer.complete();
  });
  try {
    if (ready(session.currentSnapshot)) return;
    await Future.any<void>([
      completer.future,
      ?cancelled,
    ]).timeout(const Duration(seconds: 30));
  } finally {
    await subscription.cancel();
  }
}
