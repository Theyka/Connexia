import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  for (final seed in [1, 2, 3, 7, 42, 99, 123, 2024]) {
    test('fuzz escape sequences + resize (seed $seed)', () {
      final rng = Random(seed);
      final terminal = Terminal(maxLines: 120);
      terminal.resize(80, 24);

      Object? firstError;
      String? firstErrorStage;

      void check(String stage) {
        if (firstError != null) return;
        try {
          for (final buffer in [terminal.mainBuffer, terminal.altBuffer]) {
            final lines = buffer.lines;
            expect(
              lines.length >= terminal.viewHeight,
              isTrue,
              reason:
                  '$stage: height ${lines.length} < viewHeight '
                  '${terminal.viewHeight}',
            );
            for (var i = 0; i < lines.length; i++) {
              final line = lines[i];
              for (var j = i + 1; j < lines.length; j++) {
                if (identical(line, lines[j])) {
                  fail('$stage: duplicate line at $i and $j');
                }
              }
            }
          }
          final cursorX = terminal.buffer.cursorX;
          final cursorY = terminal.buffer.cursorY;
          expect(
            cursorX >= 0 && cursorX < terminal.viewWidth,
            isTrue,
            reason: '$stage: cursorX $cursorX viewWidth ${terminal.viewWidth}',
          );
          expect(
            cursorY >= 0 && cursorY < terminal.viewHeight,
            isTrue,
            reason:
                '$stage: cursorY $cursorY viewHeight ${terminal.viewHeight}',
          );
        } catch (e) {
          firstError = e;
          firstErrorStage = stage;
        }
      }

      for (var step = 0; step < 40000 && firstError == null; step++) {
        final roll = rng.nextInt(100);
        try {
          if (roll < 60) {
            final n = 1 + rng.nextInt(6);
            for (var i = 0; i < n; i++) {
              final kind = rng.nextInt(10);
              switch (kind) {
                case 0:
                  terminal.write(String.fromCharCode(33 + rng.nextInt(90)));
                case 1:
                  terminal.write('\r\n');
                case 2:
                  terminal.write('${rng.nextInt(100)} ');
                case 3:
                  terminal.write(
                    '\x1b[${1 + rng.nextInt(40)};${1 + rng.nextInt(150)}H',
                  );
                case 4:
                  terminal.write('\x1b[${rng.nextInt(4)}J');
                case 5:
                  terminal.write('\x1b[${rng.nextInt(3)}K');
                case 6:
                  terminal.write('\x1b[${1 + rng.nextInt(5)}L');
                case 7:
                  terminal.write('\x1b[${1 + rng.nextInt(5)}M');
                case 8:
                  terminal.write(rng.nextBool() ? '\x1b7' : '\x1b8');
                case 9:
                  terminal.write('\x1b[${1 + rng.nextInt(3)}S');
              }
            }
          } else if (roll < 72) {
            terminal.write(
              '\x1b[${1 + rng.nextInt(15)};${5 + rng.nextInt(20)}r',
            );
          } else if (roll < 80) {
            terminal.write(rng.nextBool() ? '\x1b[?1049h' : '\x1b[?1049l');
          } else if (roll < 90) {
            terminal.write('y' * (1 + rng.nextInt(160)));
            terminal.write('\r\n');
          } else {
            terminal.resize(1 + rng.nextInt(200), 1 + rng.nextInt(50));
          }
        } catch (e, st) {
          firstError = '$e\n$st';
          firstErrorStage = 'step $step roll $roll';
          break;
        }
        if (step % 200 == 0) check('step $step');
      }

      if (firstError != null) {
        fail('error at $firstErrorStage: $firstError');
      }
    });
  }
}
