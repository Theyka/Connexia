import 'package:flutter/material.dart';

/// Shows a popup menu anchored at a [globalPosition] on screen.
///
/// `showMenu` positions the menu relative to the nearest navigator's overlay.
/// The app hosts its screens in a nested navigator below the mobile title bar
/// (or the custom window title bar on desktop), so screen-global coordinates
/// would render the menu too low. This helper converts the position into the
/// overlay's coordinate space first.
Future<T?> showContextMenuAt<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<PopupMenuEntry<T>> items,
  Offset offset = const Offset(0, 16),
  T? initialValue,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final local = overlay.globalToLocal(globalPosition) - offset;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      local.dx,
      local.dy,
    ),
    items: items,
    initialValue: initialValue,
  );
}
