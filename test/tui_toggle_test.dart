import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Simulates a full-screen TUI (like htop) that redraws the whole screen on
/// every resize: clear screen, home, then paint every row at the CURRENT
/// terminal size. Verifies the emulator never leaves mixed/crumpled content.
void main() {
  testWidgets('sidebar toggle: TUI redraw after resize stays clean',
      (tester) async {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();

    Size measure() => TerminalPainter(
          theme: TerminalThemes.defaultTheme,
          textStyle: const TerminalStyle(
            fontSize: 14,
            fontFamily: 'JetBrainsMono',
            height: 1.15,
          ),
          textScaler: TextScaler.noScaling,
        ).cellSize;

    Size lastPixels = Size.zero;
    void sync(Size size) {
      final cell = measure();
      const gap = 12.0;
      final viewportWidth = size.width - gap * 2;
      final viewportHeight = size.height - gap * 2;
      final cols = (viewportWidth / cell.width).floor().clamp(1, 100000);
      final rows = (viewportHeight / cell.height).floor().clamp(1, 100000);
      final content = Size(
        (cols * cell.width).round().toDouble(),
        (rows * cell.height).round().toDouble(),
      );
      if (terminal.viewWidth != cols ||
          terminal.viewHeight != rows ||
          lastPixels != content) {
        lastPixels = content;
        terminal.resize(cols, rows, content.width.round(), content.height.round());
      }
    }

    Widget pane(double width, double height) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                height: height,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    sync(constraints.biggest);
                    return TerminalView(
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
                    );
                  },
                ),
              ),
            ),
          ),
        );

    // A TUI draws a full frame with box-drawing at the current size.
    void drawTui() {
      final w = terminal.viewWidth;
      final h = terminal.viewHeight;
      final b = StringBuffer('${String.fromCharCode(27)}[H');
      for (var row = 0; row < h; row++) {
        b.write('${String.fromCharCode(27)}[2K');
        String line;
        if (row == 0) {
          line = 'header row pad pad pad ${'x' * (w - 35).clamp(0, 100000)}';
        } else {
          line = 'row${row.toString().padLeft(2, '0')} ${'y' * (w - 10)}';
        }
        if (line.length < w) {
          line = line.padRight(w);
        } else if (line.length > w) {
          line = line.substring(0, w);
        }
        b.write(line);
        b.write('${String.fromCharCode(27)}[0m\n');
      }
      terminal.write(b.toString());
    }

    // Start wide (sidebar closed).
    await tester.pumpWidget(pane(900, 600));
    await tester.pumpAndSettle();
    drawTui();
    await tester.pumpAndSettle();
    final wideText = terminal.buffer.getText();

    // Open the sidebar: pane narrows; the TUI redraws at the new size.
    await tester.pumpWidget(pane(640, 600));
    await tester.pumpAndSettle();
    drawTui();
    await tester.pumpAndSettle();
    final narrowText = terminal.buffer.getText();

    // Close the sidebar: pane widens again; TUI redraws at the new size.
    await tester.pumpWidget(pane(900, 600));
    await tester.pumpAndSettle();
    drawTui();
    await tester.pumpAndSettle();
    final closedText = terminal.buffer.getText();

    debugPrint('wide cols=${terminal.viewWidth} rows=${terminal.viewHeight}');
    debugPrint('WIDE:\n$wideText');
    debugPrint('NARROW:\n$narrowText');
    debugPrint('CLOSED:\n$closedText');

    // The final frame must be a perfect grid: every visible line exactly the
    // terminal width, no stray '?' placeholders, no blank rows in the
    // middle of the screen, no wrapped leftovers.
    final allLines = closedText.split('\n');
    final lines = allLines.length > terminal.viewHeight
        ? allLines.sublist(allLines.length - terminal.viewHeight)
        : allLines;
    expect(lines.length, terminal.viewHeight,
        reason: 'TUI frame must fill exactly the viewport rows');
    for (var i = 0; i < lines.length; i++) {
      expect(lines[i].contains('?'), isFalse,
          reason: 'row $i contains a placeholder: "${lines[i]}"');
      expect(lines[i].length, lessThanOrEqualTo(terminal.viewWidth + 1),
          reason: 'row $i overflows the viewport: "${lines[i]}"');
    }
  });
}
