import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/screens/home_screen.dart';
import 'ui/state/nav.dart';
import 'ui/state/providers.dart';
import 'ui/theme/app_theme.dart';
import 'core/debug_log.dart';
import 'core/shortcuts.dart';

class ConnexiaApp extends ConsumerStatefulWidget {
  const ConnexiaApp({super.key});

  @override
  ConsumerState<ConnexiaApp> createState() => _ConnexiaAppState();
}

class _ConnexiaAppState extends ConsumerState<ConnexiaApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Kick off any tunnels the user marked as auto-start. Best-effort;
    // failures surface through each tunnel's status in the Tunnels tab.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tunnelManagerProvider).startAllAuto();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // The window is closing: end the log entries of any still-open
      // sessions so they don't stay marked as active.
      ref.read(sessionManagerProvider).closeAllSessionLogs();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    writeDebugLog('App build: logical=${size.width}x${size.height} '
        'dpr=$dpr physical=${size.width * dpr}x${size.height * dpr}');
    return MaterialApp(
      title: 'Connexia',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const _GlobalKeyHandler(child: HomeScreen()),
    );
  }
}

/// App-wide keyboard shortcuts:
/// - Ctrl+Shift+N opens a new Connexia window (a new OS process).
/// - 'e' (no modifiers, not while typing) opens the editor of the
///   host/group/key/snippet card currently under the cursor.
class _GlobalKeyHandler extends ConsumerStatefulWidget {
  final Widget child;

  const _GlobalKeyHandler({required this.child});

  @override
  ConsumerState<_GlobalKeyHandler> createState() => _GlobalKeyHandlerState();
}

class _GlobalKeyHandlerState extends ConsumerState<_GlobalKeyHandler> {
  final _node = FocusNode();

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final hk = HardwareKeyboard.instance;

    final custom =
        ref.read(settingsControllerProvider).settings.customShortcuts;

    // When a custom binding exists for an action it replaces the built-in
    // default entirely; otherwise the hardcoded default check applies.
    bool binding(String id, bool Function() defaultCheck) {
      final chord = resolveShortcut(custom, id);
      if (chord != null) return chord.matches(hk, event.logicalKey);
      return defaultCheck();
    }

    if (binding(
      'newWindow',
      () =>
          hk.isControlPressed &&
          hk.isShiftPressed &&
          event.logicalKey == LogicalKeyboardKey.keyN,
    )) {
      _spawnNewWindow();
      return KeyEventResult.handled;
    }

    if (binding(
      'editCard',
      () =>
          !hk.isControlPressed &&
          !hk.isAltPressed &&
          !hk.isMetaPressed &&
          !hk.isShiftPressed &&
          event.logicalKey == LogicalKeyboardKey.keyE,
    )) {
      if (_isEditingText()) return KeyEventResult.ignored;
      final target = ref.read(hoveredEditTargetProvider);
      if (target == null) return KeyEventResult.ignored;
      _dispatchEdit(target);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _isEditingText() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus.context == null) return false;
    return focus.context!.widget is EditableText ||
        focus.context!.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _spawnNewWindow() {
    try {
      Process.start(
        Platform.resolvedExecutable,
        const [],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      writeDebugLog('new window spawn failed: $e');
    }
  }

  void _dispatchEdit(HoveredEditTarget target) {
    switch (target.kind) {
      case HoveredEditKind.host:
        ref.read(hostEditorRequestProvider.notifier).state =
            HostEditorRequest(hostId: target.id);
        break;
      case HoveredEditKind.group:
        ref.read(groupEditorRequestProvider.notifier).state =
            GroupEditorRequest(groupId: target.id);
        break;
      case HoveredEditKind.key:
        ref.read(keyEditorRequestProvider.notifier).state = target.id;
        break;
      case HoveredEditKind.snippet:
        ref.read(snippetEditorRequestProvider.notifier).state =
            SnippetEditorRequest(snippetId: target.id);
        break;
      case HoveredEditKind.tunnel:
        // Make sure the tunnels section is visible, then ask it to open
        // the hovered tunnel's editor (the screen consumes and clears
        // the request).
        ref.read(appSectionProvider.notifier).state = AppSection.tunnels;
        ref.read(tunnelEditRequestProvider.notifier).state = target.id;
        break;
    }
  }
}
