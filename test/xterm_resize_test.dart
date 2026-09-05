import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Regression tests for the vendored xterm resize path: a null-check
/// crash during resize (with btop-like alt-screen content) used to paint
/// an unrecoverable gray screen in release builds.
void main() {
  Terminal makeBtopLike() {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    // btop: alternate screen, scroll margins, full-width redraws.
    terminal.write('\x1b[?1049h');
    terminal.write('\x1b[2J');
    terminal.write('\x1b[1;23r');
    for (var row = 1; row <= 23; row++) {
      terminal.write('\x1b[$row;1H');
      terminal.write('x' * 79 + 'y');
      terminal.write('\x1b[K');
    }
    return terminal;
  }

  test('alt-screen resize storm does not throw', () {
    final terminal = makeBtopLike();
    final sizes = <List<int>>[
      [100, 30],
      [120, 36],
      [140, 40],
      [90, 28],
      [60, 20],
      [110, 32],
      [70, 22],
      [130, 38],
      [50, 16],
      [40, 12],
      [200, 50],
      [30, 10],
      [80, 24],
    ];
    for (final size in sizes) {
      terminal.resize(size[0], size[1], size[0] * 8, size[1] * 16);
    }
    expect(terminal.viewWidth, 80);
    expect(terminal.viewHeight, 24);
  });

  test('main-buffer reflow storm does not throw', () {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(200, 50);
    for (var i = 0; i < 300; i++) {
      terminal.write('line ${i * 37} with a fairly long payload ' * 6);
      terminal.write('\r\n');
    }
    for (final size in [
      [80, 24],
      [120, 36],
      [60, 20],
      [100, 30],
      [30, 10],
      [200, 50],
    ]) {
      terminal.resize(size[0], size[1]);
    }
  });

  test('resize with a selection (anchors) does not throw', () {
    final terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    terminal.write('hello world ' * 10);
    final controller = TerminalController();
    final base = terminal.buffer.createAnchor(0, 0);
    final extent = terminal.buffer.createAnchor(40, 5);
    controller.setSelection(base, extent);
    for (final size in [
      [120, 36],
      [60, 20],
      [140, 40],
      [80, 24],
    ]) {
      terminal.resize(size[0], size[1]);
    }
  });

  test('app-like session resize storm stays consistent', () {
    // Mirror a real SSH session: full scrollback with wrapped lines
    // (so the circular buffer window is offset), then btop (alt screen
    // + margins), then a pinch-zoom-like storm of resizes including
    // extremes. Regression test for the replaceWith window-rebase bug
    // that left null slots inside the buffer.
    void expectConsistent(Terminal terminal, String stage) {
      for (final buffer in [terminal.mainBuffer, terminal.altBuffer]) {
        final lines = buffer.lines;
        for (var i = 0; i < lines.length; i++) {
          expect(
            () => lines[i],
            returnsNormally,
            reason: '$stage: null slot at index $i of '
                '${lines.length} (alt=${terminal.isUsingAltBuffer})',
          );
        }
      }
    }

    final terminal = Terminal(maxLines: 1000);
    terminal.resize(105, 90);
    for (var i = 0; i < 2500; i++) {
      terminal.write('log entry $i: ${'x' * (20 + (i % 97))}');
      terminal.write('\r\n');
    }
    expectConsistent(terminal, 'after writes');
    terminal.write('\x1b[?1049h');
    terminal.write('\x1b[2J');
    terminal.write('\x1b[1;88r');
    for (var row = 1; row <= 88; row++) {
      terminal.write('\x1b[$row;1H');
      terminal.write('m' * 104 + 'z');
      terminal.write('\x1b[K');
    }
    expectConsistent(terminal, 'after btop setup');
    final sizes = <List<int>>[
      [110, 88],
      [115, 85],
      [120, 82],
      [126, 78],
      [132, 75],
      [138, 71],
      [144, 68],
      [150, 64],
      [98, 92],
      [104, 89],
      [180, 40],
      [64, 100],
      [40, 12],
      [200, 30],
      [30, 200],
      [2, 3],
      [500, 2],
      [105, 90],
    ];
    for (final size in sizes) {
      terminal.resize(size[0], size[1], size[0] * 8, size[1] * 16);
      expectConsistent(terminal, 'after resize ${size[0]}x${size[1]}');
    }
    terminal.write('\x1b[?1049l');
    for (final size in [
      [80, 24],
      [120, 60],
      [60, 100],
      [105, 90],
      [3, 2],
      [105, 90],
    ]) {
      terminal.resize(size[0], size[1]);
      expectConsistent(terminal, 'after main resize ${size[0]}x${size[1]}');
    }
  });
}
