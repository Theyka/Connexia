import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class TerminalActions extends StatelessWidget {
  const TerminalActions({
    super.key,
    required this.terminal,
    required this.controller,
    required this.child,
  });

  final Terminal terminal;

  final TerminalController controller;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (intent) async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = data?.text;
            if (text != null) {
              terminal.paste(text);
              controller.clearSelection();
            }
            return null;
          },
        ),
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (intent) async {
            // Prefer the frozen snapshot over the live selection: it holds
            // the exact text at selection time. A TUI redraw that only clears
            // and rewrites line content (ESC[2J, as used by screen/less/htop)
            // reuses the BufferLine objects, so the selection anchors stay
            // attached and controller.selection remains non-null, but
            // terminal.buffer.getText(selection) now returns the NEW (wrong)
            // content. The frozen text is always the originally selected text.
            // Fall back to the live selection when the frozen text is empty
            // or stale (some apps like claude code redraw so fast that the
            // snapshot captures an empty/intermediate state).
            var text = controller.selectionText;
            if (text == null || text.isEmpty) {
              final selection = controller.selection;
              if (selection != null) {
                text = terminal.buffer.getText(selection);
              }
            }

            if (text == null || text.isEmpty) {
              return;
            }

            await Clipboard.setData(ClipboardData(text: text));

            return null;
          },
        ),
        SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
          onInvoke: (intent) {
            controller.setSelection(
              terminal.buffer.createAnchor(
                0,
                terminal.buffer.height - terminal.viewHeight,
              ),
              terminal.buffer.createAnchor(
                terminal.viewWidth,
                terminal.buffer.height - 1,
              ),
              mode: SelectionMode.line,
            );
            final selection = controller.selection;
            controller.updateSelectionSnapshot(
              range: selection,
              text: selection == null
                  ? null
                  : terminal.buffer.getText(selection),
            );
            return null;
          },
        ),
      },
      child: child,
    );
  }
}
