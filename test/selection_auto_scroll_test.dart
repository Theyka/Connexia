import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('drag selection auto-scrolls past the visible viewport', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();

    for (int i = 0; i < 100; i++) {
      terminal.write('line ${i.toString().padLeft(2, '0')}\r\n');
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
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(pane());
    await tester.pumpAndSettle();

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    state.scrollBy(-10000);
    await tester.pumpAndSettle();

    final cell = terminal.viewWidth > 0
        ? Size(800 / terminal.viewWidth, 600 / terminal.viewHeight)
        : const Size(8, 17);
    final start = Offset(cell.width * 0.5, cell.height * 0.5);

    final end = Offset(cell.width * 0.5, 600 - cell.height * 0.25);

    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    await gesture.moveTo(end);
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 200));

    await gesture.up();
    await tester.pump();

    final range = controller.selection;
    debugPrint('selection range=$range text=${controller.selectionText}');
    expect(range, isNotNull, reason: 'a selection must exist after the drag');
    expect(
      range!.end.y,
      greaterThan(terminal.viewHeight),
      reason: 'drag selection must auto-scroll past the visible viewport',
    );
  });

  testWidgets('drag selection auto-scrolls upward past the visible viewport', (
    tester,
  ) async {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();

    for (int i = 0; i < 100; i++) {
      terminal.write('line ${i.toString().padLeft(2, '0')}\r\n');
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
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(pane());
    await tester.pumpAndSettle();

    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    state.scrollBy(10000);
    await tester.pumpAndSettle();

    final cell = terminal.viewWidth > 0
        ? Size(800 / terminal.viewWidth, 600 / terminal.viewHeight)
        : const Size(8, 17);
    final start = Offset(cell.width * 0.5, 600 - cell.height * 0.5);

    final end = Offset(cell.width * 0.5, cell.height * 0.25);

    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();

    final range = controller.selection;

    final firstVisibleRow = 100 - terminal.viewHeight;
    debugPrint(
      'upward selection range=$range firstVisibleRow=$firstVisibleRow '
      'text=${controller.selectionText}',
    );
    expect(range, isNotNull, reason: 'a selection must exist after the drag');
    expect(
      range!.normalized.begin.y,
      lessThan(firstVisibleRow),
      reason: 'drag selection must auto-scroll past the top of the viewport',
    );
  });
}
