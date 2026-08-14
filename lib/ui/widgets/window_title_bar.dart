import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/ssh/session_manager.dart';
import '../state/nav.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';

/// Custom window chrome bar: terminal session tabs on the left,
/// minimize / maximize / close on the right. Replaces the native title bar
/// and the separate Terminals section.
class WindowTitleBar extends ConsumerStatefulWidget {
  const WindowTitleBar({super.key});

  @override
  ConsumerState<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends ConsumerState<WindowTitleBar>
    with WindowListener {
  static const _sizeKey = 'windowSize';
  static const _positionKey = 'windowPosition';
  static const _maximizedKey = 'windowMaximized';

  bool _maximized = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refreshMaximized();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowResize() {
    _scheduleWindowSave();
  }

  @override
  void onWindowMove() {
    _scheduleWindowSave();
  }

  @override
  void onWindowMaximize() {
    setState(() => _maximized = true);
    _scheduleWindowSave();
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _maximized = false);
    _scheduleWindowSave();
  }

  void _scheduleWindowSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      final db = ref.read(appDatabaseProvider);
      if (await windowManager.isMaximized()) {
        // Remember the maximized state; the restored (normal) bounds are
        // saved once the window is unmaximized.
        await db.setSetting(_maximizedKey, 'true');
        return;
      }
      final bounds = await windowManager.getBounds();
      await db.setSetting(
        _sizeKey,
        '${bounds.width.round()}x${bounds.height.round()}',
      );
      await db.setSetting(
        _positionKey,
        '${bounds.left.round()},${bounds.top.round()}',
      );
      await db.setSetting(_maximizedKey, 'false');
    });
  }

  Future<void> _refreshMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && maximized != _maximized) {
      setState(() => _maximized = maximized);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(sessionManagerProvider);
    final sessions = manager.sessions;
    final activeId = manager.activeSessionId;
    final section = ref.watch(appSectionProvider);
    final inTerminals = section == AppSection.terminals;

    // The whole bar is a drag region so the window can be moved from
    // anywhere, even when the bar is completely filled with server tabs.
    // Buttons and tabs stay fully clickable (taps win over pan gestures).
    return _DragRegion(
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  _TitleBarLabelButton(
                    icon: Icons.home_outlined,
                    label: 'Home',
                    selected: section == AppSection.hosts,
                    onTap: () => ref
                        .read(appSectionProvider.notifier)
                        .state = AppSection.hosts,
                  ),
                  _TitleBarLabelButton(
                    icon: Icons.swap_horiz,
                    label: 'SFTP',
                    selected: section == AppSection.sftp,
                    onTap: () => _openSftp(),
                  ),
                  if (sessions.isEmpty)
                    const Expanded(child: SizedBox.expand())
                  else ...[
                    const _TabDivider(),
                    Expanded(
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: sessions.length,
                        itemBuilder: (context, index) {
                          final session = sessions[index];
                          final selected =
                              inTerminals && session.id == activeId;
                          return _SessionTab(
                            session: session,
                            selected: selected,
                            onTap: () =>
                                _selectSession(manager, session.id),
                            onClose: () => manager.closeSession(session),
                            onReconnect: () => manager.reconnect(session),
                            onDuplicate: () =>
                                manager.duplicateSession(session),
                            onRename: (label) =>
                                manager.renameSession(session, label),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _SidebarToggleButton(),
            _TitleBarButton(
              icon: Icons.remove,
              tooltip: 'Minimize',
              onTap: () => windowManager.minimize(),
            ),
            _TitleBarButton(
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              tooltip: _maximized ? 'Restore' : 'Maximize',
              onTap: () => _toggleMaximize(),
            ),
            _TitleBarButton(
              icon: Icons.close,
              tooltip: 'Close',
              closeButton: true,
              onTap: () => windowManager.close(),
            ),
          ],
        ),
      ),
    );
  }

  void _selectSession(SessionManager manager, String id) {
    manager.activeSessionId = id;
    ref.read(appSectionProvider.notifier).state = AppSection.terminals;
  }

  void _openSftp() {
    ref.read(appSectionProvider.notifier).state = AppSection.sftp;
  }

  Future<void> _toggleMaximize() async {
    if (_maximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }
}

class _DragRegion extends StatelessWidget {
  final Widget child;

  const _DragRegion({required this.child});

  @override
  Widget build(BuildContext context) {
    // The whole bar is a drag region so the window can be moved from
    // anywhere, even when the bar is completely filled with server tabs.
    // Buttons and tabs stay fully clickable (taps win over pan gestures).
    // No double-tap-to-maximize here: rapid clicks on tab close buttons
    // would otherwise toggle the window size.
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: child,
      ),
    );
  }
}

/// Invisible resize grips pinned to the top edge of the frameless window.
/// A hidden title bar removes the native caption, so the top of the window
/// is fully covered by Flutter content and the OS resize band never gets
/// the pointer. These grips restore it: the strip resizes vertically, the
/// corners resize diagonally (both width and height) from the top side.
class WindowResizeHandles extends StatelessWidget {
  const WindowResizeHandles({super.key});

  static const double _strip = 6;
  static const double _corner = 10;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _strip,
          child: _ResizeHandle(
            edge: ResizeEdge.top,
            cursor: SystemMouseCursors.resizeUpDown,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          width: _corner,
          height: _corner,
          child: _ResizeHandle(
            edge: ResizeEdge.topLeft,
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          width: _corner,
          height: _corner,
          child: _ResizeHandle(
            edge: ResizeEdge.topRight,
            cursor: SystemMouseCursors.resizeUpRightDownLeft,
          ),
        ),
      ],
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  final ResizeEdge edge;
  final MouseCursor cursor;

  const _ResizeHandle({required this.edge, required this.cursor});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: Listener(
        onPointerDown: (_) => windowManager.startResizing(edge),
        behavior: HitTestBehavior.opaque,
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SessionTab extends StatefulWidget {
  final TerminalSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onReconnect;
  final VoidCallback onDuplicate;
  final ValueChanged<String> onRename;

  const _SessionTab({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onClose,
    required this.onReconnect,
    required this.onDuplicate,
    required this.onRename,
  });

  @override
  State<_SessionTab> createState() => _SessionTabState();
}

class _SessionTabState extends State<_SessionTab> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _editing = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startRename() {
    _controller.text = widget.session.label;
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _commit() {
    if (!_editing) return;
    widget.onRename(_controller.text);
    setState(() => _editing = false);
  }

  void _cancel() {
    if (!_editing) return;
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    // Panning on a tab moves the window (a tap still selects the tab);
    // this keeps the window draggable even when the bar is full of tabs.
    // Double-tap rename lives on the label only (below), so rapid clicks
    // on the close button never start a rename and taps stay immediate.
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: InkWell(
        onTap: _editing ? null : widget.onTap,
        onSecondaryTapDown: _editing
            ? null
            : (details) =>
                _showContextMenu(context, details.globalPosition),
        child: Container(
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppColors.surfaceAlt
                : Colors.transparent,
            // A status-colored underline on every tab, visible in every
            // section (terminals, Home, SFTP, ...).
            border: Border(
              bottom: BorderSide(
                color: sessionStatusColor(widget.session.status),
                width: 2,
              ),
            ),
          ),
          child: TapRegion(
            onTapOutside: (_) => _commit(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TabCloseButton(onTap: widget.onClose),
                const SizedBox(width: 6),
                GestureDetector(
                  onDoubleTap: _editing ? null : _startRename,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Opacity(
                        opacity: _editing ? 0 : 1,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 150),
                          child: Text(
                            widget.session.label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.0,
                              color: widget.selected
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                      if (_editing)
                        Positioned.fill(child: _buildEditor()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEditor() {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _cancel();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          _commit();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: EditableText(
        controller: _controller,
        focusNode: _focusNode,
        style: TextStyle(
          fontSize: 12,
          height: 1.0,
          color: widget.selected
              ? AppColors.textPrimary
              : AppColors.textSecondary,
        ),
        cursorColor: AppColors.accent,
        backgroundCursorColor: AppColors.textFaint,
        selectionColor: AppColors.accent.withValues(alpha: 0.25),
        maxLines: 1,
        onSubmitted: (_) => _commit(),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: [
        if (widget.session.status == SessionStatus.error ||
            widget.session.status == SessionStatus.disconnected)
          const PopupMenuItem(
            value: 'reconnect',
            child: Text('Reconnect'),
          ),
        const PopupMenuItem(
          value: 'duplicate',
          child: Text('Duplicate'),
        ),
        const PopupMenuItem(
          value: 'rename',
          child: Text('Rename'),
        ),
        const PopupMenuItem(
          value: 'close',
          child: Text('Close'),
        ),
      ],
    );
    switch (action) {
      case 'reconnect':
        widget.onReconnect();
        break;
      case 'duplicate':
        widget.onDuplicate();
        break;
      case 'rename':
        _startRename();
        break;
      case 'close':
        widget.onClose();
        break;
    }
  }
}

/// Connection status color used for the underline on session tabs.
Color sessionStatusColor(SessionStatus status) {
  switch (status) {
    case SessionStatus.connecting:
    case SessionStatus.verifyingHostKey:
      return AppColors.warning;
    case SessionStatus.connected:
      return AppColors.success;
    case SessionStatus.error:
    case SessionStatus.disconnected:
      return AppColors.danger;
  }
}

class _SidebarToggleButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inTerminals =
        ref.watch(appSectionProvider) == AppSection.terminals;
    if (!inTerminals) return const SizedBox.shrink();
    final open = ref.watch(terminalSnippetsOpenProvider);
    return _TitleBarButton(
      icon: open ? Icons.menu_open : Icons.menu,
      iconSize: 17,
      tooltip: open ? 'Hide snippets panel' : 'Show snippets panel',
      onTap: () {
        ref.read(terminalSnippetsOpenProvider.notifier).state = !open;
      },
    );
  }
}

class _TitleBarLabelButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  const _TitleBarLabelButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = selected
        ? AppColors.textPrimary
        : enabled
            ? AppColors.textSecondary
            : AppColors.textFaint;
    return InkWell(
      onTap: onTap,
      child: MouseRegion(
        cursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.surfaceAlt : Colors.transparent,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabDivider extends StatelessWidget {
  const _TabDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: AppColors.border,
    );
  }
}

class _TitleBarButton extends StatefulWidget {
  final IconData icon;
  final double iconSize;
  final String tooltip;
  final bool closeButton;
  final VoidCallback onTap;

  const _TitleBarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconSize = 14,
    this.closeButton = false,
  });

  @override
  State<_TitleBarButton> createState() => _TitleBarButtonState();
}

class _TitleBarButtonState extends State<_TitleBarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = Icon(
      widget.icon,
      size: widget.iconSize,
      color: widget.closeButton && _hovered
          ? Colors.white
          : AppColors.textSecondary,
    );
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            width: 44,
            height: double.infinity,
            color: _hovered
                ? widget.closeButton
                    ? const Color(0xFFE81123)
                    : AppColors.surfaceAlt
                : Colors.transparent,
            child: Center(child: glyph),
          ),
        ),
      ),
    );
  }
}

class _TabCloseButton extends StatefulWidget {
  final VoidCallback onTap;

  const _TabCloseButton({required this.onTap});

  @override
  State<_TabCloseButton> createState() => _TabCloseButtonState();
}

class _TabCloseButtonState extends State<_TabCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: 'Close session',
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: _hovered ? AppColors.cardHover : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _hovered ? AppColors.borderStrong : Colors.transparent,
              ),
            ),
            child: Icon(
              Icons.close,
              size: 13,
              color: _hovered ? AppColors.danger : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
