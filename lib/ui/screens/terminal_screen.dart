import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/db/database.dart';
import '../../core/debug_log.dart';
import '../../core/shortcuts.dart';
import '../../core/ssh/session_manager.dart';
import '../../core/terminal/scrollback_search.dart';
import '../../core/terminal/themes.dart';
import '../state/nav.dart';
import '../../core/sync/team_providers.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';
import '../widgets/window_title_bar.dart';
import 'snippets_screen.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  bool _showSearch = false;
  final _searchController = TextEditingController();
  final Map<String, ScrollbackSearch> _searches = {};
  final Map<String, FocusNode> _paneFocusNodes = {};
  final GlobalKey _terminalAreaKey = GlobalKey();
  String? _editSnippetId;
  bool _creatingSnippet = false;
  String? _loggedTheme;

  final Map<String, double> _sessionFontSize = {};

  FocusNode _focusNodeFor(TerminalSession session) =>
      _paneFocusNodes.putIfAbsent(session.id, FocusNode.new);

  double _fontSizeFor(TerminalSession session, double global) =>
      _sessionFontSize[session.id] ?? global;

  void _pruneFocusNodes(List<TerminalSession> sessions) {
    final live = sessions.map((s) => s.id).toSet();
    final stale = _paneFocusNodes.keys
        .where((id) => !live.contains(id))
        .toList();
    for (final id in stale) {
      _paneFocusNodes.remove(id)!.dispose();
    }
    _sessionFontSize.removeWhere((id, _) => !live.contains(id));
  }

  @override
  void dispose() {
    _searchController.dispose();
    for (final node in _paneFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  TerminalSession? _activeSession(List<TerminalSession> sessions) {
    if (sessions.isEmpty) return null;
    final activeId = ref.read(sessionManagerProvider).activeSessionId;
    if (activeId != null) {
      for (final session in sessions) {
        if (session.id == activeId) return session;
      }
    }
    return sessions.first;
  }

  ScrollbackSearch _searchFor(TerminalSession session) {
    final existing = _searches[session.id];
    if (existing != null) return existing;
    final search = ScrollbackSearch(
      terminal: session.terminal,
      controller: session.controller,
    );
    _searches[session.id] = search;
    return search;
  }

  Widget _buildPane(
    TerminalSession session,
    TerminalTheme theme,
    double globalFontSize,
    SessionManager manager,
    String activeId, {
    VoidCallback? onActivate,
    Map<ShortcutActivator, Intent>? shortcuts,
    bool visible = true,
  }) {
    return _TerminalPane(
      key: ValueKey(session.id),
      session: session,
      visible: visible,
      theme: theme,
      fontSize: _fontSizeFor(session, globalFontSize),
      focusNode: _focusNodeFor(session),
      isActive: session.id == activeId,
      search: _searchFor(session),
      showSearch: _showSearch && session.id == activeId,
      onToggleSearch: () => setState(() => _showSearch = !_showSearch),
      onKeyEvent: (node, event) => _handleKeyEvent(session, node, event),
      onZoom: (delta) => _zoomBy(delta, session),
      onZoomReset: () => _zoomReset(session),
      onResolveHostKey: (accept) =>
          manager.resolveHostKey(session, accept: accept),
      onReconnect: () => manager.reconnect(session),
      onStopAutoRetry: () => manager.stopAutoRetry(session),
      onCloseSession: () => _closeWorkspaceSession(manager, session),
      onActivate: onActivate,
      shortcuts: shortcuts,
    );
  }

  Map<ShortcutActivator, Intent> _xtermShortcuts() {
    final custom = ref
        .read(settingsControllerProvider)
        .settings
        .customShortcuts;
    final copyChord = resolveShortcut(custom, 'copy');
    final pasteChord = resolveShortcut(custom, 'paste');
    return {
      if (copyChord != null)
        copyChord.toActivator(): CopySelectionTextIntent.copy,
      if (pasteChord != null)
        pasteChord.toActivator(): const PasteTextIntent(
          SelectionChangedCause.keyboard,
        ),
    };
  }

  Widget _terminalContent(
    List<TerminalSession> sessions,
    TerminalSession active,
    TerminalTheme theme,
    double fontSize,
    SessionManager manager,
  ) {
    final wsIds = ref.watch(workspaceSessionIdsProvider);
    final wsOpen = ref.watch(workspaceOpenProvider);
    final byId = {for (final s in sessions) s.id: s};
    final wsSessions = [
      for (final id in wsIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (!wsOpen || wsSessions.isEmpty) {
      final xtermShortcuts = _xtermShortcuts();
      return IndexedStack(
        index: sessions.indexWhere((s) => s.id == active.id),
        children: [
          for (final session in sessions)
            _buildPane(
              session,
              theme,
              fontSize,
              manager,
              active.id,
              shortcuts: xtermShortcuts,
              visible: session.id == active.id,
            ),
        ],
      );
    }

    final columns = ref.watch(workspaceColumnsProvider);
    final cols = columns.clamp(1, wsSessions.length).toInt();
    final rows = (wsSessions.length + cols - 1) ~/ cols;
    final xtermShortcuts = _xtermShortcuts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            children: [
              for (var r = 0; r < rows; r++)
                Expanded(
                  child: Row(
                    children: [
                      for (var c = 0; c < cols; c++)
                        Expanded(
                          child: Container(
                            margin: EdgeInsets.only(
                              right: c < cols - 1 ? 1.0 : 0,
                              bottom: r < rows - 1 ? 1.0 : 0,
                            ),
                            decoration: BoxDecoration(
                              border: Border(
                                right: c < cols - 1
                                    ? BorderSide(
                                        color: AppColors.border,
                                        width: 1,
                                      )
                                    : BorderSide.none,
                                bottom: r < rows - 1
                                    ? BorderSide(
                                        color: AppColors.border,
                                        width: 1,
                                      )
                                    : BorderSide.none,
                              ),
                            ),
                            child: _workspaceCell(
                              wsSessions,
                              r * cols + c,
                              theme,
                              fontSize,
                              manager,
                              active.id,
                              shortcuts: xtermShortcuts,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _workspaceCell(
    List<TerminalSession> wsSessions,
    int index,
    TerminalTheme theme,
    double fontSize,
    SessionManager manager,
    String activeId, {
    Map<ShortcutActivator, Intent>? shortcuts,
  }) {
    if (index >= wsSessions.length) return const SizedBox.shrink();
    final session = wsSessions[index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: SessionTab(
            session: session,
            selected: session.id == activeId,
            onTap: () => manager.activeSessionId = session.id,
            onClose: () => _closeWorkspaceSession(manager, session),
            onReconnect: () => manager.reconnect(session),
            onDuplicate: () => manager.duplicateSession(session),
            onRename: (label) => manager.renameSession(session, label),
          ),
        ),
        Expanded(
          child: _buildPane(
            session,
            theme,
            fontSize,
            manager,
            activeId,
            onActivate: () => manager.activeSessionId = session.id,
            shortcuts: shortcuts,
          ),
        ),
      ],
    );
  }

  void _closeWorkspaceSession(SessionManager manager, TerminalSession session) {
    final current = ref.read(workspaceSessionIdsProvider);
    ref.read(workspaceSessionIdsProvider.notifier).state = current
        .where((id) => id != session.id)
        .toList();
    if (current.length <= 1) {
      ref.read(workspaceOpenProvider.notifier).state = false;
    }
    manager.closeSession(session);
  }

  KeyEventResult _handleKeyEvent(
    TerminalSession session,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed;
    final alt = hk.isAltPressed;
    final shift = hk.isShiftPressed;
    final key = event.logicalKey;

    final altGr =
        alt &&
        !hk.logicalKeysPressed.contains(LogicalKeyboardKey.altLeft) &&
        event.character != null &&
        event.character!.isNotEmpty;
    if (altGr) {
      session.terminal.textInput(event.character!);
      return KeyEventResult.handled;
    }

    final custom = ref
        .read(settingsControllerProvider)
        .settings
        .customShortcuts;

    bool binding(String id, bool Function() defaultCheck) {
      final chord = resolveShortcut(custom, id);
      if (chord != null) return chord.matches(hk, key);
      return defaultCheck();
    }

    if (binding(
      'search',
      () => ctrl && shift && key == LogicalKeyboardKey.keyF,
    )) {
      setState(() => _showSearch = !_showSearch);
      return KeyEventResult.handled;
    }
    if (binding(
      'paste',
      () => ctrl && shift && key == LogicalKeyboardKey.keyV,
    )) {
      Clipboard.getData(Clipboard.kTextPlain).then((data) {
        if (data?.text != null) {
          session.terminal.paste(SessionManager.normalizePaste(data!.text!));
        }
      });
      return KeyEventResult.handled;
    }

    if (binding(
      'zoomIn',
      () =>
          ctrl &&
          !alt &&
          (key == LogicalKeyboardKey.equal ||
              key == LogicalKeyboardKey.numpadAdd),
    )) {
      _zoomBy(1, session);
      return KeyEventResult.handled;
    }
    if (binding(
      'zoomOut',
      () =>
          ctrl &&
          !alt &&
          (key == LogicalKeyboardKey.minus ||
              key == LogicalKeyboardKey.numpadSubtract),
    )) {
      _zoomBy(-1, session);
      return KeyEventResult.handled;
    }
    if (binding(
      'zoomReset',
      () => ctrl && !alt && key == LogicalKeyboardKey.digit0,
    )) {
      _zoomReset(session);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  static const double _minFontSize = 6;
  static const double _maxFontSize = 28;
  static const double _defaultFontSize = 14;

  static const int _minTuiCols = 80;
  static const int _minTuiRows = 24;

  Terminal? _sizeBadgeTerminal;
  DateTime? _sizeBadgeUntil;

  void _zoomBy(int delta, [TerminalSession? session]) {
    final controller = ref.read(settingsControllerProvider);
    if (session == null) {
      final current = controller.settings.fontSize;
      final next = (current + delta).clamp(_minFontSize, _maxFontSize);
      if (next == current) return;
      controller.update(controller.settings.copyWith(fontSize: next));
      return;
    }
    final current =
        _sessionFontSize[session.id] ?? controller.settings.fontSize;
    final next = (current + delta).clamp(_minFontSize, _maxFontSize);
    if (next == current) {
      _showSizeBadge(session.terminal);
      return;
    }
    if (delta > 0) {
      final predicted = (session.terminal.viewWidth * current / next).floor();
      final predictedRows = (session.terminal.viewHeight * current / next)
          .floor();
      final tooNarrow =
          session.terminal.viewWidth >= _minTuiCols && predicted < _minTuiCols;
      final tooShort =
          session.terminal.viewHeight >= _minTuiRows &&
          predictedRows < _minTuiRows;
      if (tooNarrow || tooShort) {
        _showSizeBadge(session.terminal);
        return;
      }
    }
    setState(() => _sessionFontSize[session.id] = next);
    _showSizeBadge(session.terminal);
  }

  void _showSizeBadge(Terminal terminal) {
    _sizeBadgeTerminal = terminal;
    _sizeBadgeUntil = DateTime.now().add(const Duration(milliseconds: 1500));
    setState(() {});
  }

  void _zoomReset([TerminalSession? session]) {
    if (session == null) {
      final controller = ref.read(settingsControllerProvider);
      if (controller.settings.fontSize == _defaultFontSize) return;
      controller.update(
        controller.settings.copyWith(fontSize: _defaultFontSize),
      );
      return;
    }
    if (_sessionFontSize.remove(session.id) != null) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(sessionManagerProvider);
    final sessions = manager.sessions;
    final active = _activeSession(sessions);
    final settings = ref.watch(settingsControllerProvider).settings;
    final theme = terminalThemeByName(settings.terminalTheme).theme;
    if (settings.terminalTheme != _loggedTheme) {
      _loggedTheme = settings.terminalTheme;
      writeDebugLog(
        'TerminalScreen build: theme -> '
        '${settings.terminalTheme} (${theme.background})',
      );
    }

    ref.listen<SnippetEditorRequest?>(snippetEditorRequestProvider, (_, next) {
      if (next == null) return;
      ref.read(snippetEditorRequestProvider.notifier).state = null;
      setState(() {
        _creatingSnippet = next.snippetId == null;
        _editSnippetId = next.snippetId;
      });
    });

    if (active == null) {
      return const SizedBox.shrink();
    }

    _pruneFocusNodes(sessions);

    final snippetsAsync = ref.watch(scopedSnippetsProvider);
    Snippet? editingSnippet;
    if (_editSnippetId != null) {
      final snippets = snippetsAsync.value ?? const <Snippet>[];
      for (final snippet in snippets) {
        if (snippet.id == _editSnippetId) {
          editingSnippet = snippet;
          break;
        }
      }
    }

    final snippetPanelOpen = _creatingSnippet || editingSnippet != null;

    final inTerminals = ref.watch(appSectionProvider) == AppSection.terminals;
    if (inTerminals && !snippetPanelOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _paneFocusNodes[active.id]?.requestFocus();
        }
      });
    }

    final snippetsOpen = ref.watch(terminalSnippetsOpenProvider);

    Widget terminalArea = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          key: _terminalAreaKey,
          child: _TileDropZone(
            terminalAreaKey: _terminalAreaKey,
            child: _terminalContent(
              sessions,
              active,
              theme,
              settings.fontSize,
              manager,
            ),
          ),
        ),
        if (snippetsOpen)
          _SnippetsSidebar(
            onToggleSearch: () => setState(() => _showSearch = !_showSearch),
            fontSize: settings.fontSize,
            onZoom: (delta) => _zoomBy(delta),
          ),
      ],
    );

    final sizeBadgeVisible =
        _sizeBadgeUntil != null && _sizeBadgeUntil!.isAfter(DateTime.now());

    if (snippetPanelOpen || sizeBadgeVisible) {
      terminalArea = Stack(
        children: [
          Positioned.fill(child: terminalArea),
          if (sizeBadgeVisible)
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: _TerminalSizeBadge(
                    terminal: _sizeBadgeTerminal!,
                    until: _sizeBadgeUntil!,
                  ),
                ),
              ),
            ),
          if (snippetPanelOpen) ...[
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() {
                  _editSnippetId = null;
                  _creatingSnippet = false;
                }),
                child: const ColoredBox(color: Color(0x66000000)),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: SnippetEditorPanel(
                snippet: editingSnippet,
                creating: _creatingSnippet,
                onClose: () => setState(() {
                  _editSnippetId = null;
                  _creatingSnippet = false;
                }),
              ),
            ),
          ],
        ],
      );
    }

    return Scaffold(backgroundColor: AppColors.background, body: terminalArea);
  }
}

class _TerminalPane extends StatefulWidget {
  final TerminalSession session;
  final TerminalTheme theme;
  final double fontSize;
  final FocusNode focusNode;
  final bool isActive;
  final bool visible;
  final ScrollbackSearch search;
  final bool showSearch;
  final VoidCallback onToggleSearch;
  final FocusOnKeyEventCallback onKeyEvent;
  final ValueChanged<int> onZoom;
  final VoidCallback onZoomReset;
  final ValueChanged<bool> onResolveHostKey;
  final VoidCallback onReconnect;
  final VoidCallback onStopAutoRetry;

  final VoidCallback onCloseSession;

  final VoidCallback? onActivate;

  final Map<ShortcutActivator, Intent>? shortcuts;

  const _TerminalPane({
    super.key,
    required this.session,
    required this.theme,
    required this.fontSize,
    required this.focusNode,
    required this.isActive,
    this.visible = true,
    required this.search,
    required this.showSearch,
    required this.onToggleSearch,
    required this.onKeyEvent,
    required this.onZoom,
    required this.onZoomReset,
    required this.onResolveHostKey,
    required this.onReconnect,
    required this.onStopAutoRetry,
    required this.onCloseSession,
    this.onActivate,
    this.shortcuts,
  });

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  static const double _gap = 12;

  Size? _lastSentPixels;

  Timer? _resizeDebounce;
  int? _pendingCols;
  int? _pendingRows;
  int? _pendingPixelWidth;
  int? _pendingPixelHeight;
  bool _hasAppliedResize = false;

  final ScrollController _terminalScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _requestFocusWhenActive();

    for (final delay in const [60, 250, 800]) {
      Future.delayed(Duration(milliseconds: delay), () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    _terminalScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.theme != widget.theme) {
      writeDebugLog(
        'Pane didUpdateWidget: theme -> ${widget.theme.background} '
        '(was ${oldWidget.theme.background})',
      );
    }
    final becameActive = widget.isActive && !oldWidget.isActive;
    final wasConnected = oldWidget.session.status == SessionStatus.connected;
    final nowConnected = widget.session.status == SessionStatus.connected;
    if (becameActive || (!wasConnected && nowConnected)) {
      _requestFocusWhenActive();
    }
    if (oldWidget.visible && !widget.visible) {
      _resizeDebounce?.cancel();
      _resizeDebounce = null;
    }
  }

  void _requestFocusWhenActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) widget.focusNode.requestFocus();
    });
  }

  void _syncViewportSize(BuildContext context, Size size) {
    final terminal = widget.session.terminal;

    final painter = TerminalPainter(
      theme: widget.theme,
      textStyle: TerminalStyle(
        fontSize: widget.fontSize,
        fontFamily: 'JetBrainsMono',
        height: 1.15,
      ),
      textScaler: MediaQuery.textScalerOf(context),
    );
    final cell = painter.cellSize;

    if (!cell.width.isFinite ||
        !cell.height.isFinite ||
        cell.width <= 0 ||
        cell.height <= 0) {
      return;
    }
    if (!size.isFinite) return;

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final viewportWidth = size.width - _gap * 2;
    final viewportHeight = size.height - _gap * 2 - bottomInset;
    final cols = (viewportWidth / cell.width).floor().clamp(1, 100000);
    final rows = (viewportHeight / cell.height).floor().clamp(1, 100000);

    final pixels = Size(
      (cols * cell.width).round().toDouble(),
      (rows * cell.height).round().toDouble(),
    );
    if (terminal.viewWidth != cols ||
        terminal.viewHeight != rows ||
        _lastSentPixels != pixels) {
      _lastSentPixels = pixels;
      _pendingCols = cols;
      _pendingRows = rows;
      _pendingPixelWidth = pixels.width.round();
      _pendingPixelHeight = pixels.height.round();
      _resizeDebounce?.cancel();
      if (!_hasAppliedResize) {
        _applyPendingResize();
      } else {
        _resizeDebounce = Timer(
          const Duration(milliseconds: 90),
          _applyPendingResize,
        );
      }
    }
  }

  void _applyPendingResize() {
    _resizeDebounce?.cancel();
    _resizeDebounce = null;
    final cols = _pendingCols;
    final rows = _pendingRows;
    final pixelWidth = _pendingPixelWidth;
    final pixelHeight = _pendingPixelHeight;
    if (cols == null ||
        rows == null ||
        pixelWidth == null ||
        pixelHeight == null) {
      return;
    }
    if (!mounted) return;
    _hasAppliedResize = true;
    try {
      widget.session.terminal.resize(cols, rows, pixelWidth, pixelHeight);
    } catch (e, st) {
      writeDebugLog('terminal resize failed: $e\n$st');
    }
  }

  Widget _withPinchZoom(bool enabled, Widget child) {
    if (!enabled) return child;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _PinchZoomGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_PinchZoomGestureRecognizer>(
              () => _PinchZoomGestureRecognizer(
                debugOwner: this,
                supportedDevices: const {PointerDeviceKind.touch},
                onZoomStep: widget.onZoom,
              ),
              (_) {},
            ),
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = Platform.isAndroid || Platform.isIOS;
        final terminalSize = isMobile
            ? Size(
                constraints.maxWidth,
                constraints.maxHeight - _MobileKeyToolbar.kHeight,
              )
            : constraints.biggest;
        if (widget.visible) {
          _syncViewportSize(context, terminalSize);
        }

        Widget terminalArea = Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent &&
                HardwareKeyboard.instance.isControlPressed) {
              final dy = event.scrollDelta.dy;
              if (dy != 0) {
                widget.onZoom(dy < 0 ? 1 : -1);
              }
            }
          },
          child: TerminalView(
            session.terminal,
            controller: session.controller,
            theme: widget.theme,
            padding: const EdgeInsets.all(_gap),

            autoResize: false,
            scrollController: _terminalScrollController,
            textStyle: TerminalStyle(
              fontSize: widget.fontSize,
              fontFamily: 'JetBrainsMono',
              height: 1.15,
            ),

            shortcuts:
                widget.shortcuts ??
                {
                  SingleActivator(
                    LogicalKeyboardKey.keyC,
                    control: true,
                    shift: true,
                  ): CopySelectionTextIntent.copy,
                  SingleActivator(
                    LogicalKeyboardKey.keyV,
                    control: true,
                    shift: true,
                  ): const PasteTextIntent(
                    SelectionChangedCause.keyboard,
                  ),
                },
            backgroundOpacity: 1,
            autofocus: widget.isActive,
            focusNode: widget.focusNode,

            hardwareKeyboardOnly: !Platform.isAndroid && !Platform.isIOS,
            onKeyEvent: widget.onKeyEvent,
            onTapUp: (_, _) {
              widget.focusNode.requestFocus();
              widget.onActivate?.call();
            },
            onSecondaryTapDown: (details, _) {
              _showContextMenu(context, details.globalPosition);
            },
          ),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: MediaQuery.removePadding(
                context: context,

                removeTop: true,
                child: Column(
                  children: [
                    Expanded(
                      child: Scrollbar(
                        controller: _terminalScrollController,
                        thumbVisibility: !isMobile,

                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),

                          child: _withPinchZoom(isMobile, terminalArea),
                        ),
                      ),
                    ),
                    if (isMobile) _MobileKeyToolbar(session: session),
                  ],
                ),
              ),
            ),
            if (session.status == SessionStatus.connecting)
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xCC0D0E12),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 14),
                        Text(
                          session.autoRetry
                              ? 'Reconnecting...'
                              : 'Connecting...',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        OutlinedButton(
                          onPressed: widget.onCloseSession,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 36),
                            textStyle: const TextStyle(fontSize: 12.5),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (session.status == SessionStatus.verifyingHostKey)
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xCC0D0E12),
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 430),
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.shield_outlined,
                                  size: 22,
                                  color: Colors.amber,
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text(
                                    'Unknown host key',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'The authenticity of '
                              '${session.request.address}:${session.request.port} '
                              'cannot be established. This is the first time '
                              'you connect to this host.',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Key type: ${session.acceptedKeyType ?? 'unknown'}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              session.acceptedFingerprint ?? '',
                              style: TextStyle(
                                fontSize: 13,
                                fontFamily: 'JetBrainsMono',
                                color: AppColors.accent,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Continue only if you trust this host. An '
                              'attacker could otherwise intercept your '
                              'connection.',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: AppColors.textFaint,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () =>
                                        widget.onResolveHostKey(false),
                                    style: OutlinedButton.styleFrom(
                                      minimumSize: const Size.fromHeight(40),
                                    ),
                                    child: const Text('Cancel'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 2,
                                  child: FilledButton(
                                    onPressed: () =>
                                        widget.onResolveHostKey(true),
                                    style: FilledButton.styleFrom(
                                      minimumSize: const Size.fromHeight(40),
                                    ),
                                    child: const Text('Connect'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (session.status == SessionStatus.error)
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xCC0D0E12),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            size: 48,
                            color: AppColors.danger,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            session.error ?? 'Connection failed',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: widget.onReconnect,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Reconnect'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 40),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            if (session.status == SessionStatus.disconnected)
              Positioned(
                left: 12,
                bottom: isMobile ? _MobileKeyToolbar.kHeight + 12 : 12,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ReconnectButton(onTap: widget.onReconnect),
                    if (session.autoRetry) ...[
                      const SizedBox(width: 8),
                      _AutoRetryBanner(
                        session: session,
                        onStop: widget.onStopAutoRetry,
                      ),
                    ],
                  ],
                ),
              ),
            if (session.autoRetry && session.status == SessionStatus.error)
              Positioned(
                left: 12,
                bottom: isMobile ? _MobileKeyToolbar.kHeight + 12 : 12,
                child: _AutoRetryBanner(
                  session: session,
                  onStop: widget.onStopAutoRetry,
                ),
              ),
            if (widget.showSearch)
              Positioned(
                top: 12,
                right: 12,
                child: _SearchBar(
                  search: widget.search,
                  onClose: widget.onToggleSearch,
                ),
              ),
          ],
        );
      },
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    showContextMenuAt<void>(
      context: context,
      globalPosition: position,
      items: [
        PopupMenuItem(
          onTap: () {
            final controller = widget.session.controller;

            var text = controller.selectionText;
            if (text == null || text.isEmpty) {
              final terminal = widget.session.terminal;
              final range =
                  controller.effectiveFrozenRange(
                    terminal.buffer.lines.absoluteStartIndex,
                  ) ??
                  controller.selection;
              if (range != null) {
                text = terminal.buffer.getText(range);
              }
            }
            if (text == null || text.isEmpty) return;
            Clipboard.setData(ClipboardData(text: text));
            controller.clearSelection();
          },
          child: Row(
            children: [
              Icon(Icons.copy_outlined, size: 15, color: AppColors.accent),
              const SizedBox(width: 12),
              const Text('Copy'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: () async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            if (data?.text != null) {
              widget.session.terminal.paste(
                SessionManager.normalizePaste(data!.text!),
              );
            }
          },
          child: Row(
            children: [
              Icon(Icons.content_paste, size: 15, color: AppColors.accent),
              const SizedBox(width: 12),
              const Text('Paste'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: widget.onToggleSearch,
          child: Row(
            children: [
              Icon(Icons.search, size: 15, color: AppColors.accent),
              const SizedBox(width: 12),
              const Text('Find...'),
            ],
          ),
        ),
      ],
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            icon,
            size: 13,
            color: onTap != null
                ? AppColors.textSecondary
                : AppColors.textFaint,
          ),
        ),
      ),
    );
  }
}

class _ReconnectButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ReconnectButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: AppColors.elevated,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.borderStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh, size: 14, color: AppColors.accent),
              const SizedBox(width: 6),
              const Text('Reconnect', style: TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AutoRetryBanner extends StatelessWidget {
  final TerminalSession session;
  final VoidCallback onStop;

  const _AutoRetryBanner({required this.session, required this.onStop});

  @override
  Widget build(BuildContext context) {
    final next = session.nextRetryAt;
    var seconds = 0;
    if (next != null) {
      seconds = (next.difference(DateTime.now()).inMilliseconds / 1000).ceil();
    }
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: AppColors.elevated,
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.warning,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Reconnecting in ${seconds < 1 ? 1 : seconds}s…',
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Stop reconnecting',
              child: InkWell(
                onTap: onStop,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.close,
                    size: 15,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  final ScrollbackSearch search;
  final VoidCallback onClose;

  const _SearchBar({required this.search, required this.onClose});

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    widget.search.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: AppColors.elevated,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 200,
              child: TextField(
                controller: _controller,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Find in buffer...',
                  hintStyle: TextStyle(fontSize: 13),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (value) {
                  setState(() => widget.search.search(value));
                },
                onSubmitted: (value) {
                  final s = widget.search;
                  if (s.total > 0) s.moveTo(s.currentIndex + 1);
                },
              ),
            ),
            const SizedBox(width: 12),
            Text(
              widget.search.total == 0
                  ? ''
                  : '${widget.search.currentIndex + 1}/${widget.search.total}',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            IconButton(
              tooltip: 'Previous match',
              icon: const Icon(Icons.keyboard_arrow_up, size: 18),
              onPressed: widget.search.total == 0
                  ? null
                  : () {
                      final s = widget.search;
                      s.moveTo(s.currentIndex - 1);
                      setState(() {});
                    },
            ),
            IconButton(
              tooltip: 'Next match',
              icon: const Icon(Icons.keyboard_arrow_down, size: 18),
              onPressed: widget.search.total == 0
                  ? null
                  : () {
                      final s = widget.search;
                      s.moveTo(s.currentIndex + 1);
                      setState(() {});
                    },
            ),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close, size: 18),
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _SnippetsSidebar extends ConsumerWidget {
  final VoidCallback onToggleSearch;
  final double fontSize;
  final ValueChanged<int> onZoom;

  const _SnippetsSidebar({
    required this.onToggleSearch,
    required this.fontSize,
    required this.onZoom,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snippets = ref.watch(scopedSnippetsProvider);

    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
            child: Row(
              children: [
                Icon(Icons.code, size: 16, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Snippets',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                _SidebarIconButton(
                  icon: Icons.search,
                  tooltip: 'Find in terminal (Ctrl+Shift+F)',
                  onTap: onToggleSearch,
                ),
                const SizedBox(width: 6),
                _SidebarIconButton(
                  icon: Icons.add,
                  tooltip: 'New snippet',
                  onTap: () => showSnippetEditor(ref),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: snippets.when(
              loading: () => const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (e, _) => Center(
                child: Text(
                  'Error: $e',
                  style: const TextStyle(fontSize: 12, color: AppColors.danger),
                ),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return _NoSnippets(onCreate: () => showSnippetEditor(ref));
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final snippet = items[index];
                    return _SnippetRow(
                      snippet: snippet,
                      onRun: () => _runCurrent(context, ref, snippet),
                      onPaste: () => _pasteCurrent(context, ref, snippet),
                      onRunAll: () => _runAll(context, ref, snippet),
                      onEdit: () => showSnippetEditor(ref, snippet: snippet),
                      onCopy: () => _copySnippet(context, ref, snippet),
                      onDelete: () => _deleteSnippet(context, ref, snippet),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 5, 10, 7),
            child: Row(
              children: [
                Text(
                  'Zoom',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textFaint,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ctrl+wheel / Ctrl+= / Ctrl+-',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppColors.textFaint,
                    ),
                  ),
                ),
                _ZoomButton(
                  icon: Icons.remove,
                  tooltip: 'Zoom out (Ctrl+-)',
                  onTap: fontSize > _TerminalScreenState._minFontSize
                      ? () => onZoom(-1)
                      : null,
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(fontSize / 14 * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                _ZoomButton(
                  icon: Icons.add,
                  tooltip: 'Zoom in (Ctrl+=)',
                  onTap: fontSize < _TerminalScreenState._maxFontSize
                      ? () => onZoom(1)
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _runCurrent(BuildContext context, WidgetRef ref, Snippet snippet) {
    final ok = ref
        .read(sessionManagerProvider)
        .runInActiveSession(snippet.command);
    if (!ok) {
      _toast(context, 'No connected terminal to run in');
    }
  }

  void _pasteCurrent(BuildContext context, WidgetRef ref, Snippet snippet) {
    final ok = ref
        .read(sessionManagerProvider)
        .pasteToActiveSession(snippet.command);
    _toast(
      context,
      ok
          ? 'Pasted into the active terminal'
          : 'No connected terminal to paste into',
    );
  }

  void _runAll(BuildContext context, WidgetRef ref, Snippet snippet) {
    final count = ref
        .read(sessionManagerProvider)
        .runInAllConnected(snippet.command);
    if (count == 0) {
      _toast(context, 'No connected terminals');
    }
  }

  Future<void> _copySnippet(
    BuildContext context,
    WidgetRef ref,
    Snippet snippet,
  ) async {
    await Clipboard.setData(ClipboardData(text: snippet.command));
    if (!context.mounted) return;
    _toast(context, 'Command copied to clipboard');
  }

  Future<void> _deleteSnippet(
    BuildContext context,
    WidgetRef ref,
    Snippet snippet,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete snippet?'),
        content: Text('Delete "${snippet.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appDatabaseProvider).deleteSnippet(snippet.id);
    }
  }
}

class _NoSnippets extends StatelessWidget {
  final VoidCallback onCreate;

  const _NoSnippets({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.code, size: 30, color: AppColors.textFaint),
            const SizedBox(height: 12),
            const Text(
              'No snippets yet',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Save reusable commands and send them to any terminal.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add, size: 15),
              label: const Text('New snippet'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnippetRow extends StatefulWidget {
  final Snippet snippet;
  final VoidCallback onRun;
  final VoidCallback onPaste;
  final VoidCallback onRunAll;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  const _SnippetRow({
    required this.snippet,
    required this.onRun,
    required this.onPaste,
    required this.onRunAll,
    required this.onEdit,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  State<_SnippetRow> createState() => _SnippetRowState();
}

class _SnippetRowState extends State<_SnippetRow> {
  bool _hovered = false;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final command = widget.snippet.command;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onRun,
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          color: _hovered ? AppColors.surfaceAlt : Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.snippet.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (!_expanded) ...[
                              const SizedBox(height: 2),
                              Text(
                                command.replaceAll('\n', ' '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'JetBrainsMono',
                                  color: AppColors.textFaint,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),

                  Positioned(
                    top: 0,
                    right: 0,
                    child: AnimatedOpacity(
                      opacity: _hovered ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      child: IgnorePointer(
                        ignoring: !_hovered,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              stops: const [0.0, 0.4, 1.0],
                              colors: [
                                AppColors.surfaceAlt.withValues(alpha: 0),
                                AppColors.surfaceAlt.withValues(alpha: 0.6),
                                AppColors.surfaceAlt,
                              ],
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(width: 4),
                              _SidebarIconButton(
                                icon: Icons.play_arrow,
                                tooltip: 'Run in the active terminal',
                                onTap: widget.onRun,
                              ),
                              _SidebarIconButton(
                                icon: Icons.content_paste,
                                tooltip: 'Paste into the active terminal',
                                onTap: widget.onPaste,
                              ),
                              _SidebarIconButton(
                                icon: _expanded
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                tooltip: _expanded
                                    ? 'Collapse'
                                    : 'View full command',
                                onTap: () =>
                                    setState(() => _expanded = !_expanded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (_expanded)
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      command,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        fontFamily: 'JetBrainsMono',
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: const [
        PopupMenuItem(
          value: 'run',
          child: _SidebarMenuItem(icon: Icons.play_arrow, label: 'Run'),
        ),
        PopupMenuItem(
          value: 'edit',
          child: _SidebarMenuItem(icon: Icons.edit_outlined, label: 'Edit'),
        ),
        PopupMenuItem(
          value: 'runAll',
          child: _SidebarMenuItem(
            icon: Icons.playlist_play,
            label: 'Run in all tabs',
          ),
        ),
        PopupMenuItem(
          value: 'paste',
          child: _SidebarMenuItem(icon: Icons.content_paste, label: 'Paste'),
        ),
        PopupMenuItem(
          value: 'copy',
          child: _SidebarMenuItem(
            icon: Icons.copy_outlined,
            label: 'Copy to clipboard',
          ),
        ),
        PopupMenuItem(
          value: 'viewMore',
          child: _SidebarMenuItem(
            icon: Icons.visibility_outlined,
            label: 'View more',
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: _SidebarMenuItem(
            icon: Icons.delete_outline,
            label: 'Delete',
            danger: true,
          ),
        ),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'run':
        widget.onRun();
      case 'edit':
        widget.onEdit();
      case 'runAll':
        widget.onRunAll();
      case 'paste':
        widget.onPaste();
      case 'copy':
        widget.onCopy();
      case 'viewMore':
        setState(() => _expanded = !_expanded);
      case 'delete':
        widget.onDelete();
    }
  }
}

class _SidebarMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;

  const _SidebarMenuItem({
    required this.icon,
    required this.label,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: danger ? AppColors.danger : AppColors.accent,
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: danger ? AppColors.danger : AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _SidebarIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _SidebarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_SidebarIconButton> createState() => _SidebarIconButtonState();
}

class _SidebarIconButtonState extends State<_SidebarIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: _hovered ? AppColors.cardHover : AppColors.card,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _hovered ? AppColors.borderStrong : AppColors.border,
              ),
            ),
            child: Icon(widget.icon, size: 16, color: AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

class _MobileKeyToolbar extends StatefulWidget {
  const _MobileKeyToolbar({required this.session});

  static const double kHeight = 42;

  final TerminalSession session;

  @override
  State<_MobileKeyToolbar> createState() => _MobileKeyToolbarState();
}

class _MobileKeyToolbarState extends State<_MobileKeyToolbar> {
  Timer? _oneShotTimer;

  static const _navKeys = <(String, TerminalKey)>[
    ('Esc', TerminalKey.escape),
    ('Tab', TerminalKey.tab),
    ('Home', TerminalKey.home),
    ('End', TerminalKey.end),
    ('PgUp', TerminalKey.pageUp),
    ('PgDn', TerminalKey.pageDown),
    ('Ins', TerminalKey.insert),
    ('Del', TerminalKey.delete),
  ];

  TerminalSession get _session => widget.session;

  @override
  void dispose() {
    _oneShotTimer?.cancel();
    super.dispose();
  }

  void _sendKey(TerminalKey key) {
    final session = _session;
    final ctrl = session.ctrlLocked || session.ctrlOneShot;
    final alt = session.altLocked || session.altOneShot;
    session.ctrlOneShot = false;
    session.altOneShot = false;
    _oneShotTimer?.cancel();
    session.terminal.keyInput(key, ctrl: ctrl, alt: alt);
    setState(() {});
  }

  void _armOneShot(bool ctrl) {
    final session = _session;
    setState(() {
      if (ctrl) {
        session.ctrlOneShot = true;
      } else {
        session.altOneShot = true;
      }
    });
    _oneShotTimer?.cancel();
    _oneShotTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() {
        session.ctrlOneShot = false;
        session.altOneShot = false;
      });
    });
  }

  void _toggleLock(bool ctrl) {
    final session = _session;
    setState(() {
      if (ctrl) {
        session.ctrlLocked = !session.ctrlLocked;
      } else {
        session.altLocked = !session.altLocked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Focus(
      canRequestFocus: false,
      child: Container(
        height: _MobileKeyToolbar.kHeight,
        decoration: BoxDecoration(
          color: AppColors.terminalChrome,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              _KeyChip(
                label: 'Ctrl',
                highlighted: session.ctrlLocked || session.ctrlOneShot,
                locked: session.ctrlLocked,
                onTap: () => _armOneShot(true),
                onDoubleTap: () => _toggleLock(true),
              ),
              const SizedBox(width: 4),
              _KeyChip(
                label: 'Alt',
                highlighted: session.altLocked || session.altOneShot,
                locked: session.altLocked,
                onTap: () => _armOneShot(false),
                onDoubleTap: () => _toggleLock(false),
              ),
              const _KeyChipDivider(),
              _KeyChip(
                icon: Icons.keyboard_arrow_up,
                label: 'Up',
                onTap: () => _sendKey(TerminalKey.arrowUp),
              ),
              const SizedBox(width: 4),
              _KeyChip(
                icon: Icons.keyboard_arrow_down,
                label: 'Down',
                onTap: () => _sendKey(TerminalKey.arrowDown),
              ),
              const SizedBox(width: 4),
              _KeyChip(
                icon: Icons.keyboard_arrow_left,
                label: 'Left',
                onTap: () => _sendKey(TerminalKey.arrowLeft),
              ),
              const SizedBox(width: 4),
              _KeyChip(
                icon: Icons.keyboard_arrow_right,
                label: 'Right',
                onTap: () => _sendKey(TerminalKey.arrowRight),
              ),
              const _KeyChipDivider(),
              for (final (label, key) in _navKeys) ...[
                _KeyChip(label: label, onTap: () => _sendKey(key)),
                const SizedBox(width: 4),
              ],
              const _KeyChipDivider(),
              _KeyChip(
                icon: Icons.keyboard_hide_outlined,
                label: 'Hide',
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyChipDivider extends StatelessWidget {
  const _KeyChipDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: AppColors.border,
    );
  }
}

class _KeyChip extends StatelessWidget {
  const _KeyChip({
    required this.label,
    this.icon,
    this.highlighted = false,
    this.locked = false,
    required this.onTap,
    this.onDoubleTap,
  });

  final String label;
  final IconData? icon;
  final bool highlighted;
  final bool locked;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final color = highlighted ? AppColors.accent : AppColors.textPrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: highlighted ? AppColors.accentMuted : AppColors.terminalChrome,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: highlighted ? AppColors.accentBorder : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 3),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            if (locked) ...[
              const SizedBox(width: 4),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkspaceTabStrip extends ConsumerStatefulWidget {
  final List<TerminalSession> sessions;
  final String activeId;
  final ValueChanged<String> onSelect;
  final ValueChanged<TerminalSession> onClose;
  final ValueChanged<TerminalSession> onReconnect;
  final ValueChanged<TerminalSession> onDuplicate;
  final void Function(TerminalSession, String) onRename;

  const _WorkspaceTabStrip({
    required this.sessions,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onReconnect,
    required this.onDuplicate,
    required this.onRename,
  });

  @override
  ConsumerState<_WorkspaceTabStrip> createState() => _WorkspaceTabStripState();
}

class _WorkspaceTabStripState extends ConsumerState<_WorkspaceTabStrip> {
  int? _dropIndex;
  double _dropGlobalX = 0;
  final Map<String, GlobalKey> _tabKeys = {};
  final GlobalKey _stripKey = GlobalKey();

  GlobalKey _tabKey(String sessionId) =>
      _tabKeys.putIfAbsent(sessionId, GlobalKey.new);

  void _updateDropIndex(Offset globalPos) {
    final sessions = widget.sessions;
    var index = sessions.length;
    var dropX = 0.0;
    for (var i = 0; i < sessions.length; i++) {
      final box =
          _tabKey(sessions[i].id).currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null) continue;
      final left = box.localToGlobal(Offset.zero).dx;
      final right = left + box.size.width;
      if (globalPos.dx < right) {
        final before = globalPos.dx < left + box.size.width / 2;
        index = before ? i : i + 1;
        dropX = before ? left : right;
        break;
      }
    }
    if (index == sessions.length && sessions.isNotEmpty) {
      final lastBox =
          _tabKey(sessions.last.id).currentContext?.findRenderObject()
              as RenderBox?;
      if (lastBox != null) {
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

  void _commitReorder(String draggedId) {
    final current = [...ref.read(workspaceSessionIdsProvider)];
    final oldIndex = current.indexOf(draggedId);
    if (oldIndex < 0) return;
    current.removeAt(oldIndex);
    var insertAt = _dropIndex ?? current.length;
    if (insertAt < 0) insertAt = 0;
    if (insertAt > current.length) insertAt = current.length;
    if (insertAt > oldIndex) insertAt--;
    current.insert(insertAt, draggedId);
    ref.read(workspaceSessionIdsProvider.notifier).state = current;
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
    final sessions = widget.sessions;
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) =>
            ref.read(workspaceSessionIdsProvider).contains(details.data),
        onMove: (details) => _updateDropIndex(details.offset),
        onAcceptWithDetails: (details) => _commitReorder(details.data),
        onLeave: (_) {
          if (_dropIndex != null) {
            setState(() {
              _dropIndex = null;
              _dropGlobalX = 0;
            });
          }
        },
        builder: (context, candidateData, rejectedData) {
          final showIndicator = _dropIndex != null && candidateData.isNotEmpty;
          return Stack(
            key: _stripKey,
            children: [
              ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: sessions.length,
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  final selected = session.id == widget.activeId;
                  return LongPressDraggable<String>(
                    data: session.id,
                    delay: const Duration(milliseconds: 150),
                    feedback: Material(
                      color: Colors.transparent,
                      child: Container(
                        height: 40,
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
                              Icons.grid_view_outlined,
                              size: 13,
                              color: AppColors.textSecondary,
                            ),
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 150),
                              child: Text(
                                session.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textPrimary,
                                ),
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
                        bordered: true,
                        onTap: () => widget.onSelect(session.id),
                        onClose: () => widget.onClose(session),
                        onReconnect: () => widget.onReconnect(session),
                        onDuplicate: () => widget.onDuplicate(session),
                        onRename: (label) => widget.onRename(session, label),
                      ),
                    ),
                    child: SessionTab(
                      session: session,
                      selected: selected,
                      bordered: true,
                      onTap: () => widget.onSelect(session.id),
                      onClose: () => widget.onClose(session),
                      onReconnect: () => widget.onReconnect(session),
                      onDuplicate: () => widget.onDuplicate(session),
                      onRename: (label) => widget.onRename(session, label),
                    ),
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
            ],
          );
        },
      ),
    );
  }
}

class _TileDropZone extends ConsumerStatefulWidget {
  final Widget child;
  final GlobalKey terminalAreaKey;

  const _TileDropZone({required this.child, required this.terminalAreaKey});

  @override
  ConsumerState<_TileDropZone> createState() => _TileDropZoneState();
}

class _TileDropZoneState extends ConsumerState<_TileDropZone> {
  bool _hovering = false;
  String? _draggedId;
  Offset _lastGlobalPos = Offset.zero;

  List<String> _prospectiveMembers() {
    final current = [...ref.read(workspaceSessionIdsProvider)];
    final activeId = ref.read(sessionManagerProvider).activeSessionId;
    final result = <String>[];
    for (final id in [activeId, _draggedId]) {
      if (id != null && !result.contains(id)) result.add(id);
    }
    for (final id in current) {
      if (!result.contains(id)) result.add(id);
    }
    return result;
  }

  int _dropCellFromPosition(Offset globalPos) {
    final box =
        widget.terminalAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return -1;
    final local = box.globalToLocal(globalPos);
    final size = box.size;
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > size.width ||
        local.dy > size.height) {
      return -1;
    }
    final members = _prospectiveMembers();
    if (members.isEmpty) return 0;
    final columns = ref
        .read(workspaceColumnsProvider)
        .clamp(1, members.length)
        .toInt();
    final cellW = size.width / columns;
    final cellH = size.height / ((members.length + columns - 1) ~/ columns);
    final col = (local.dx / cellW).floor();
    final row = (local.dy / cellH).floor();
    return row * columns + col;
  }

  Widget _buildPreview(BuildContext context) {
    final draggedId = _draggedId;
    final prospective = _prospectiveMembers();
    if (prospective.isEmpty || draggedId == null) {
      return const SizedBox.shrink();
    }

    final finalMembers = prospective.where((x) => x != draggedId).toList();
    final dropIndex = _dropCellFromPosition(_lastGlobalPos);
    if (dropIndex >= 0) {
      finalMembers.insert(dropIndex.clamp(0, finalMembers.length), draggedId);
    } else {
      finalMembers.insert(0, draggedId);
    }

    final sessions = ref.read(sessionManagerProvider).sessions;
    final byId = {for (final s in sessions) s.id: s};
    final labels = {for (final id in finalMembers) id: byId[id]?.label ?? id};
    final columns = ref.read(workspaceColumnsProvider);
    final cols = columns.clamp(1, finalMembers.length).toInt();
    final rows = (finalMembers.length + cols - 1) ~/ cols;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 24)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_view_outlined, size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              Text(
                'Drop to tile · ${finalMembers.length} session${finalMembers.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 280,
            height: 140,
            child: Column(
              children: [
                for (var r = 0; r < rows; r++)
                  Expanded(
                    child: Row(
                      children: [
                        for (var c = 0; c < cols; c++)
                          Expanded(
                            child: _PreviewCell(
                              label: (r * cols + c) < finalMembers.length
                                  ? labels[finalMembers[r * cols + c]]!
                                  : '',
                              highlighted:
                                  (r * cols + c) < finalMembers.length &&
                                  finalMembers[r * cols + c] == draggedId,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          !ref.read(workspaceSessionIdsProvider).contains(details.data),
      onAcceptWithDetails: (details) {
        final id = details.data;

        final prospective = _prospectiveMembers();
        final result = prospective.where((x) => x != id).toList();
        final dropIndex = _dropCellFromPosition(_lastGlobalPos);
        if (dropIndex >= 0) {
          result.insert(dropIndex.clamp(0, result.length), id);
        } else {
          result.insert(0, id);
        }
        ref.read(workspaceSessionIdsProvider.notifier).state = result;
        ref.read(workspaceOpenProvider.notifier).state = true;
        setState(() {
          _hovering = false;
          _draggedId = null;
          _lastGlobalPos = Offset.zero;
        });
      },
      onMove: (details) {
        setState(() {
          _hovering = true;
          _draggedId = details.data;
          _lastGlobalPos = details.offset;
        });
      },
      onLeave: (_) {
        setState(() {
          _hovering = false;
          _draggedId = null;
          _lastGlobalPos = Offset.zero;
        });
      },
      builder: (context, candidateData, rejectedData) {
        final show = _hovering && candidateData.isNotEmpty;
        return Stack(
          children: [
            widget.child,
            if (show)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: AppColors.accent.withValues(alpha: 0.10),
                    child: Center(child: _buildPreview(context)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PreviewCell extends StatelessWidget {
  final String label;
  final bool highlighted;

  const _PreviewCell({required this.label, required this.highlighted});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: highlighted
            ? AppColors.accent.withValues(alpha: 0.22)
            : label.isEmpty
            ? Colors.transparent
            : AppColors.surfaceAlt,
        border: Border.all(
          color: highlighted
              ? AppColors.accent
              : label.isEmpty
              ? AppColors.border
              : AppColors.borderStrong,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: highlighted ? AppColors.accent : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalSizeBadge extends StatefulWidget {
  const _TerminalSizeBadge({required this.terminal, required this.until});

  final Terminal terminal;

  final DateTime until;

  @override
  State<_TerminalSizeBadge> createState() => _TerminalSizeBadgeState();
}

class _TerminalSizeBadgeState extends State<_TerminalSizeBadge> {
  Timer? _timer;

  bool get _visible => DateTime.now().isBefore(widget.until);

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      if (!_visible) timer.cancel();
      setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(_TerminalSizeBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.until != oldWidget.until) _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.terminalChrome,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        '${widget.terminal.viewWidth} × ${widget.terminal.viewHeight}',
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12.5,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _PinchZoomGestureRecognizer extends OneSequenceGestureRecognizer {
  _PinchZoomGestureRecognizer({
    required this.onZoomStep,
    super.debugOwner,
    super.supportedDevices,
  });

  final ValueChanged<int> onZoomStep;

  static const double _step = 0.12;

  final Map<int, Offset> _pointers = {};
  double? _referenceSpan;
  double _accumulated = 0;

  double get _span {
    final positions = _pointers.values.toList(growable: false);
    return (positions.first - positions.last).distance;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointers[event.pointer] = event.position;

    if (_pointers.length == 2) {
      final span = _span;
      if (span > 0) {
        _referenceSpan = span;
        _accumulated = 0;
        resolve(GestureDisposition.accepted);
      }
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      if (!_pointers.containsKey(event.pointer)) return;
      _pointers[event.pointer] = event.position;
      final reference = _referenceSpan;
      if (reference == null || reference <= 0 || _pointers.length < 2) {
        return;
      }
      final span = _span;
      if (span <= 0) return;
      _accumulated += (span - reference) / reference;
      _referenceSpan = span;
      while (_accumulated >= _step) {
        _accumulated -= _step;
        onZoomStep(1);
      }
      while (_accumulated <= -_step) {
        _accumulated += _step;
        onZoomStep(-1);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _forgetPointer(event.pointer);
      stopTrackingIfPointerNoLongerDown(event);
    }
  }

  void _forgetPointer(int pointer) {
    _pointers.remove(pointer);

    if (_pointers.length < 2) {
      _referenceSpan = null;
      _accumulated = 0;
    }
  }

  @override
  void rejectGesture(int pointer) {
    _forgetPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointers.clear();
    _referenceSpan = null;
    _accumulated = 0;
  }

  @override
  void dispose() {
    _pointers.clear();
    super.dispose();
  }

  @override
  String get debugDescription => '_PinchZoomGestureRecognizer';
}
