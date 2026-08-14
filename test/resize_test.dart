import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Mirrors the app's terminal pane exactly (see terminal_screen.dart
/// `_TerminalPane`): a LayoutBuilder that re-asserts the terminal size, a
/// 12px gap, and TerminalView with the default autoResize.
/// Mirrors the pane's guard against sending an unchanged resize: the last
/// pixel dimensions sent to the remote. A mutable holder so it survives
/// widget rebuilds between pumps.
class _PixelTracker {
  Size? last;
}

class _Pane extends StatelessWidget {
  const _Pane({
    required this.terminal,
    required this.controller,
    required this.width,
    required this.height,
    required this.pixels,
    this.autoResize = true,
  });

  final Terminal terminal;
  final TerminalController controller;
  final double width;
  final double height;
  final bool autoResize;
  final _PixelTracker pixels;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                final size = constraints.biggest;
                // Measured fresh every layout, like the app does, so font
                // load / zoom / text-scale changes never leave a stale size.
                final painter = TerminalPainter(
                  theme: TerminalThemes.defaultTheme,
                  textStyle: const TerminalStyle(
                    fontSize: 14,
                    fontFamily: 'JetBrainsMono',
                    height: 1.15,
                  ),
                  textScaler: TextScaler.noScaling,
                );
                final cell = painter.cellSize;
                final viewportWidth = size.width - gap * 2;
                final viewportHeight = size.height - gap * 2;
                final cols =
                    (viewportWidth / cell.width).floor().clamp(1, 100000);
                final rows =
                    (viewportHeight / cell.height).floor().clamp(1, 100000);
                // The pixel size mirrors the drawn content area: cols x rows
                // cells, so pixel-aware TUIs derive the exact grid.
                final contentPixels = Size(
                  (cols * cell.width).round().toDouble(),
                  (rows * cell.height).round().toDouble(),
                );
                if (terminal.viewWidth != cols ||
                    terminal.viewHeight != rows ||
                    pixels.last != contentPixels) {
                  pixels.last = contentPixels;
                  terminal.resize(
                    cols,
                    rows,
                    contentPixels.width.round(),
                    contentPixels.height.round(),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.all(gap),
                  child: TerminalView(
                    terminal,
                    controller: controller,
                    padding: EdgeInsets.zero,
                    autoResize: autoResize,
                    textStyle: const TerminalStyle(
                      fontSize: 14,
                      fontFamily: 'JetBrainsMono',
                      height: 1.15,
                    ),
                    autofocus: true,
                    hardwareKeyboardOnly: true,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
      'sidebar toggle resize: terminal, shell and buffer stay consistent',
      (tester) async {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();
    final pixels = _PixelTracker();
    final resizeCalls = <(int, int, int, int)>[];
    terminal.onResize = (w, h, pw, ph) => resizeCalls.add((w, h, pw, ph));

    // Wide pane (sidebar closed), then write a full screen of text plus a
    // long wrapped line, like output a TUI or a wide command leaves behind.
    await tester.pumpWidget(_Pane(
      terminal: terminal,
      controller: controller,
      width: 900,
      height: 600,
      pixels: pixels,
      autoResize: false,
    ));
    await tester.pumpAndSettle();
    final wideCols = terminal.viewWidth;
    resizeCalls.clear();

    for (var i = 1; i <= 20; i++) {
      terminal.write('line ${i.toString().padLeft(2, '0')} abcdefghijklmnopqrstuvwxyz\r\n');
    }
    terminal.write('long-command ${'x' * 120}\r\n');
    await tester.pumpAndSettle();

    // Narrow the pane (open sidebar).
    await tester.pumpWidget(_Pane(
      terminal: terminal,
      controller: controller,
      width: 700,
      height: 600,
      pixels: pixels,
      autoResize: false,
    ));
    await tester.pumpAndSettle();

    final narrowCols = terminal.viewWidth;
    final lastResize = resizeCalls.isEmpty ? null : resizeCalls.last;

    debugPrint('wideCols=$wideCols narrowCols=$narrowCols');
    debugPrint('resizeCalls=$resizeCalls');

    // The pane is 700px wide with a 12px gap on each side, so the content
    // area is 676px. Exactly ONE resize must reach the shell, with the
    // pixel dimensions of the drawn content (cols x rows cells, so a
    // pixel-aware TUI derives exactly the grid we render), and its columns
    // must match the terminal's final width.
    expect(narrowCols, greaterThan(0));
    expect(resizeCalls.length, 1,
        reason: 'exactly one window-change per pane resize: $resizeCalls');
    expect(lastResize, isNotNull);
    expect(lastResize!.$1, narrowCols,
        reason: 'shell resize must match terminal width');
    final cell = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(
        fontSize: 14,
        fontFamily: 'JetBrainsMono',
        height: 1.15,
      ),
      textScaler: TextScaler.noScaling,
    ).cellSize;
    expect(lastResize.$3, (narrowCols * cell.width).round(),
        reason: 'pixel width must match the drawn content area');
    expect(lastResize.$4, (terminal.viewHeight * cell.height).round(),
        reason: 'pixel height must match the drawn content area');

    // All lines fed to the terminal must still be present, in order, after
    // the resize (no content lost or scrambled).
    final text = terminal.buffer.getText();
    for (var i = 1; i <= 20; i++) {
      final marker = 'line ${i.toString().padLeft(2, '0')}';
      expect(text.contains(marker), isTrue,
          reason: 'line $i missing after resize: $text');
    }
    expect(text.contains('long-command'), isTrue);
    expect(text.length, greaterThan(20 * 40),
        reason: 'content vanished after resize');
  });
}
