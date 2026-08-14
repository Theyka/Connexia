import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Reproduces the "selecting text in a live TUI" flow: the user drags to
/// select while the remote redraws the screen, then copies.
void main() {
  testWidgets('drag-select survives a mid-drag TUI redraw and copies',
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

    const esc = '\x1b';
    terminal.write('$esc[?1049h$esc[H$esc[2J');
    terminal.write('alpha beta gamma\r\n');
    terminal.write('delta epsilon zeta\r\n');

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

    final cell = terminal.buffer.viewWidth > 0
        ? Size(800 / terminal.viewWidth, 600 / terminal.viewHeight)
        : const Size(8, 17);
    final start = Offset(cell.width * 1.5, cell.height * 0.5);
    final end = Offset(cell.width * 6.5, cell.height * 0.5);

    // Press and start dragging.
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();

    // A live TUI redraws WHILE the user still holds the mouse down:
    // full-screen rewrite that clears every line (detaches anchors).
    terminal.write('$esc[H$esc[2J');
    terminal.write('redrawn alpha beta\r\n');
    terminal.write('redrawn delta epsilon\r\n');
    await tester.pump();

    // One more move after the redraw, then release.
    await gesture.moveTo(end + const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(controller.selectionText, isNotNull,
        reason: 'selection must be captured after a mid-drag redraw');

    // Invoke the real copy action (Ctrl+Shift+C path).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    debugPrint('selection=${controller.selectionText} '
        'frozen=${controller.frozenRange} clipboard=${clipboard.length}');
    expect(clipboard, isNotEmpty,
        reason: 'copy must put text on the clipboard');
  });

  testWidgets('selection survives a post-release redraw and copies',
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

    const esc = '\x1b';
    terminal.write('$esc[?1049h$esc[H$esc[2J');
    terminal.write('one two three\r\n');

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
    final start = Offset(cell.width * 0.5, cell.height * 0.5);
    final end = Offset(cell.width * 3.5, cell.height * 0.5);

    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // The TUI keeps refreshing after the user released the mouse.
    terminal.write('$esc[H$esc[2J');
    terminal.write('refreshed one two\r\n');
    await tester.pump();

    expect(controller.selectionText, 'one',
        reason: 'frozen selection text must survive a later redraw');

    // Ctrl+Shift+C through the focused terminal, exactly like the app.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    debugPrint('selection=${controller.selectionText} '
        'clipboard=${clipboard.length}');

    expect(clipboard, isNotEmpty,
        reason: 'copy must put text on the clipboard after a redraw');
  });
}
