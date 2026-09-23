import 'package:connexia/core/host_protocol.dart';
import 'package:connexia/core/remote/key_mapping.dart';
import 'package:connexia/core/remote/remote_session.dart';
import 'package:connexia/ui/screens/remote_screen.dart';
import 'package:connexia/ui/state/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the pointer/wheel commands a remote session sends.
class _Recorder implements RemoteClient {
  final List<(int buttons, int x, int y)> pointers = [];
  final List<int> wheels = [];

  @override
  void sendKey(RemoteKeyEvent event, bool down) {}

  @override
  void sendPointer(int buttons, int x, int y) => pointers.add((buttons, x, y));

  @override
  void sendWheel(int buttons, int x, int y, int delta) => wheels.add(delta);

  @override
  void sendClipboard(String text) {}

  @override
  void setVisible(bool visible) {}

  @override
  void close() {}
}

/// Runs [body] while the app is pretending to run on a touch platform, then
/// restores the override (the test binding asserts it is unset at the end).
Future<void> _onTouchPlatform(Future<void> Function() body) async {
  final original = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = original;
  }
}

Future<void> _pumpViewport(WidgetTester tester, _Recorder recorder) async {
  final session =
      RemoteSession(
          id: 'r1',
          title: 'Test',
          protocol: HostProtocol.rdp,
          width: 100,
          height: 100,
        )
        ..address = '10.0.0.1'
        ..status = RemoteStatus.connected;
  session.attachClient(recorder);

  final manager = RemoteSessionManager()..addSessionForTesting(session);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [remoteManagerProvider.overrideWith((ref) => manager)],
      child: const MaterialApp(home: Scaffold(body: RemoteScreen())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('tap sends a left click', (tester) async {
    await _onTouchPlatform(() async {
      final recorder = _Recorder();
      await _pumpViewport(tester, recorder);

      await tester.tapAt(const Offset(300, 300));
      await tester.pump(const Duration(milliseconds: 50));

      expect(recorder.pointers.any((p) => p.$1 == 1), isTrue);
      expect(recorder.pointers.any((p) => p.$1 == 0), isTrue);
    });
  });

  testWidgets('hold sends a right click', (tester) async {
    await _onTouchPlatform(() async {
      final recorder = _Recorder();
      await _pumpViewport(tester, recorder);

      await tester.longPressAt(const Offset(300, 300));
      await tester.pump(const Duration(milliseconds: 50));

      expect(recorder.pointers.any((p) => p.$1 == 2), isTrue);
      expect(recorder.pointers.any((p) => p.$1 == 0), isTrue);
      expect(recorder.pointers.any((p) => p.$1 == 1), isFalse);
    });
  });

  testWidgets('one-finger drag moves the cursor with no button held', (
    tester,
  ) async {
    await _onTouchPlatform(() async {
      final recorder = _Recorder();
      await _pumpViewport(tester, recorder);

      await tester.dragFrom(const Offset(300, 300), const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 50));

      expect(recorder.pointers, isNotEmpty);
      expect(recorder.pointers.every((p) => p.$1 == 0), isTrue);
    });
  });

  testWidgets('two-finger drag sends wheel scroll', (tester) async {
    await _onTouchPlatform(() async {
      final recorder = _Recorder();
      await _pumpViewport(tester, recorder);

      final first = await tester.startGesture(const Offset(300, 300));
      final second = await tester.startGesture(const Offset(340, 300));
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await first.moveBy(const Offset(0, 30));
        await second.moveBy(const Offset(0, 30));
        await tester.pump();
      }
      await first.up();
      await second.up();
      await tester.pump(const Duration(milliseconds: 50));

      expect(recorder.wheels, isNotEmpty);
    });
  });

  testWidgets('macOS trackpad pan/zoom sends wheel scroll', (tester) async {
    final original = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final recorder = _Recorder();
      await _pumpViewport(tester, recorder);

      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(
        pointer.panZoomStart(const Offset(300, 300)),
      );
      for (var i = 1; i <= 5; i++) {
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(
            const Offset(300, 300),
            pan: Offset(0, 30.0 * i),
          ),
        );
        await tester.pump();
      }
      await tester.sendEventToBinding(pointer.panZoomEnd());
      await tester.pump();

      expect(recorder.wheels, isNotEmpty);
      // Natural scrolling: fingers moving down scroll toward the top, which is
      // a positive wheel delta.
      expect(recorder.wheels, everyElement(1));
    } finally {
      debugDefaultTargetPlatformOverride = original;
    }
  });
}
