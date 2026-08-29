import 'package:flutter/material.dart';
import 'package:meta/meta.dart';
import 'package:xterm/src/base/disposable.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/range_block.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class TerminalController with ChangeNotifier {
  TerminalController({
    SelectionMode selectionMode = SelectionMode.line,
    PointerInputs pointerInputs = const PointerInputs({PointerInput.tap}),
    bool suspendPointerInput = false,
  })  : _selectionMode = selectionMode,
        _pointerInputs = pointerInputs,
        _suspendPointerInputs = suspendPointerInput;

  CellAnchor? _selectionBase;
  CellAnchor? _selectionExtent;

  SelectionMode get selectionMode => _selectionMode;
  SelectionMode _selectionMode;

  /// The set of pointer events which will be used as mouse input for the terminal.
  PointerInputs get pointerInput => _pointerInputs;
  PointerInputs _pointerInputs;

  /// True if sending pointer events to the terminal is suspended.
  bool get suspendedPointerInputs => _suspendPointerInputs;
  bool _suspendPointerInputs;

  List<TerminalHighlight> get highlights => _highlights;
  final _highlights = <TerminalHighlight>[];

  BufferRange? get selection {
    final base = _selectionBase;
    final extent = _selectionExtent;

    if (base == null || extent == null) {
      return null;
    }

    if (!base.attached || !extent.attached) {
      return null;
    }

    return _createRange(base.offset, extent.offset);
  }

  /// Set selection on the terminal from [base] to [extent]. This method takes
  /// the ownership of [base] and [extent] and will dispose them when the
  /// selection is cleared or changed.
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    _selectionBase?.dispose();
    _selectionBase = base;

    _selectionExtent?.dispose();
    _selectionExtent = extent;

    if (mode != null) {
      _selectionMode = mode;
    }

    notifyListeners();
  }

  BufferRange _createRange(CellOffset begin, CellOffset end) {
    switch (selectionMode) {
      case SelectionMode.line:
        return BufferRangeLine(begin, end);
      case SelectionMode.block:
        return BufferRangeBlock(begin, end);
    }
  }

  /// Controls how the terminal behaves when the user selects a range of text.
  /// The default is [SelectionMode.line]. Setting this to [SelectionMode.block]
  /// enables block selection mode.
  void setSelectionMode(SelectionMode newSelectionMode) {
    // If the new mode is the same as the old mode,
    // nothing has to be changed.
    if (_selectionMode == newSelectionMode) {
      return;
    }
    // Set the new mode.
    _selectionMode = newSelectionMode;
    notifyListeners();
  }

  BufferRange? _frozenRange;
  String? _frozenText;
  int _frozenAbsoluteStartIndex = 0;

  /// The last applied selection range, frozen as plain cell offsets. Unlike
  /// [selection] it survives terminal refreshes that detach the anchors, so
  /// the highlight and the copied text stay stable while a TUI redraws.
  BufferRange? get frozenRange => _frozenRange;

  /// The text of the last applied selection, frozen at selection time. Copy
  /// can use it even after the terminal refreshes and [selection] is gone.
  String? get selectionText => _frozenText;

  /// The buffer's absolute start index when the frozen snapshot was captured.
  /// If lines were trimmed from the top afterwards, the snapshot's cell
  /// offsets must be shifted by the difference to keep the highlight on the
  /// originally selected content.
  int get frozenAbsoluteStartIndex => _frozenAbsoluteStartIndex;

  /// Refreshes the frozen selection snapshot. Called by the renderer every
  /// time a selection is applied.
  void updateSelectionSnapshot({
    BufferRange? range,
    String? text,
    int? absoluteStartIndex,
  }) {
    _frozenRange = range;
    _frozenText = text;
    if (absoluteStartIndex != null) {
      _frozenAbsoluteStartIndex = absoluteStartIndex;
    }
  }

  /// The frozen selection range shifted to match the current buffer state.
  ///
  /// The snapshot is captured with logical line indices at selection time. If
  /// lines were later trimmed from the top of the circular buffer (scrollback
  /// overflow), those indices no longer point at the originally selected
  /// content — the highlight would paint over unrelated lines (or the top of
  /// the selection would visually vanish). Shifting by the absolute start
  /// delta keeps the highlight on the selected content for as long as it
  /// survives in the buffer.
  BufferRange? effectiveFrozenRange(int currentAbsoluteStartIndex) {
    final range = _frozenRange;
    if (range == null) return null;
    final delta = currentAbsoluteStartIndex - _frozenAbsoluteStartIndex;
    if (delta == 0) return range;

    final beginY = range.begin.y - delta;
    final endY = range.end.y - delta;

    // The whole selection was trimmed out of the buffer; nothing to paint.
    if (beginY < 0 && endY < 0) return null;

    return _createRange(
      CellOffset(range.begin.x, beginY < 0 ? 0 : beginY),
      CellOffset(range.end.x, endY < 0 ? 0 : endY),
    );
  }

  /// Clears the current selection. The frozen text ([selectionText]) is kept
  /// so copy still works after a TUI redraw or an accidental tap clears the
  /// live selection anchors. A new selection overwrites it.
  void clearSelection() {
    _selectionBase?.dispose();
    _selectionBase = null;
    _selectionExtent?.dispose();
    _selectionExtent = null;
    _frozenRange = null;
    notifyListeners();
  }

  // Select which type of pointer events are send to the terminal.
  void setPointerInputs(PointerInputs pointerInput) {
    _pointerInputs = pointerInput;
    notifyListeners();
  }

  // Toggle sending pointer events to the terminal.
  void setSuspendPointerInput(bool suspend) {
    _suspendPointerInputs = suspend;
    notifyListeners();
  }

  // Returns true if this type of PointerInput should be send to the Terminal.
  @internal
  bool shouldSendPointerInput(PointerInput pointerInput) {
    // Always return false if pointer input is suspended.
    return _suspendPointerInputs
        ? false
        : _pointerInputs.inputs.contains(pointerInput);
  }

  /// Creates a new highlight on the terminal from [p1] to [p2] with the given
  /// [color]. The highlight will be removed when the returned object is
  /// disposed.
  TerminalHighlight highlight({
    required CellAnchor p1,
    required CellAnchor p2,
    required Color color,
  }) {
    final highlight = TerminalHighlight(
      this,
      p1: p1,
      p2: p2,
      color: color,
    );

    _highlights.add(highlight);
    notifyListeners();

    highlight.registerCallback(() {
      _highlights.remove(highlight);
      notifyListeners();
    });

    return highlight;
  }
}

class TerminalHighlight with Disposable {
  final TerminalController owner;

  final CellAnchor p1;

  final CellAnchor p2;

  final Color color;

  TerminalHighlight(
    this.owner, {
    required this.p1,
    required this.p2,
    required this.color,
  });

  /// Returns the range of the highlight. May be null if the anchors that
  /// define the highlight are not attached to the terminal.
  BufferRange? get range {
    if (!p1.attached || !p2.attached) {
      return null;
    }
    return BufferRangeLine(p1.offset, p2.offset);
  }
}
