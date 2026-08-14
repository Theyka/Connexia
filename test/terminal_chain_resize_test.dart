import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 40,
      child: ColoredBox(color: Colors.black),
    );
  }
}

/// Mirrors Connexia's `_TerminalPane`: re-asserts the terminal viewport size
/// from the pane's actual size on every layout.
class _Pane extends StatefulWidget {
  final Terminal terminal;
  final TerminalController controller;
  final FocusNode focusNode;

  const _Pane({
    required this.terminal,
    required this.controller,
    required this.focusNode,
  });

  @override
  State<_Pane> createState() => _PaneState();
}

class _PaneState extends State<_Pane> {
  TerminalPainter? _cellPainter;

  void _syncViewportSize(BuildContext context, Size size) {
    final painter = _cellPainter ??=
        TerminalPainter(
          theme: TerminalThemes.defaultTheme,
          textStyle: const TerminalStyle(
            fontSize: 12,
            fontFamily: 'JetBrainsMono',
            height: 1.15,
          ),
          textScaler: MediaQuery.textScalerOf(context),
        );
    final cell = painter.cellSize;
    if (cell.width <= 0 || cell.height <= 0) return;
    final cols = (size.width / cell.width).floor().clamp(1, 100000);
    final rows = (size.height / cell.height).floor().clamp(1, 100000);
    if (widget.terminal.viewWidth != cols ||
        widget.terminal.viewHeight != rows) {
      widget.terminal.resize(
        cols,
        rows,
        size.width.round(),
        size.height.round(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _syncViewportSize(context, constraints.biggest);
        return Stack(
          children: [
            Positioned.fill(
              child: TerminalView(
                widget.terminal,
                controller: widget.controller,
                focusNode: widget.focusNode,
                theme: TerminalThemes.defaultTheme,
                textStyle: const TerminalStyle(
                  fontSize: 12,
                  fontFamily: 'JetBrainsMono',
                  height: 1.15,
                ),
                hardwareKeyboardOnly: true,
              ),
            ),
          ],
        );
      },
    );
  }
}

void main() {
  testWidgets('terminal pane follows window resize', (tester) async {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const _TitleBar(),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: IndexedStack(
                        index: 0,
                        children: [
                          _Pane(
                            terminal: terminal,
                            controller: controller,
                            focusNode: focusNode,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final w0 = terminal.viewWidth;
    final h0 = terminal.viewHeight;
    expect(w0, greaterThan(40), reason: 'initial layout should resize');

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    await tester.pump();

    final w1 = terminal.viewWidth;
    final h1 = terminal.viewHeight;
    expect(w1, greaterThan(w0),
        reason: 'growing the window must grow the terminal width '
            '(was $w0 -> $w1)');
    expect(h1, greaterThan(h0),
        reason: 'growing the window must grow the terminal height');

    tester.view.physicalSize = const Size(640, 400);
    await tester.pump();

    expect(terminal.viewWidth, lessThan(w1),
        reason: 'shrinking the window must shrink the terminal width');
    expect(terminal.viewHeight, lessThan(h1),
        reason: 'shrinking the window must shrink the terminal height');

    focusNode.dispose();
  });

  testWidgets('terminal keeps sizing when the resize callback throws',
      (tester) async {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();
    final focusNode = FocusNode();
    var calls = 0;
    terminal.onResize = (w, h, _, _) {
      calls++;
      throw StateError('boom');
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Pane(
            terminal: terminal,
            controller: controller,
            focusNode: focusNode,
          ),
        ),
      ),
    );
    await tester.pump();

    final w0 = terminal.viewWidth;
    expect(w0, greaterThan(40),
        reason: 'the terminal buffer must resize even when onResize throws');

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    await tester.pump();

    expect(terminal.viewWidth, greaterThan(w0),
        reason: 'buffer must keep growing despite the throwing callback');
    expect(calls, greaterThan(0), reason: 'the callback must have fired');

    focusNode.dispose();
  });
}
