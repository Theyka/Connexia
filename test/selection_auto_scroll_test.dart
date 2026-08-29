import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Verifies that drag selection auto-scrolls past the visible viewport,
/// so the user can select more than one screenful in a single drag.
void main() {
  testWidgets('drag selection auto-scrolls past the visible viewport',
      (tester) async {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();

    // Write more lines than the viewport can show (viewport ~37 rows).
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

    // Scroll to the top so there is room to auto-scroll downward.
    final state = tester.state<TerminalViewState>(
      find.byType(TerminalView),
    );
    state.scrollBy(-10000);
    await tester.pumpAndSettle();

    final cell = terminal.viewWidth > 0
        ? Size(800 / terminal.viewWidth, 600 / terminal.viewHeight)
        : const Size(8, 17);
    final start = Offset(cell.width * 0.5, cell.height * 0.5);
    // Move pointer to the bottom edge, within the auto-scroll margin.
    final end = Offset(cell.width * 0.5, 600 - cell.height * 0.25);

    // Start dragging at the top of the viewport.
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    // Move to the bottom edge to trigger auto-scroll.
    await gesture.moveTo(end);
    await tester.pump();

    // Let the auto-scroll timer fire several times (~200 ms).
    await tester.pump(const Duration(milliseconds: 200));
    // Release the drag.
    await gesture.up();
    await tester.pump();

    final range = controller.selection;
    debugPrint(
      'selection range=$range text=${controller.selectionText}',
    );
    expect(range, isNotNull,
        reason: 'a selection must exist after the drag');
    expect(range!.end.y, greaterThan(terminal.viewHeight),
        reason: 'drag selection must auto-scroll past the visible viewport');
  });

  testWidgets('drag selection auto-scrolls upward past the visible viewport',
      (tester) async {
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

    // Start scrolled at the bottom so there is room to auto-scroll upward.
    final state = tester.state<TerminalViewState>(
      find.byType(TerminalView),
    );
    state.scrollBy(10000);
    await tester.pumpAndSettle();

    final cell = terminal.viewWidth > 0
        ? Size(800 / terminal.viewWidth, 600 / terminal.viewHeight)
        : const Size(8, 17);
    final start = Offset(cell.width * 0.5, 600 - cell.height * 0.5);
    // Move pointer to the top edge, within the auto-scroll margin.
    final end = Offset(cell.width * 0.5, cell.height * 0.25);

    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();

    // Let the auto-scroll timer fire several times (~200 ms).
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();

    final range = controller.selection;
    // Buffer has 100 lines; scrolled to the bottom the first visible row is
    // 100 - viewHeight. Auto-scroll up must select rows above that.
    final firstVisibleRow = 100 - terminal.viewHeight;
    debugPrint(
      'upward selection range=$range firstVisibleRow=$firstVisibleRow '
      'text=${controller.selectionText}',
    );
    expect(range, isNotNull,
        reason: 'a selection must exist after the drag');
    expect(range!.normalized.begin.y, lessThan(firstVisibleRow),
        reason: 'drag selection must auto-scroll past the top of the viewport');
  });
}