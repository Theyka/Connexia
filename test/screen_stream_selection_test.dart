import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Reproduces the `screen -rd` flow: the user drag-selects while the
/// remote program streams log output (plain scrolling, no ESC[2J).
void main() {
  for (final streamDuringDrag in [true, false]) {
    testWidgets(
        'screen -rd: drag-select with streaming logs '
        '(streamDuringDrag=$streamDuringDrag)', (tester) async {
      final terminal = Terminal(maxLines: 1000);
      final controller = TerminalController();
      final clipboard = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add(call);
            return null;
          }
          return null;
        },
      );

      // Screen's reattach redraw: a viewport full of finished log lines.
      for (var i = 0; i < 40; i++) {
        terminal.write('baseline log line $i\r\n');
      }

      Widget pane() => MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 800,
                  height: 600,
                  child: TerminalView(
                    terminal,
                    controller: controller,
                    padding: EdgeInsets.zero,
                    autoResize: false,
                    textStyle: const TerminalStyle(
                      fontSize: 14,
                      fontFamily: 'JetBrainsMono',
                      height: 1.15,
                    ),
                    autofocus: true,
                    hardwareKeyboardOnly: true,
                    shortcuts: {
                      SingleActivator(
                        LogicalKeyboardKey.keyC,
                        control: true,
                        shift: true,
                      ): CopySelectionTextIntent.copy,
                    },
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(pane());
      await tester.pumpAndSettle();

      final cell = Size(800 / terminal.viewWidth, 600 / terminal.viewHeight);
      // Select something in the middle of the viewport.
      final start = Offset(cell.width * 1.5, cell.height * 10.5);
      final end = Offset(cell.width * 6.5, cell.height * 10.5);

      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();

      if (streamDuringDrag) {
        // The running program streams while the mouse is still held down.
        for (var i = 0; i < 30; i++) {
          terminal.write('streaming line $i\r\n');
        }
        await tester.pump();
      }

      await gesture.up();
      await tester.pump();

      if (!streamDuringDrag) {
        // The program streams after the selection was made.
        for (var i = 0; i < 30; i++) {
          terminal.write('streaming line $i\r\n');
        }
        await tester.pump();
      }

      debugPrint(
          'selectionText=${controller.selectionText ?? "null"} '
          'live=${controller.selection?.begin.y ?? "null"}..'
          '${controller.selection?.end.y ?? "null"}');
      debugPrint('frozen=${controller.frozenRange}');

      expect(controller.selectionText, isNotNull,
          reason: 'selection text must survive streaming output');

      // Copy via the real shortcut path.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(clipboard, isNotEmpty,
          reason: 'copy must put text on the clipboard');
      debugPrint('clipboard=${clipboard.length}');
    });
  }
}
