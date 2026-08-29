import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  DragStartDetails? _lastDragStartDetails;

  LongPressStartDetails? _lastLongPressStartDetails;

  /// The cell where the drag selection started, captured once. Re-resolving
  /// it from a fixed pixel position on every update would make the selection
  /// base drift whenever auto-scroll moves the viewport mid-drag.
  CellOffset? _dragBaseCell;

  /// Timer driving the auto-scroll while the pointer is held outside the
  /// visible viewport during a drag selection.
  Timer? _autoScrollTimer;

  /// Sign of the current auto-scroll direction (1 = down, -1 = up, 0 = off).
  int _autoScrollDirection = 0;

  /// Most recent pointer position during a drag, used while auto-scrolling to
  /// keep extending the selection as the viewport moves.
  Offset? _dragPosition;

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      child: widget.child,
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onSecondaryTapDown,
      onTertiaryTapUp: onSecondaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      // onLongPressUp: onLongPressUp,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDragEnd: onDragEnd,
      onDoubleTapDown: onDoubleTapDown,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.right);
  }

  void onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressStart(LongPressStartDetails details) {
    _lastLongPressStartDetails = details;
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    renderTerminal.selectWord(
      _lastLongPressStartDetails!.localPosition,
      details.localPosition,
    );
  }

  // void onLongPressUp() {}

  void onDragStart(DragStartDetails details) {
    _lastDragStartDetails = details;
    _dragPosition = details.localPosition;
    _dragBaseCell = renderTerminal.getCellOffset(details.localPosition);

    details.kind == PointerDeviceKind.mouse
        ? renderTerminal.selectCharacters(details.localPosition)
        : renderTerminal.selectWord(details.localPosition);
  }

  void onDragUpdate(DragUpdateDetails details) {
    _dragPosition = details.localPosition;
    _updateAutoScroll(details.localPosition);

    final base = _dragBaseCell;
    if (base != null) {
      final extent = renderTerminal.getCellOffset(details.localPosition);
      renderTerminal.selectCharactersFromCells(base, extent);
    } else {
      renderTerminal.selectCharacters(
        _lastDragStartDetails!.localPosition,
        details.localPosition,
      );
    }
  }

  void onDragEnd(DragEndDetails details) {
    _stopAutoScroll();
    _dragBaseCell = null;
    _dragPosition = null;
  }

  void _updateAutoScroll(Offset position) {
    final size = renderTerminal.size;
    final lineHeight = renderTerminal.lineHeight;
    if (size.height <= 0 || lineHeight <= 0) return;

    const scrollMarginFactor = 0.5;
    final margin = lineHeight * scrollMarginFactor;

    if (position.dy > size.height - margin) {
      // pointer near or below the bottom edge — scroll down
      if (_autoScrollDirection != 1) {
        _startAutoScroll(1);
      }
    } else if (position.dy < margin) {
      // pointer near or above the top edge — scroll up
      if (_autoScrollDirection != -1) {
        _startAutoScroll(-1);
      }
    } else {
      // within the visible area — stop auto-scroll
      if (_autoScrollDirection != 0) {
        _stopAutoScroll();
      }
    }
  }

  void _startAutoScroll(int direction) {
    _stopAutoScroll();
    _autoScrollDirection = direction;
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) {
        final step = direction * 3.0;
        terminalView.scrollBy(step);
        // recompute the extent cell so the selection follows the scroll
        final pos = _dragPosition;
        if (pos != null) {
          final base = _dragBaseCell;
          if (base != null) {
            final extent = renderTerminal.getCellOffset(pos);
            renderTerminal.selectCharactersFromCells(base, extent);
          }
        }
      },
    );
  }

  void _stopAutoScroll() {
    _autoScrollDirection = 0;
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  @override
  void dispose() {
    _stopAutoScroll();
    super.dispose();
  }
}
