import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Builds a TerminalPainter with the same style the app uses, so the test can
/// compute the exact pixel size of a terminal cell.
TerminalPainter _painter() {
  return TerminalPainter(
    theme: TerminalThemes.defaultTheme,
    textStyle: const TerminalStyle(
      fontSize: 12,
      fontFamily: 'JetBrainsMono',
      height: 1.15,
    ),
    textScaler: TextScaler.noScaling,
  );
}

/// The shortcuts map that Connexia passes to [TerminalView]. Plain Ctrl+A,
/// Ctrl+V and friends must reach the remote terminal (Ctrl+A is the GNU
/// screen escape key), so only the shift-copy/paste shortcuts are kept.
Map<ShortcutActivator, Intent> appTerminalShortcuts() => {
      SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
          CopySelectionTextIntent.copy,
      SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
          const PasteTextIntent(SelectionChangedCause.keyboard),
    };

/// Asserts that after content has been written and the layout has settled
/// over several frames, the terminal viewport rests exactly on the bottom.
void _expectStuckToBottom(WidgetTester tester, String reason) {
  final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
  expect(
    scrollable.position.pixels,
    moreOrLessEquals(scrollable.position.maxScrollExtent, epsilon: 0.001),
    reason: reason,
  );
}

void main() {
  testWidgets('viewport sticks exactly to the bottom as content grows',
      (tester) async {
    final terminal = Terminal(maxLines: 1000);
    final focusNode = FocusNode();
    final cell = _painter().cellSize;

    // A viewport height that is NOT a whole multiple of the line height.
    // With this, the content height can never line up with the viewport
    // either, which used to make the stick-to-bottom correction ratchet
    // the viewport a few pixels off the bottom on every layout.
    const rows = 30;
    final paneHeight = cell.height * rows + 7;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: paneHeight,
              child: TerminalView(
                terminal,
                focusNode: focusNode,
                theme: TerminalThemes.defaultTheme,
                textStyle: const TerminalStyle(
                  fontSize: 12,
                  fontFamily: 'JetBrainsMono',
                  height: 1.15,
                ),
                hardwareKeyboardOnly: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(terminal.viewHeight, rows,
        reason: 'sanity: the terminal must report the expected row count');

    for (var i = 0; i < 500; i++) {
      terminal.write('scrollback line $i\n');
    }
    await tester.pump();

    // Let any layout-driven corrections settle over several frames.
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    _expectStuckToBottom(
      tester,
      'after writing lots of output the viewport must rest exactly at '
          'the bottom, not a few pixels short',
    );

    // More output while stuck to the bottom must keep the viewport glued
    // to the new bottom edge.
    for (var i = 0; i < 50; i++) {
      terminal.write('more output $i\n');
    }
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    _expectStuckToBottom(
      tester,
      'growing content must not leave a gap at the bottom',
    );

    focusNode.dispose();
  });

  testWidgets('Ctrl+A and Ctrl+V are forwarded to the remote terminal',
      (tester) async {
    final terminal = Terminal(maxLines: 100);
    final outputs = <String>[];
    terminal.onOutput = outputs.add;
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: 300,
              child: TerminalView(
                terminal,
                focusNode: focusNode,
                autofocus: true,
                hardwareKeyboardOnly: true,
                shortcuts: appTerminalShortcuts(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await simulateKeyDownEvent(LogicalKeyboardKey.keyA);
    await simulateKeyUpEvent(LogicalKeyboardKey.keyA);
    await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(outputs.join(), contains('\u0001'),
        reason: 'Ctrl+A must reach the remote as 0x01 (GNU screen escape), '
            'not be swallowed by a select-all shortcut');

    outputs.clear();
    await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await simulateKeyDownEvent(LogicalKeyboardKey.keyV);
    await simulateKeyUpEvent(LogicalKeyboardKey.keyV);
    await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(outputs.join(), contains('\u0016'),
        reason: 'plain Ctrl+V must reach the remote (readline '
            'quoted-insert) instead of pasting clipboard text');

    focusNode.dispose();
  });
}
