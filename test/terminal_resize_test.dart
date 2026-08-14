import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('terminal viewport follows pane resize', (tester) async {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            theme: TerminalThemes.defaultTheme,
            textStyle: const TerminalStyle(fontSize: 12, height: 1.15),
            autofocus: true,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final w0 = terminal.viewWidth;
    final h0 = terminal.viewHeight;
    expect(w0, greaterThan(40), reason: 'initial layout should resize 80x24');

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    await tester.pump();

    final w1 = terminal.viewWidth;
    final h1 = terminal.viewHeight;
    expect(w1, greaterThan(w0),
        reason: 'growing the window must grow the terminal width');
    expect(h1, greaterThan(h0),
        reason: 'growing the window must grow the terminal height');

    tester.view.physicalSize = const Size(640, 400);
    await tester.pump();

    expect(terminal.viewWidth, lessThan(w1),
        reason: 'shrinking the window must shrink the terminal width');
    expect(terminal.viewHeight, lessThan(h1),
        reason: 'shrinking the window must shrink the terminal height');
  });
}
