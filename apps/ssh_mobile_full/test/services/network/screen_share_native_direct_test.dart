import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';
import 'package:ssh_mobile/app/realtime_feature_adapters.dart';
import 'package:ssh_mobile/services/network/network_service.dart';

void main() {
  for (final passiveReceiver in [false, true]) {
    test(
      'real native direct invitation returns acceptance (passive=$passiveReceiver)',
      () async {
        final root = await Directory.systemTemp.createTemp('screen-direct-');
        final a = NetworkRuntimeImpl();
        final b = NetworkRuntimeImpl();
        NativeNetworkService? sa;
        NativeNetworkService? sb;
        RealtimeClientImpl? client;
        RealtimeClientImpl? receiver;
        try {
          sa = NativeNetworkService.fromGateway(await a.openCommandGateway());
          sb = NativeNetworkService.fromGateway(await b.openCommandGateway());
          final seedA = Uint8List.fromList(List.filled(32, 41));
          final seedB = Uint8List.fromList(List.filled(32, 42));
          final xA = Uint8List.fromList(List.filled(32, 51));
          final xB = Uint8List.fromList(List.filled(32, 52));
          expect(
            await sa.start(
              SdkRuntimeConfig(
                deviceId: 'direct-a',
                identityPrivateKey: seedA,
                e2ePrivateKey: xA,
                listenAddress: '0.0.0.0:0',
                receiveDirectory: '${root.path}/a',
              ),
            ),
            isA<SdkSuccess<void>>(),
          );
          expect(
            await sb.start(
              SdkRuntimeConfig(
                deviceId: 'direct-b',
                identityPrivateKey: seedB,
                e2ePrivateKey: xB,
                listenAddress: '0.0.0.0:0',
                receiveDirectory: '${root.path}/b',
              ),
            ),
            isA<SdkSuccess<void>>(),
          );
          Future<Uint8List> public(SimpleKeyPair pair) async =>
              Uint8List.fromList((await pair.extractPublicKey()).bytes);
          expect(
            await sa.upsertPeer(
              SdkPeerConfig(
                peerId: 'direct-b',
                endpointAddress: '127.0.0.1:${b.diagnostics.boundLocalPort}',
                identityPublicKey: await public(
                  await Ed25519().newKeyPairFromSeed(seedB),
                ),
                e2ePublicKey: await public(
                  await X25519().newKeyPairFromSeed(xB),
                ),
              ),
            ),
            isA<SdkSuccess<void>>(),
          );
          expect(
            await sb.upsertPeer(
              SdkPeerConfig(
                peerId: 'direct-a',
                endpointAddress: passiveReceiver
                    ? ''
                    : '127.0.0.1:${a.diagnostics.boundLocalPort}',
                identityPublicKey: await public(
                  await Ed25519().newKeyPairFromSeed(seedA),
                ),
                e2ePublicKey: await public(
                  await X25519().newKeyPairFromSeed(xA),
                ),
              ),
            ),
            isA<SdkSuccess<void>>(),
          );
          expect(
            await sa.connect(
              'direct-b',
              communicationClass: CommunicationClass.reliableMessage,
            ),
            isA<SdkSuccess<void>>(),
          );
          final backend = AppRealtimeSessionBackend(
            networkRuntime: a,
            screenVideo: true,
          );
          backend.observeGateway(await a.openRealtimeGateway());
          final receivingBackend = AppRealtimeSessionBackend(networkRuntime: b);
          receivingBackend.observeGateway(await b.openRealtimeGateway());
          receiver = RealtimeClientImpl(backend: receivingBackend);
          client = RealtimeClientImpl(backend: backend);
          final session = client.createSession(
            realtimeId: '00112233445566778899aabbccddeeff',
            peerId: 'direct-b',
          );
          final videoOffer = (await a.openRealtimeGateway()).events
              .where(
                (e) =>
                    e is NativeRealtimeSignalEvent &&
                    e.kind == NativeRealtimeSignalKind.webRtcOffer,
              )
              .cast<NativeRealtimeSignalEvent>()
              .first;
          final identity = session.snapshots.firstWhere(
            (snapshot) =>
                snapshot.generation != null &&
                snapshot.sharedSessionInstanceId != null,
          );
          final result = await session.start();
          expect(
            result,
            isA<SdkSuccess<void>>(),
            reason: result is SdkFailure<void> ? result.error.message : null,
          );
          final snapshot = await identity.timeout(const Duration(seconds: 5));
          final sdp = utf8.decode((await videoOffer).payload);
          expect(sdp, contains('m=video'));
          expect(sdp, contains('H264/90000'));
          expect(snapshot.state, RealtimeSessionState.negotiating);
          expect(snapshot.generation, greaterThan(0));
          expect(snapshot.sharedSessionInstanceId, hasLength(32));
          final incoming = receiver.incomingOffers.first;
          final now = DateTime.now().toUtc();
          final request = RealtimeConsent(
            operationId: 'direct-operation',
            realtimeId: session.realtimeId,
            sharedSessionInstanceId: snapshot.sharedSessionInstanceId!,
            issuedAt: now,
            expiresAt: now.add(const Duration(minutes: 1)),
            decision: RealtimeConsentDecision.request,
            senderPeerId: 'direct-a',
            actionRevision: 1,
          );
          expect(await session.sendConsent(request), isA<SdkSuccess<void>>());
          final offer = await incoming.timeout(const Duration(seconds: 5));
          expect(offer.authenticatedPeerId, 'direct-a');
          await Future<void>.delayed(const Duration(seconds: 2));
          expect(session.state, RealtimeSessionState.negotiating);
          final connectedA = session.snapshots.firstWhere(
            (s) => s.state == RealtimeSessionState.connected,
          );
          final claimed = await receiver.claimIncomingSession(offer);
          expect(claimed, isA<SdkSuccess<RealtimeSession>>());
          final receivingSession =
              (claimed as SdkSuccess<RealtimeSession>).data;
          if (receivingSession.sharedSessionInstanceId == null) {
            await receivingSession.snapshots
                .firstWhere((s) => s.sharedSessionInstanceId != null)
                .timeout(const Duration(seconds: 5));
          }
          final connectedB = receivingSession.snapshots.firstWhere(
            (s) => s.state == RealtimeSessionState.connected,
          );
          final accepted = session.consentEvents.firstWhere(
            (consent) => consent.decision == RealtimeConsentDecision.accept,
          );
          expect(
            await receivingSession.sendConsent(
              RealtimeConsent(
                operationId: request.operationId,
                realtimeId: session.realtimeId,
                sharedSessionInstanceId: snapshot.sharedSessionInstanceId!,
                issuedAt: now,
                expiresAt: request.expiresAt,
                decision: RealtimeConsentDecision.accept,
                senderPeerId: 'direct-b',
                actionRevision: 1,
              ),
            ),
            isA<SdkSuccess<void>>(),
          );
          await Future.wait([
            connectedA,
            connectedB,
            accepted,
          ]).timeout(const Duration(seconds: 15));
          await session.stop();
        } finally {
          await client?.dispose();
          await receiver?.dispose();
          await sa?.dispose();
          await sb?.dispose();
          await a.dispose();
          await b.dispose();
          await root.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
