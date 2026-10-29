import 'dart:async';
import 'dart:typed_data';

import 'package:feature_screen_share/feature_screen_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/screen_share_picture_in_picture.dart';
import 'package:ssh_mobile/app/screen_share_video_page.dart';
import 'package:ssh_mobile/app/window_fullscreen_controller.dart';

void main() {
  late ValueNotifier<Size?> size;
  late _WindowPlatform platform;
  setUp(() {
    size = ValueNotifier(const Size(1080, 2400));
    platform = _WindowPlatform();
  });
  tearDown(() => size.dispose());

  Widget page({
    VoidCallback? onStop,
    bool enabled = true,
    bool automatic = false,
    bool pictureInPicture = false,
    AppPictureInPicturePlatform? pip,
    Locale? locale,
    ScreenShareAnnotationSession? annotation,
  }) => MaterialApp(
    locale: locale,
    home: AppScreenShareVideoPage(
      video: const _Video(),
      videoSize: size,
      controls: const Text('consent state'),
      enableViewerControls: enabled,
      autoEnterFullscreen: automatic,
      allowPictureInPicture: pictureInPicture,
      pictureInPicturePlatform: pip,
      onStop: onStop,
      annotation: annotation,
      windowPlatform: platform,
    ),
  );

  testWidgets('automatic fullscreen waits for a ready viewer and enters once', (
    tester,
  ) async {
    await tester.pumpWidget(page(automatic: true, enabled: false));
    await tester.pumpAndSettle();
    expect(platform.calls, isEmpty);
    final video = tester.state(find.byType(_Video));
    await tester.pumpWidget(page(automatic: true));
    await tester.pumpAndSettle();
    expect(platform.calls.map((call) => call.$2), [true]);
    expect(find.byType(AppBar), findsNothing);
    expect(tester.state(find.byType(_Video)), same(video));
    await tester.tap(find.byTooltip('Exit fullscreen'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(automatic: true));
    size.value = const Size(1920, 1080);
    await tester.pumpAndSettle();
    expect(platform.calls.map((call) => call.$2), [true, false]);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.state(find.byType(_Video)), same(video));
  });

  testWidgets('ready receiver enters automatically with stop still available', (
    tester,
  ) async {
    var stopped = 0;
    await tester.pumpWidget(page(automatic: true, onStop: () => stopped++));
    await tester.pumpAndSettle();
    expect(platform.calls.map((call) => call.$2), [true]);
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(find.byTooltip('Stop screen share'));
    expect(stopped, 1);
    await tester.pumpWidget(page(automatic: true, enabled: false));
    await tester.pumpAndSettle();
    expect(platform.calls.map((call) => call.$2), [true, false]);
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('failed automatic enter allows an explicit fullscreen retry', (
    tester,
  ) async {
    platform.failEnter = true;
    await tester.pumpWidget(page(automatic: true));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(
      find.text('Unable to change or restore fullscreen.'),
      findsOneWidget,
    );
    await tester.pumpWidget(page(automatic: true));
    await tester.pumpAndSettle();
    expect(platform.calls.map((call) => call.$2), [true, false]);
    platform.failEnter = false;
    await tester.tap(find.byTooltip('Enter fullscreen'));
    await tester.pumpAndSettle();
    expect(platform.calls.map((call) => call.$2), [true, false, true]);
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('terminal state compensates a pending automatic enter', (
    tester,
  ) async {
    final entered = Completer<void>();
    platform.entering = entered.future;
    await tester.pumpWidget(page(automatic: true));
    await tester.pumpWidget(page(automatic: true, enabled: false));
    entered.complete();
    await tester.pumpAndSettle();
    expect(platform.calls.map((call) => call.$2), [true, false]);
    expect(platform.calls.first.$1, platform.calls.last.$1);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation keeps native aspect ratio and wraps after four turns', (
    tester,
  ) async {
    await tester.pumpWidget(page());
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      1080 / 2400,
    );
    await tester.tap(find.byTooltip('Rotate view'));
    await tester.pump();
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      2400 / 1080,
    );
    size.value = const Size(1920, 1080);
    await tester.pump();
    expect(
      tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
      1080 / 1920,
    );
    for (var turn = 0; turn < 3; turn++) {
      await tester.tap(find.byTooltip('Rotate view'));
      await tester.pump();
    }
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 0);
  });

  testWidgets(
    'fullscreen preserves video state and back exits it before navigation',
    (tester) async {
      var stopped = 0;
      await tester.pumpWidget(page(onStop: () => stopped++));
      final before = tester.state(find.byType(_Video));
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('consent state'), findsNothing);
      expect(tester.state(find.byType(_Video)), same(before));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('consent state'), findsOneWidget);
      expect(tester.state(find.byType(_Video)), same(before));
      expect(stopped, 0);
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop screen share'));
      expect(stopped, 1);
    },
  );

  testWidgets('escape exits fullscreen and terminal state restores controls', (
    tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.tap(find.byTooltip('Enter fullscreen'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    await tester.tap(find.byTooltip('Enter fullscreen'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(enabled: false));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('Rotate view'), findsNothing);
    expect(find.text('consent state'), findsOneWidget);
  });

  testWidgets(
    'back during pending enter restores native window before leaving fullscreen',
    (tester) async {
      final entered = Completer<void>();
      platform.entering = entered.future;
      await tester.pumpWidget(page());
      final before = tester.state(find.byType(_Video));
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      entered.complete();
      await tester.pumpAndSettle();
      expect(platform.calls.map((call) => call.$2), [true, false]);
      expect(platform.calls.first.$1, platform.calls.last.$1);
      expect(find.byType(AppBar), findsOneWidget);
      expect(tester.state(find.byType(_Video)), same(before));
    },
  );

  testWidgets('route disposal compensates late native enter', (tester) async {
    final entered = Completer<void>();
    platform.entering = entered.future;
    await tester.pumpWidget(page());
    await tester.tap(find.byTooltip('Enter fullscreen'));
    await tester.pumpWidget(const SizedBox());
    entered.complete();
    await tester.pumpAndSettle();
    expect(platform.calls.map((call) => call.$2), [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native failure keeps window controls and reports an error', (
    tester,
  ) async {
    platform.failEnter = true;
    await tester.pumpWidget(page());
    await tester.tap(find.byTooltip('Enter fullscreen'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(
      find.text('Unable to change or restore fullscreen.'),
      findsOneWidget,
    );
    expect(platform.calls.map((call) => call.$2), [true, false]);
  });

  testWidgets('missing or invalid dimensions remain renderable', (
    tester,
  ) async {
    size.value = null;
    await tester.pumpWidget(page());
    expect(find.byType(_Video), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
    size.value = const Size(double.infinity, -1);
    await tester.pump();
    expect(find.byType(AspectRatio), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'terminal view can retry a failed native fullscreen restoration',
    (tester) async {
      await tester.pumpWidget(page());
      final before = tester.state(find.byType(_Video));
      await tester.tap(find.byTooltip('Enter fullscreen'));
      await tester.pumpAndSettle();
      platform.failExit = true;
      await tester.pumpWidget(page(enabled: false));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('Rotate view'), findsNothing);
      expect(find.text('Retry restore'), findsOneWidget);
      platform.failExit = false;
      await tester.tap(find.text('Retry restore'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(
        find.text('Unable to change or restore fullscreen.'),
        findsNothing,
      );
      expect(tester.state(find.byType(_Video)), same(before));
      expect(platform.calls.map((call) => call.$1).toSet().length, 1);
    },
  );

  testWidgets('annotation is drawn inside the frame and escape still exits', (
    tester,
  ) async {
    final transport = _AnnotationTransport()..open = true;
    final session = ScreenShareAnnotationSession(
      operationId: 'operation-a',
      generation: 4,
      transport: transport,
    )..start();
    addTearDown(session.dispose);
    await tester.pumpWidget(page(annotation: session, onStop: () {}));
    expect(find.byTooltip('Annotate'), findsOneWidget);
    await tester.tap(find.byTooltip('Annotate'));
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ScreenShareAnnotationCanvas)),
    );
    await gesture.moveBy(const Offset(8, 4));
    await gesture.up();
    await tester.pump();
    expect(session.strokes, hasLength(1));
    await tester.tap(find.byTooltip('Enter fullscreen'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('Stop screen share'), findsNothing);
    expect(session.strokes, hasLength(1));
  });

  testWidgets('picture in picture keeps the same video and hides chrome', (
    tester,
  ) async {
    final pip = _PipPlatform();
    final annotation = ScreenShareAnnotationSession(
      operationId: 'operation',
      generation: 1,
      transport: _AnnotationTransport(),
    );
    addTearDown(annotation.dispose);
    await tester.pumpWidget(
      page(
        pictureInPicture: true,
        pip: pip,
        annotation: annotation,
        onStop: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(pip.sessions.single?.width, 1080);
    expect(pip.sessions.single?.height, 2400);
    expect(find.byType(ScreenShareAnnotationToolbar), findsOneWidget);
    expect(find.byType(ScreenShareAnnotationCanvas), findsOneWidget);
    expect(find.byTooltip('Rotate view'), findsOneWidget);
    expect(platform.calls, isEmpty);
    final video = tester.state(find.byType(_Video));
    pip.listener!(true);
    await tester.pump();
    expect(find.byType(ScreenShareAnnotationToolbar), findsNothing);
    expect(find.byType(ScreenShareAnnotationCanvas), findsNothing);
    expect(find.byTooltip('Rotate view'), findsNothing);
    expect(find.byTooltip('Stop screen share'), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('consent state'), findsNothing);
    expect(tester.state(find.byType(_Video)), same(video));
    pip.listener!(false);
    await tester.pump();
    expect(find.byTooltip('Rotate view'), findsOneWidget);
    expect(find.byType(ScreenShareAnnotationCanvas), findsOneWidget);
    await tester.tap(find.byTooltip('Rotate view'));
    await tester.pump();
    expect(pip.sessions.last?.width, 2400);
    expect(pip.sessions.last?.height, 1080);
    size.value = Size.zero;
    await tester.pump();
    expect(pip.sessions.last, isNull);
    expect(platform.calls, isEmpty);
  });

  testWidgets(
    'a covered receiver clears picture in picture without stopping the share',
    (tester) async {
      final pip = _PipPlatform();
      var stopped = 0;
      final annotation = ScreenShareAnnotationSession(
        operationId: 'operation',
        generation: 2,
        transport: _AnnotationTransport(),
      )..start();
      addTearDown(annotation.dispose);
      await tester.pumpWidget(
        page(
          pictureInPicture: true,
          pip: pip,
          annotation: annotation,
          onStop: () => stopped++,
        ),
      );
      await tester.pumpAndSettle();
      expect(pip.sessions.single?.width, 1080);
      expect(pip.sessions.single?.height, 2400);
      final video = tester.state(find.byType(_Video));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering route')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Covering route'), findsOneWidget);
      expect(pip.sessions.last, isNull);
      expect(stopped, 0);
      expect(annotation.strokes, isEmpty);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(pip.sessions.last?.width, 1080);
      expect(pip.sessions.last?.height, 2400);
      expect(stopped, 0);
      expect(annotation.strokes, isEmpty);
      expect(tester.state(find.byType(_Video)), same(video));
    },
  );

  testWidgets(
    'closing the newer share page republishes the receiver underneath',
    (tester) async {
      const channel = MethodChannel('ssh_mobile/screen_share_pip_pages');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final covered = ValueNotifier<Size?>(const Size(1080, 2400));
      final front = ValueNotifier<Size?>(const Size(640, 480));
      addTearDown(covered.dispose);
      addTearDown(front.dispose);
      Widget share(ValueNotifier<Size?> videoSize) => AppScreenShareVideoPage(
        video: const _Video(),
        videoSize: videoSize,
        controls: const Text('consent state'),
        allowPictureInPicture: true,
        pictureInPicturePlatform: MethodChannelAppPictureInPicture(
          channel: channel,
        ),
        windowPlatform: platform,
      );

      await tester.pumpWidget(MaterialApp(home: share(covered)));
      await tester.pump();
      expect(calls.last.arguments, {'width': 1080.0, 'height': 2400.0});
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute<void>(builder: (_) => share(front)));
      await tester.pumpAndSettle();
      expect(calls.last.arguments, {'width': 640.0, 'height': 480.0});
      navigator.pop();
      await tester.pumpAndSettle();
      expect(calls.last.arguments, {'width': 1080.0, 'height': 2400.0});
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onModeChanged', true),
        ),
        (_) {},
      );
      await tester.pump();
      expect(find.byTooltip('Rotate view'), findsNothing);
    },
  );

  testWidgets('sender and an unread frame do not become eligible', (
    tester,
  ) async {
    final pip = _PipPlatform();
    size.value = null;
    await tester.pumpWidget(page(pictureInPicture: true, pip: pip));
    await tester.pump();
    expect(pip.sessions, [null]);
    size.value = const Size(320, 180);
    await tester.pumpWidget(page(pip: pip));
    await tester.pump();
    expect(pip.sessions.last, isNull);
  });
}

class _AnnotationTransport implements ScreenShareAnnotationTransport {
  bool open = false;
  final StreamController<bool> _channel = StreamController<bool>.broadcast();
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();

  @override
  bool get channelOpen => open;

  @override
  Stream<bool> get channelEvents => _channel.stream;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async {}
}

class _PipPlatform implements AppPictureInPicturePlatform {
  final sessions = <AppPictureInPictureSession?>[];
  void Function(bool active)? listener;
  var _holds = false;

  @override
  bool get holds => _holds;

  @override
  Future<bool> setSession(AppPictureInPictureSession? session) async {
    sessions.add(session);
    return true;
  }

  @override
  void bind(void Function(bool active) onModeChanged) {
    _holds = true;
    listener = onModeChanged;
  }

  @override
  bool reclaimIfVacant(void Function(bool active) onModeChanged) {
    if (_holds) return true;
    bind(onModeChanged);
    return true;
  }

  @override
  void unbind() {
    _holds = false;
    listener = null;
  }
}

class _WindowPlatform implements AppWindowPresentationPlatform {
  final calls = <(int, bool)>[];
  Future<void>? entering;
  bool failEnter = false;
  bool failExit = false;
  @override
  Future<void> setFullscreen({
    required int leaseId,
    required bool enabled,
  }) async {
    calls.add((leaseId, enabled));
    if (enabled) {
      await entering;
      if (failEnter) throw StateError('window unavailable');
    } else if (failExit) {
      throw StateError('restore failed');
    }
  }
}

class _Video extends StatefulWidget {
  const _Video();
  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
}
