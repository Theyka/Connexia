import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Replays the exact byte stream captured from a real GNU `screen -r`
/// attach onto an already-streaming program (alt screen + DECSTR soft
/// reset + charset + scroll region + double clear + streamed logs), then
/// drags a selection while the stream continues and copies.
void main() {
  testWidgets('screen attach replay: drag-select + copy mid-stream',
      (tester) async {
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

    // The exact reattach prefix captured from GNU screen.
    terminal.write('\x1b[?1049h\x1b[!p\x1b[?3;4l\x1b[4l\x1b>\x1b[4l'
        '\x1b[?1h\x1b=\x1b[0m\x1b(B\x1b[1;24r\x1b[H\x1b[2J\x1b[H\x1b[2J');
    for (var i = 0; i < 30; i++) {
      terminal.write('reattached log line $i\r\n');
    }

    final cell = Size(800 / terminal.viewWidth, 600 / terminal.viewHeight);
    final start = Offset(cell.width * 1.5, cell.height * 10.5);
    final end = Offset(cell.width * 6.5, cell.height * 10.5);

    // The running program streams while the user drags.
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(end);
    for (var i = 0; i < 40; i++) {
      terminal.write('streaming line $i\r\n');
    }
    await tester.pump();
    await gesture.up();
    await tester.pump();

    debugPrint('selectionText=${controller.selectionText ?? "null"} '
        'live=${controller.selection?.begin.y ?? "null"}..'
        '${controller.selection?.end.y ?? "null"}');

    expect(controller.selectionText, isNotNull,
        reason: 'selection must survive the attach replay');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(clipboard, isNotEmpty, reason: 'copy must reach the clipboard');
  });
}
