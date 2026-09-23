import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/host_protocol.dart';
import '../../core/remote/remote_session.dart';
import '../../core/ssh/session_manager.dart';
import '../state/nav.dart';
import '../state/providers.dart';
import '../screens/hosts_screen.dart' show osIcon;
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';
import 'new_output_dot.dart';

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

  static const double _barHeight = 40;

  int? _dropIndex;
  double _dropGlobalX = 0;

  final Map<String, GlobalKey> _tabKeys = {};
  final Map<String, GlobalKey> _remoteTabKeys = {};
  final GlobalKey _stripKey = GlobalKey();
  final GlobalKey _workspaceTabKey = GlobalKey();

  GlobalKey _tabKey(String sessionId) =>
      _tabKeys.putIfAbsent(sessionId, GlobalKey.new);

  GlobalKey _remoteTabKey(String sessionId) =>
      _remoteTabKeys.putIfAbsent(sessionId, GlobalKey.new);

  final ScrollController _stripScroll = ScrollController();

  double _lastTabRight = 0;
  bool showWorkspaceTabRef = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _stripScroll.addListener(_measureStrip);
    _refreshMaximized();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    windowManager.removeListener(this);
    _stripScroll.dispose();
    super.dispose();
  }

  void _measureStrip() {
    if (!mounted) return;
    final stripBox = _stripKey.currentContext?.findRenderObject() as RenderBox?;
    if (stripBox == null || (_tabOrder.isEmpty && !showWorkspaceTabRef)) {
      _setLastTabRight(0);
      return;
    }
    final stripWidth = stripBox.size.width;
    if (_stripScroll.hasClients &&
        _stripScroll.position.maxScrollExtent > 0.5) {
      _setLastTabRight(stripWidth);
      return;
    }
    double right = -1;
    void consider(GlobalKey key) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      final value = stripBox
          .globalToLocal(box.localToGlobal(Offset(box.size.width, 0)))
          .dx;
      if (value > right) right = value;
    }

    if (_tabOrder.isNotEmpty) consider(_keyFor(_tabOrder.last));
    if (showWorkspaceTabRef) consider(_workspaceTabKey);
    if (right < 0) {
      _setLastTabRight(stripWidth);
      return;
    }
    _setLastTabRight(right.clamp(0.0, stripWidth));
  }

  /// Creation time encoded in a session id. Terminal ids are
  /// `<micros>-<counter>`, remote ids are the raw `<micros>`.
  int _creationTime(String id) => int.tryParse(id.split('-').first) ?? 0;

  /// Stable display order shared by terminal and remote tabs (keys are
  /// `t:<id>` / `r:<id>`). New tabs are appended in creation order, and drag
  /// reordering mutates this list, so both kinds of tab behave identically.
  final List<String> _tabOrder = [];

  String _idOf(String tabKey) => tabKey.substring(2);

  bool _isRemoteKey(String tabKey) => tabKey.startsWith('r:');

  GlobalKey _keyFor(String tabKey) => _isRemoteKey(tabKey)
      ? _remoteTabKey(_idOf(tabKey))
      : _tabKey(_idOf(tabKey));

  /// Adds newly opened tabs and drops closed ones, keeping existing positions.
  void _reconcileTabOrder(
    List<TerminalSession> terminals,
    List<RemoteSession> remotes,
  ) {
    final keys = <String>{
      for (final terminal in terminals) 't:${terminal.id}',
      for (final remote in remotes) 'r:${remote.id}',
    };
    _tabOrder.removeWhere((key) => !keys.contains(key));
    final missing = keys.where((key) => !_tabOrder.contains(key)).toList()
      ..sort(
        (a, b) => _creationTime(_idOf(a)).compareTo(_creationTime(_idOf(b))),
      );
    _tabOrder.addAll(missing);
  }

  void _setLastTabRight(double value) {
    final clamped = value.clamp(0.0, double.maxFinite);
    if (_lastTabRight != clamped) {
      setState(() => _lastTabRight = clamped);
    }
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

  void _updateDropIndex(Offset globalPos) {
    if (_tabOrder.isEmpty) return;
    var index = _tabOrder.length;
    var dropX = 0.0;
    var found = false;
    for (var i = 0; i < _tabOrder.length; i++) {
      final box =
          _keyFor(_tabOrder[i]).currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null) continue;
      final left = box.localToGlobal(Offset.zero).dx;
      final right = left + box.size.width;
      if (globalPos.dx < right) {
        final before = globalPos.dx < left + box.size.width / 2;
        index = before ? i : i + 1;
        dropX = before ? left : right;
        found = true;
        break;
      }
    }
    if (!found) {
      final lastBox =
          _keyFor(_tabOrder.last).currentContext?.findRenderObject()
              as RenderBox?;
      if (lastBox != null) {
        index = _tabOrder.length;
        dropX = lastBox.localToGlobal(Offset(lastBox.size.width, 0)).dx;
      }
    }
    if (index != _dropIndex || dropX != _dropGlobalX) {
      setState(() {
        _dropIndex = index;
        _dropGlobalX = dropX;
      });
    }
  }

  void _commitStripDrop(String draggedId) {
    final wsIds = ref.read(workspaceSessionIdsProvider);
    final dropIndex = _dropIndex;

    if (wsIds.contains(draggedId)) {
      ref.read(workspaceSessionIdsProvider.notifier).state = wsIds
          .where((id) => id != draggedId)
          .toList();
      setState(() {
        _dropIndex = null;
        _dropGlobalX = 0;
      });
      return;
    }

    final dragKey = _tabOrder.contains('r:$draggedId')
        ? 'r:$draggedId'
        : 't:$draggedId';
    if (dropIndex != null && _tabOrder.contains(dragKey)) {
      final from = _tabOrder.indexOf(dragKey);
      var to = dropIndex.clamp(0, _tabOrder.length);
      _tabOrder.removeAt(from);
      if (to > from) to -= 1;
      _tabOrder.insert(to.clamp(0, _tabOrder.length), dragKey);
    }
    setState(() {
      _dropIndex = null;
      _dropGlobalX = 0;
    });
  }

  double _indicatorLeft(BuildContext context) {
    final stripBox = _stripKey.currentContext?.findRenderObject() as RenderBox?;
    if (stripBox == null) return 0;
    return stripBox.globalToLocal(Offset(_dropGlobalX, 0)).dx;
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(sessionManagerProvider);
    final sessions = manager.sessions;
    final activeId = manager.activeSessionId;
    final section = ref.watch(appSectionProvider);
    final inTerminals = section == AppSection.terminals;
    final wsOpen = ref.watch(workspaceOpenProvider);
    final wsIds = ref.watch(workspaceSessionIdsProvider);
    final remoteManager = ref.watch(remoteManagerProvider);
    final remoteSessions = remoteManager.sessions;

    WidgetsBinding.instance.addPostFrameCallback((_) => _measureStrip());

    final visible = [
      for (final s in sessions)
        if (!wsIds.contains(s.id)) s,
    ];

    final liveSessions = sessions.where((s) => !s.isClosed).toList();
    final wsLiveCount = wsIds
        .where((id) => liveSessions.any((s) => s.id == id))
        .length;
    final showWorkspaceTab = wsLiveCount >= 1;
    showWorkspaceTabRef = showWorkspaceTab;

    _reconcileTabOrder(visible, remoteSessions);
    final terminalsById = {
      for (final session in visible) 't:${session.id}': session,
    };
    final remotesById = {
      for (final session in remoteSessions) 'r:${session.id}': session,
    };
    final stripEntries = <Object>[
      for (final key in _tabOrder)
        if (terminalsById[key] != null)
          terminalsById[key]!
        else if (remotesById[key] != null)
          remotesById[key]!,
    ];

    final workspaceTab = _WorkspaceTab(
      open: wsOpen,
      onTap: () {
        ref.read(workspaceOpenProvider.notifier).state = true;
        ref.read(appSectionProvider.notifier).state = AppSection.terminals;
      },
    );

    return Container(
      height: _barHeight,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          if (Platform.isMacOS)
            const _DragRegion(child: SizedBox(width: 80))
          else
            const _DragRegion(child: SizedBox(width: 8)),
          Expanded(
            child: Row(
              children: [
                _TitleBarLabelButton(
                  icon: Icons.home_outlined,
                  label: 'Home',
                  selected: section == AppSection.hosts,
                  onTap: () => ref.read(appSectionProvider.notifier).state =
                      AppSection.hosts,
                ),
                _TitleBarLabelButton(
                  icon: Icons.swap_horiz,
                  label: 'SFTP',
                  selected: section == AppSection.sftp,
                  onTap: () => _openSftp(),
                ),
                if (visible.isEmpty && remoteSessions.isEmpty) ...[
                  if (showWorkspaceTab) ...[const _TabDivider(), workspaceTab],
                  const Expanded(child: _DragRegion(child: SizedBox.expand())),
                ] else ...[
                  const _TabDivider(),
                  Expanded(
                    child: DragTarget<String>(
                      onWillAcceptWithDetails: (_) => true,
                      onMove: (details) => _updateDropIndex(details.offset),
                      onAcceptWithDetails: (details) =>
                          _commitStripDrop(details.data),
                      onLeave: (_) {
                        if (_dropIndex != null) {
                          setState(() {
                            _dropIndex = null;
                            _dropGlobalX = 0;
                          });
                        }
                      },
                      builder: (context, candidateData, rejectedData) {
                        final showIndicator =
                            _dropIndex != null && candidateData.isNotEmpty;
                        return Stack(
                          key: _stripKey,
                          children: [
                            ListView.builder(
                              controller: _stripScroll,
                              scrollDirection: Axis.horizontal,
                              itemCount:
                                  stripEntries.length +
                                  (showWorkspaceTab ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index >= stripEntries.length) {
                                  return Row(
                                    key: _workspaceTabKey,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const _TabDivider(),
                                      workspaceTab,
                                    ],
                                  );
                                }
                                final entry = stripEntries[index];
                                if (entry is RemoteSession) {
                                  return _RemoteTab(
                                    key: _remoteTabKey(entry.id),
                                    session: entry,
                                    barHeight: _barHeight,
                                    selected:
                                        section == AppSection.remotes &&
                                        remoteManager.activeId == entry.id,
                                    onTap: () =>
                                        _selectRemote(remoteManager, entry.id),
                                    onClose: () =>
                                        remoteManager.close(entry.id),
                                  );
                                }
                                final session = entry as TerminalSession;
                                final selected =
                                    inTerminals && session.id == activeId;
                                return _DraggableTab(
                                  key: _tabKey(session.id),
                                  session: session,
                                  barHeight: _barHeight,
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
                            if (showIndicator)
                              Positioned(
                                left: _indicatorLeft(context),
                                top: 6,
                                bottom: 6,
                                width: 2,
                                child: IgnorePointer(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: AppColors.accent,
                                      borderRadius: BorderRadius.circular(1),
                                    ),
                                  ),
                                ),
                              ),

                            Positioned.fill(
                              child: Row(
                                children: [
                                  SizedBox(width: _lastTabRight),
                                  const Expanded(
                                    child: _DragRegion(
                                      child: SizedBox.expand(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          _SidebarToggleButton(),

          if (!Platform.isMacOS) ...[
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
        ],
      ),
    );
  }

  void _selectSession(SessionManager manager, String id) {
    manager.activeSessionId = id;
    ref.read(workspaceOpenProvider.notifier).state = false;
    ref.read(appSectionProvider.notifier).state = AppSection.terminals;
  }

  void _selectRemote(RemoteSessionManager manager, String id) {
    manager.setActive(id);
    ref.read(workspaceOpenProvider.notifier).state = false;
    ref.read(appSectionProvider.notifier).state = AppSection.remotes;
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => windowManager.startDragging(),
      child: MouseRegion(cursor: SystemMouseCursors.move, child: child),
    );
  }
}

class WindowResizeHandles extends StatefulWidget {
  const WindowResizeHandles({super.key});

  static const double _strip = 6;
  static const double _corner = 10;

  @override
  State<WindowResizeHandles> createState() => _WindowResizeHandlesState();
}

class _WindowResizeHandlesState extends State<WindowResizeHandles>
    with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refreshMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  Future<void> _refreshMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && maximized != _maximized) {
      setState(() => _maximized = maximized);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_maximized) return const SizedBox.shrink();
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: WindowResizeHandles._strip,
          child: _ResizeHandle(
            edge: ResizeEdge.top,
            cursor: SystemMouseCursors.resizeUpDown,
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          width: WindowResizeHandles._corner,
          height: WindowResizeHandles._corner,
          child: _ResizeHandle(
            edge: ResizeEdge.topLeft,
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          width: WindowResizeHandles._corner,
          height: WindowResizeHandles._corner,
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

class _DraggableTab extends StatelessWidget {
  final TerminalSession session;
  final double barHeight;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onReconnect;
  final VoidCallback onDuplicate;
  final ValueChanged<String> onRename;

  const _DraggableTab({
    super.key,
    required this.session,
    required this.barHeight,
    required this.selected,
    required this.onTap,
    required this.onClose,
    required this.onReconnect,
    required this.onDuplicate,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    return Draggable<String>(
      data: session.id,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          height: barHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(
              bottom: BorderSide(
                color: sessionStatusColor(session.status),
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                session.os != null ? osIcon(session.os) : Icons.close,
                size: 13,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  session.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: SessionTab(
          session: session,
          selected: selected,
          onTap: onTap,
          onClose: onClose,
          onReconnect: onReconnect,
          onDuplicate: onDuplicate,
          onRename: onRename,
        ),
      ),
      child: SessionTab(
        session: session,
        selected: selected,
        onTap: onTap,
        onClose: onClose,
        onReconnect: onReconnect,
        onDuplicate: onDuplicate,
        onRename: onRename,
      ),
    );
  }
}

class SessionTab extends ConsumerStatefulWidget {
  final TerminalSession session;
  final bool selected;

  final bool bordered;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onReconnect;
  final VoidCallback onDuplicate;
  final ValueChanged<String> onRename;

  const SessionTab({
    super.key,
    required this.session,
    required this.selected,
    this.bordered = false,
    required this.onTap,
    required this.onClose,
    required this.onReconnect,
    required this.onDuplicate,
    required this.onRename,
  });

  @override
  ConsumerState<SessionTab> createState() => SessionTabState();
}

class SessionTabState extends ConsumerState<SessionTab> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _editing = false;
  DateTime? _lastLabelTap;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleLabelTap() {
    final now = DateTime.now();
    final previous = _lastLabelTap;
    if (previous != null &&
        now.difference(previous) < const Duration(milliseconds: 320)) {
      _lastLabelTap = null;
      _startRename();
      return;
    }
    _lastLabelTap = now;
    widget.onTap();
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
    return InkWell(
      onTap: _editing ? null : widget.onTap,
      onSecondaryTapDown: _editing
          ? null
          : (details) => _showContextMenu(context, details.globalPosition),
      child: Container(
        height: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: widget.selected ? AppColors.surfaceAlt : Colors.transparent,
          border: widget.bordered
              ? Border(
                  top: BorderSide(color: AppColors.border),
                  left: BorderSide(color: AppColors.border),
                  right: BorderSide(color: AppColors.border),
                  bottom: BorderSide(
                    color: sessionStatusColor(widget.session.status),
                    width: 2,
                  ),
                )
              : Border(
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
              _TabCloseButton(onTap: widget.onClose, os: widget.session.os),
              const SizedBox(width: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _editing ? null : _handleLabelTap,
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
                    if (_editing) Positioned.fill(child: _buildEditor()),
                  ],
                ),
              ),

              if (widget.session.hasUnseenOutput && !widget.selected) ...[
                const SizedBox(width: 7),
                const NewOutputDot(),
              ],
            ],
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
    final wsIds = ref.read(workspaceSessionIdsProvider);
    final inWorkspace = wsIds.contains(widget.session.id);
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: [
        if (widget.session.status == SessionStatus.error ||
            widget.session.status == SessionStatus.disconnected)
          PopupMenuItem(
            value: 'reconnect',
            child: Row(
              children: [
                Icon(Icons.refresh, size: 15, color: AppColors.accent),
                const SizedBox(width: 12),
                const Text('Reconnect'),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'duplicate',
          child: Row(
            children: [
              Icon(
                Icons.content_copy_outlined,
                size: 15,
                color: AppColors.accent,
              ),
              const SizedBox(width: 12),
              const Text('Duplicate'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'rename',
          child: Row(
            children: [
              Icon(
                Icons.drive_file_rename_outline,
                size: 15,
                color: AppColors.accent,
              ),
              const SizedBox(width: 12),
              const Text('Rename'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'workspace',
          child: Row(
            children: [
              Icon(
                inWorkspace
                    ? Icons.dashboard_customize
                    : Icons.dashboard_outlined,
                size: 15,
                color: AppColors.accent,
              ),
              const SizedBox(width: 12),
              Text(inWorkspace ? 'Remove from workspace' : 'Tile in workspace'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'close',
          child: Row(
            children: [
              const Icon(Icons.close, size: 15, color: AppColors.danger),
              const SizedBox(width: 12),
              const Text('Close'),
            ],
          ),
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
      case 'workspace':
        final current = ref.read(workspaceSessionIdsProvider);
        if (inWorkspace) {
          ref.read(workspaceSessionIdsProvider.notifier).state = current
              .where((id) => id != widget.session.id)
              .toList();
          if (current.length <= 1) {
            ref.read(workspaceOpenProvider.notifier).state = false;
          }
        } else {
          ref.read(workspaceSessionIdsProvider.notifier).state = [
            ...current,
            widget.session.id,
          ];
          ref.read(workspaceOpenProvider.notifier).state = true;
        }
        break;
      case 'close':
        widget.onClose();
        break;
    }
  }
}

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
    final inTerminals = ref.watch(appSectionProvider) == AppSection.terminals;
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

class _RemoteTab extends StatelessWidget {
  const _RemoteTab({
    super.key,
    required this.session,
    required this.barHeight,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final RemoteSession session;
  final double barHeight;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  Color get _statusColor => switch (session.status) {
    RemoteStatus.connected => AppColors.accent,
    RemoteStatus.connecting => AppColors.warning,
    RemoteStatus.error => AppColors.danger,
    RemoteStatus.disconnected => AppColors.textFaint,
  };

  IconData get _icon => switch (session.protocol) {
    HostProtocol.vnc => Icons.screen_share_outlined,
    _ => Icons.desktop_windows_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Draggable<String>(
        data: session.id,
        feedback: Material(
          color: Colors.transparent,
          child: _visual(context, interactive: false),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: _visual(context, interactive: false),
        ),
        child: _visual(context, interactive: true),
      ),
    );
  }

  Widget _visual(BuildContext context, {required bool interactive}) {
    final error = session.error;
    final tooltip = error != null && error.isNotEmpty
        ? '${session.title}\n$error'
        : session.title;
    final content = Container(
      height: barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: selected ? AppColors.surfaceAlt : Colors.transparent,
        border: Border(bottom: BorderSide(color: _statusColor, width: 2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TabCloseButton(onTap: onClose, icon: _icon),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              session.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.0,
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
    if (!interactive) return content;
    return Tooltip(
      message: tooltip,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}

class _WorkspaceTab extends ConsumerWidget {
  final bool open;
  final VoidCallback onTap;

  const _WorkspaceTab({required this.open, required this.onTap});

  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) async {
    final columns = ref.read(workspaceColumnsProvider);
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: [
        for (final n in const [1, 2, 3, 4])
          PopupMenuItem(
            value: 'cols:$n',
            child: Row(
              children: [
                Icon(
                  n == columns
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 15,
                  color: n == columns
                      ? AppColors.accent
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  '$n column${n == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'exit',
          child: Row(
            children: [
              Icon(Icons.close_fullscreen, size: 15, color: AppColors.accent),
              const SizedBox(width: 12),
              const Text('Exit workspace', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    );
    if (action == null || !context.mounted) return;
    if (action.startsWith('cols:')) {
      final n = int.parse(action.substring(5));
      ref.read(workspaceColumnsProvider.notifier).state = n;
    } else if (action == 'exit') {
      ref.read(workspaceSessionIdsProvider.notifier).state = const [];
      ref.read(workspaceOpenProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      workspaceSessionIdsProvider.select((ids) => ids.length),
    );
    return InkWell(
      onTap: onTap,
      onSecondaryTapDown: (details) =>
          _showMenu(context, ref, details.globalPosition),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: open ? AppColors.surfaceAlt : Colors.transparent,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.grid_view_outlined,
                size: 14,
                color: open ? AppColors.textPrimary : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                'Workspace${count > 0 ? ' · $count' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: open ? AppColors.textPrimary : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
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
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
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

  final String? os;

  /// Icon shown while the button is not hovered. Takes precedence over [os].
  final IconData? icon;

  const _TabCloseButton({required this.onTap, this.os, this.icon});

  @override
  State<_TabCloseButton> createState() => _TabCloseButtonState();
}

class _TabCloseButtonState extends State<_TabCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final restIcon =
        widget.icon ?? (widget.os != null ? osIcon(widget.os) : Icons.close);
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
              _hovered ? Icons.close : restIcon,
              size: 13,
              color: _hovered ? AppColors.danger : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
