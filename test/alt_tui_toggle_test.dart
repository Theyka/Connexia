import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('alt-buffer TUI with CJK stays clean across sidebar toggles', (
    tester,
  ) async {
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
        terminal.resize(
          cols,
          rows,
          content.width.round(),
          content.height.round(),
        );
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

    const esc = '\x1b';
    void drawTui() {
      final w = terminal.viewWidth;
      final h = terminal.viewHeight;
      final b = StringBuffer('$esc[?1049h$esc[H$esc[2J');
      for (var row = 0; row < h; row++) {
        if (row > 0) b.write('\r\n');
        b.write('$esc[2K');
        final label = row == 0
            ? 'header CJK: 状态 CPU 内存'
            : 'row${row.toString().padLeft(2, '0')} 进程 数据 ${'y' * (w - 16)}';
        final bytes = label.codeUnits;
        var written = 0;
        final out = StringBuffer();
        for (final unit in bytes) {
          if (written >= w) break;
          out.writeCharCode(unit);
          written += 1;
        }
        b.write(out);
      }
      terminal.write(b.toString());
    }

    await tester.pumpWidget(pane(900, 600));
    await tester.pumpAndSettle();
    drawTui();
    await tester.pumpAndSettle();

    await tester.pumpWidget(pane(640, 600));
    await tester.pumpAndSettle();
    drawTui();
    await tester.pumpAndSettle();

    await tester.pumpWidget(pane(900, 600));
    await tester.pumpAndSettle();
    drawTui();
    await tester.pumpAndSettle();

    final text = terminal.buffer.getText();
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    debugPrint('view=${terminal.viewWidth}x${terminal.viewHeight}');
    debugPrint('ALT TEXT:\n$text');

    expect(
      text.contains('?'),
      isFalse,
      reason: 'alt screen contains placeholder garbage',
    );

    expect(
      lines.any((l) => l.startsWith('header')),
      isTrue,
      reason: 'header missing after toggles',
    );

    expect(text.contains('状态'), isTrue, reason: 'CJK text corrupted');
    expect(text.contains('CPU'), isTrue);
  });

  testWidgets(
    'narrow->wide resize never resurfaces stale content at the right edge',
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

      void sync(Size size) {
        final cell = measure();
        const gap = 12.0;
        final viewportWidth = size.width - gap * 2;
        final viewportHeight = size.height - gap * 2;
        final cols = (viewportWidth / cell.width).floor().clamp(1, 100000);
        final rows = (viewportHeight / cell.height).floor().clamp(1, 100000);
        terminal.resize(
          cols,
          rows,
          (cols * cell.width).round(),
          (rows * cell.height).round(),
        );
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

      await tester.pumpWidget(pane(900, 600));
      await tester.pumpAndSettle();
      final wideCols = terminal.viewWidth;
      terminal.write('\x1b[?1049h\x1b[H\x1b[2J');
      terminal.write('${'A' * wideCols}\r\n');
      terminal.write('${'B' * wideCols}\r\n');

      await tester.pumpWidget(pane(640, 600));
      await tester.pumpAndSettle();
      final narrowCols = terminal.viewWidth;
      terminal.write('\x1b[2J\x1b[H');
      terminal.write('${'a' * narrowCols}\r\n');
      terminal.write('${'b' * narrowCols}\r\n');

      await tester.pumpWidget(pane(900, 600));
      await tester.pumpAndSettle();
      final text = terminal.buffer.getText();
      final lastTwo = text
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      final first = lastTwo.length > 1 ? lastTwo[lastTwo.length - 2] : '';
      final second = lastTwo.isEmpty ? '' : lastTwo.last;
      debugPrint(
        'wide=$wideCols narrow=$narrowCols last lines: $first / $second',
      );

      expect(
        first.trim().length,
        narrowCols,
        reason: 'row 1 must end at the narrow width, tail blank: "$first"',
      );
      expect(
        second.trim().length,
        narrowCols,
        reason: 'row 2 must end at the narrow width, tail blank: "$second"',
      );
    },
  );
}
