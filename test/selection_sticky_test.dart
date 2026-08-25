import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('selection survives a TUI refresh that detaches the anchors', () {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();
    terminal.write('alpha beta gamma\n');
    terminal.write('delta epsilon zeta\n');

    // Apply a selection the same way the renderer does.
    final base =
        terminal.buffer.createAnchorFromOffset(const CellOffset(0, 0));
    final extent =
        terminal.buffer.createAnchorFromOffset(const CellOffset(5, 0));
    controller.setSelection(base, extent);
    final range = controller.selection;
    controller.updateSelectionSnapshot(
      range: range,
      text: range == null ? null : terminal.buffer.getText(range),
    );
    expect(controller.selection, isNotNull);
    expect(controller.selectionText, 'alpha');

    // A full redraw clears the buffer and replaces every line, which
    // detaches the selection anchors (this is what kills the selection
    // while a moving TUI like htop or watch refreshes).
    terminal.buffer.clear();
    terminal.write('a b c\n');
    terminal.write('d e f\n');

    expect(controller.selection, isNull);
    expect(controller.frozenRange, isNotNull);
    expect(controller.selectionText, 'alpha');
  });

  test('clearing the selection drops the live range but keeps frozen text for copy', () {
    final terminal = Terminal(maxLines: 1000);
    final controller = TerminalController();
    terminal.write('one two three\n');

    final base =
        terminal.buffer.createAnchorFromOffset(const CellOffset(0, 0));
    final extent =
        terminal.buffer.createAnchorFromOffset(const CellOffset(3, 0));
    controller.setSelection(base, extent);
    final range = controller.selection;
    controller.updateSelectionSnapshot(
      range: range,
      text: range == null ? null : terminal.buffer.getText(range),
    );
    expect(controller.selectionText, 'one');

    controller.clearSelection();
    // The frozen text persists so copy still works after a TUI redraw
    // or an accidental tap clears the live selection.
    expect(controller.selectionText, 'one');
    expect(controller.frozenRange, isNull);
  });
}
