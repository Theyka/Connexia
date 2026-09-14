import 'package:flutter/material.dart';

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
    position: RelativeRect.fromLTRB(local.dx, local.dy, local.dx, local.dy),
    items: items,
    initialValue: initialValue,
  );
}
