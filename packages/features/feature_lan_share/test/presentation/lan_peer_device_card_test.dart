import 'dart:io';
import 'dart:ui' as ui;

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:feature_lan_share/src/features/lan_share/views/widgets/lan_peer_device_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/lan_share_test_fakes.dart';

void main() {
  testWidgets(
    'connecting card blocks pointer and keyboard and offers termination',
    (tester) async {
      var stops = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LanPeerDeviceCard(
              peer: LanPeerViewState(trust: _trust()),
              strings: FakeLanShareStrings(),
              onTap: null,
              isConnecting: true,
              onCancel: () => stops++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('peer'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(find.text('Connecting…'), findsOneWidget);
      await tester.tap(find.text('Terminate'));
      expect(stops, 1);
    },
  );
  testWidgets(
    'keyboard activation preserves device tap and the separate unpair action',
    (tester) async {
      var taps = 0;
      var unpairs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LanPeerDeviceCard(
              peer: LanPeerViewState(trust: _trust()),
              strings: FakeLanShareStrings(),
              onTap: () => taps++,
              onUnpair: () => unpairs++,
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
      expect(unpairs, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(unpairs, 1);
      expect(taps, 1);
    },
  );
  for (final width in [360.0, 1000.0]) {
    testWidgets('render representative device list at $width', (tester) async {
      final visualFontPath = Platform.environment['LAN_UI_FONT'];
      if (visualFontPath != null) {
        await tester.runAsync(() async {
          final loader = FontLoader('DeviceVisualFont');
          loader.addFont(
            File(
              visualFontPath,
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
          await loader.load();
          final icons = FontLoader('MaterialIcons');
          icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await icons.load();
        });
      }
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      final peers = [
        LanPeerViewState(
          trust: _trust(),
          discovery: LanDiscoveredPeer(
            deviceId: 'peer',
            alias: 'Android 模拟器',
            ip: '127.0.0.1',
            controlPort: 55001,
            os: 'android',
            deviceType: LanDeviceType.mobile,
            lastSeen: DateTime(2026, 10, 12, 10, 30),
          ),
        ),
        LanPeerViewState(
          peerId: 'desktop',
          trust: _trust(deviceId: 'desktop'),
          savedAlias: 'Windows 工作电脑',
          savedDeviceType: LanDeviceType.desktop,
          lastOnlineAt: DateTime(2026, 10, 11, 21, 45),
        ),
        LanPeerViewState(
          discovery: LanDiscoveredPeer(
            deviceId: 'new',
            alias: '附近的新设备',
            ip: '192.0.2.30',
            controlPort: 53317,
            os: 'android',
            lastSeen: DateTime(2026, 10, 12, 10, 28),
          ),
        ),
      ];
      final theme = AppTheme.lightThemeFor();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(
              fontFamily: visualFontPath != null ? 'DeviceVisualFont' : null,
            ),
          ),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: peers
                    .map(
                      (peer) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: LanPeerDeviceCard(
                          peer: peer,
                          strings: FakeLanShareStrings(english: false),
                          onTap: () {},
                          onUnpair: () {},
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      if (visualFontPath != null) {
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build').create(recursive: true);
          await File(
            'build/device-list-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
  for (final width in [320.0, 1000.0]) {
    for (final english in [false, true]) {
      testWidgets(
        'device card fits $width with enlarged ${english ? 'English' : 'Chinese'} text',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final seen = DateTime(2026, 10, 12, 10, 30);
          final peer = LanPeerViewState(
            peerId: 'peer',
            trust: _trust(),
            savedAlias: 'Android Studio very long device name 安卓模拟器',
            lastOnlineAt: seen,
          );
          var taps = 0;
          var unpairs = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 900),
                  textScaler: const TextScaler.linear(2),
                ),
                child: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(16),
                    child: LanPeerDeviceCard(
                      peer: peer,
                      strings: FakeLanShareStrings(english: english),
                      onTap: () => taps++,
                      onUnpair: () => unpairs++,
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(find.text(english ? 'Offline' : '离线'), findsOneWidget);
          expect(find.text(english ? 'Paired' : '已配对'), findsOneWidget);
          expect(find.textContaining('2026-10-12 10:30'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(peer.displayAlias));
          expect(taps, 1);
          await tester.longPress(find.text(peer.displayAlias));
          expect(unpairs, 1);
          await tester.tap(find.byIcon(Icons.more_horiz_rounded));
          expect(unpairs, 2);
          await tester.tap(
            find.text(peer.displayAlias),
            buttons: kSecondaryMouseButton,
          );
          expect(unpairs, 3);
        },
      );
    }
  }
  testWidgets(
    'online unpaired card has no revoke action or invented timestamp',
    (tester) async {
      final peer = LanPeerViewState(
        peerId: 'unknown',
        reachability: LanPeerReachability.online,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LanPeerDeviceCard(
              peer: peer,
              strings: FakeLanShareStrings(),
              onTap: () {},
            ),
          ),
        ),
      );
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Not paired'), findsOneWidget);
      expect(find.textContaining('Unknown'), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
    },
  );
  testWidgets(
    'unpair confirmation explains rediscovery and supports cancel and confirm',
    (tester) async {
      var confirmed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  confirmed = await confirmLanPeerUnpair(
                    context,
                    LanPeerViewState(peerId: 'peer', trust: _trust()),
                    FakeLanShareStrings(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('discovered'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(confirmed, isFalse);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpair'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    },
  );
}

LanPeerTrustRecord _trust({String deviceId = 'peer'}) => LanPeerTrustRecord(
  deviceId: deviceId,
  certificateFingerprint: 'a' * 64,
  inboundAccessToken: 'inbound',
  outboundAccessToken: 'outbound',
  x25519PublicKey: Uint8List(32),
  networkIdentityPublicKey: Uint8List(32),
  origin: PeerTrustOrigin.localPin,
  authorization: const PeerRouteAuthorization(localDirect: true, relay: false),
  createdAt: DateTime.utc(2026),
);
