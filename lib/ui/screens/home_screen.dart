import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/remote/remote_session.dart';
import '../../core/sync/sync_controller.dart';
import '../state/nav.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../widgets/multi_select_bar.dart';
import '../widgets/new_output_dot.dart';
import '../widgets/sidebar.dart';
import '../widgets/window_title_bar.dart';
import 'active_connections_screen.dart';
import 'hosts_screen.dart';
import 'keys_screen.dart';
import 'known_hosts_screen.dart';
import 'metrics_screen.dart';
import 'logs_screen.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';
import 'sftp_screen.dart';
import 'snippets_screen.dart';
import 'teams_screen.dart';
import 'terminal_screen.dart';
import 'tunnels_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              if (isDesktop)
                const WindowTitleBar()
              else
                const _MobileTitleBar(),
              Expanded(
                child: Navigator(
                  key: appNavigatorKey,
                  onGenerateRoute: (settings) => MaterialPageRoute(
                    settings: settings,
                    builder: (_) => const _AppShell(),
                  ),
                ),
              ),
            ],
          ),
          if (isDesktop)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 1,
              child: WindowResizeHandles(),
            ),
        ],
      ),
    );
  }
}

/// Mobile top bar: session tabs covering both terminals and remote desktops
/// on the first row (mirroring the desktop title bar), and the section chip
/// row underneath for navigation.
class _MobileTitleBar extends ConsumerStatefulWidget {
  const _MobileTitleBar();

  @override
  ConsumerState<_MobileTitleBar> createState() => _MobileTitleBarState();
}

class _MobileTitleBarState extends ConsumerState<_MobileTitleBar> {
  /// Stable tab order across terminal and remote sessions, keyed the same way
  /// as the desktop title bar (`t:<id>` for terminals, `r:<id>` for remotes).
  final List<String> _tabOrder = [];

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(sessionManagerProvider);
    final sessions = manager.sessions;
    final activeId = manager.activeSessionId;
    final remoteManager = ref.watch(remoteManagerProvider);
    final remoteSessions = remoteManager.sessions;
    final section = ref.watch(appSectionProvider);
    final inTerminals = section == AppSection.terminals;
    final inRemotes = section == AppSection.remotes;
    final liveView = ref.watch(liveSessionViewProvider);

    final keys = <String>[
      for (final session in sessions) 't:${session.id}',
      for (final session in remoteSessions) 'r:${session.id}',
    ];
    _tabOrder.removeWhere((key) => !keys.contains(key));
    _tabOrder.addAll(keys.where((key) => !_tabOrder.contains(key)));

    final terminalsById = {
      for (final session in sessions) 't:${session.id}': session,
    };
    final remotesById = {
      for (final session in remoteSessions) 'r:${session.id}': session,
    };

    return Container(
      color: AppColors.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 38,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: _tabOrder.isEmpty
                        ? const SizedBox.shrink()
                        : ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: _tabOrder.length,
                            itemBuilder: (context, index) {
                              final key = _tabOrder[index];
                              final terminal = terminalsById[key];
                              if (terminal != null) {
                                return Center(
                                  child: _MobileSessionChip(
                                    label: terminal.label,
                                    selected:
                                        inTerminals &&
                                        liveView &&
                                        terminal.id == activeId,
                                    hasNewOutput: terminal.hasUnseenOutput,
                                    onTap: () {
                                      manager.activeSessionId = terminal.id;
                                      ref
                                              .read(appSectionProvider.notifier)
                                              .state =
                                          AppSection.terminals;
                                      ref
                                              .read(
                                                liveSessionViewProvider
                                                    .notifier,
                                              )
                                              .state =
                                          true;
                                    },
                                    onClose: () =>
                                        manager.closeSession(terminal),
                                    onRename: (label) =>
                                        manager.renameSession(terminal, label),
                                    onDuplicate: () =>
                                        manager.duplicateSession(terminal),
                                    onReconnect: () =>
                                        manager.reconnect(terminal),
                                  ),
                                );
                              }
                              final remote = remotesById[key]!;
                              return Center(
                                child: _MobileRemoteChip(
                                  session: remote,
                                  selected:
                                      inRemotes &&
                                      liveView &&
                                      remote.id == remoteManager.activeId,
                                  onTap: () {
                                    remoteManager.setActive(remote.id);
                                    ref
                                            .read(appSectionProvider.notifier)
                                            .state =
                                        AppSection.remotes;
                                    ref
                                            .read(
                                              liveSessionViewProvider.notifier,
                                            )
                                            .state =
                                        true;
                                  },
                                  onClose: () => remoteManager.close(remote.id),
                                  onReconnect: () =>
                                      remoteManager.reconnect(remote.id),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            Container(
              height: 42,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                children: [
                  for (final s in AppSection.values)
                    if ((s != AppSection.terminals || sessions.isNotEmpty) &&
                        (s != AppSection.remotes ||
                            remoteSessions.isNotEmpty)) ...[
                      if (s != AppSection.values.first)
                        const SizedBox(width: 6),
                      _MobileSectionChip(
                        label: s.label,
                        selected:
                            section == s &&
                            !(liveView &&
                                (s == AppSection.terminals ||
                                    s == AppSection.remotes)),
                        onTap: () => _selectSection(s),
                      ),
                    ],
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.border),
          ],
        ),
      ),
    );
  }

  /// Terminals and Remote desktops render a Hosts-style list of live
  /// connections in-shell, so tapping their chip shows that list rather than
  /// the last session; every other section switches directly.
  void _selectSection(AppSection s) {
    ref.read(liveSessionViewProvider.notifier).state = false;
    ref.read(appSectionProvider.notifier).state = s;
  }
}

class _MobileSectionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MobileSectionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentMuted : AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accentBorder : AppColors.border,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _MobileRemoteChip extends StatelessWidget {
  const _MobileRemoteChip({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onClose,
    required this.onReconnect,
  });

  final RemoteSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onReconnect;

  void _showMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                session.title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            ListTile(
              leading: Icon(
                Icons.refresh,
                size: 20,
                color: AppColors.textSecondary,
              ),
              title: const Text('Reconnect'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onReconnect();
              },
            ),
            ListTile(
              leading: Icon(Icons.close, size: 20, color: AppColors.danger),
              title: const Text('Close'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onClose();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _showMenu(context),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 28,
            padding: const EdgeInsets.only(left: 6, right: 8),
            decoration: BoxDecoration(
              color: selected ? AppColors.accentMuted : AppColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? AppColors.accentBorder : AppColors.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(4),
                  child: Icon(
                    Icons.close,
                    size: 13,
                    color: AppColors.textFaint,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileSessionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool hasNewOutput;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueChanged<String> onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onReconnect;

  const _MobileSessionChip({
    required this.label,
    required this.selected,
    required this.hasNewOutput,
    required this.onTap,
    required this.onClose,
    required this.onRename,
    required this.onDuplicate,
    required this.onReconnect,
  });

  void _showMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            ListTile(
              leading: Icon(
                Icons.drive_file_rename_outline,
                size: 20,
                color: AppColors.textSecondary,
              ),
              title: const Text('Rename'),
              onTap: () {
                Navigator.of(context).pop();
                _promptRename(context);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.copy_outlined,
                size: 20,
                color: AppColors.textSecondary,
              ),
              title: const Text('Duplicate'),
              onTap: () {
                Navigator.of(context).pop();
                onDuplicate();
              },
            ),
            ListTile(
              leading: Icon(
                Icons.refresh,
                size: 20,
                color: AppColors.textSecondary,
              ),
              title: const Text('Reconnect'),
              onTap: () {
                Navigator.of(context).pop();
                onReconnect();
              },
            ),
            ListTile(
              leading: Icon(Icons.close, size: 20, color: AppColors.danger),
              title: const Text('Close'),
              onTap: () {
                Navigator.of(context).pop();
                onClose();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptRename(BuildContext context) async {
    final controller = TextEditingController(text: label);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Label'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (result != null) onRename(result);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showMenu(context),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 28,
          padding: const EdgeInsets.only(left: 6, right: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentMuted : AppColors.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppColors.accentBorder : AppColors.border,
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(4),
                child: Icon(Icons.close, size: 13, color: AppColors.textFaint),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ),

              if (hasNewOutput && !selected) ...[
                const SizedBox(width: 6),
                const NewOutputDot(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AppShell extends ConsumerWidget {
  const _AppShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionCount = ref.watch(
      sessionManagerProvider.select((m) => m.sessions.length),
    );
    final hasSessions = sessionCount > 0;
    final hasRemotes = ref.watch(
      remoteManagerProvider.select((m) => m.sessions.isNotEmpty),
    );

    ref.watch(syncControllerProvider);

    final section = ref.watch(appSectionProvider);
    final sidebarOpen = ref.watch(sidebarOpenProvider);
    final isWide = MediaQuery.sizeOf(context).width >= 760;
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final liveView = ref.watch(liveSessionViewProvider);
    final effective =
        (!hasSessions && section == AppSection.terminals) ||
            (!hasRemotes && section == AppSection.remotes)
        ? AppSection.hosts
        : section;
    final selection = ref.watch(selectionBarProvider);

    ref.listen(appSectionProvider, (_, _) {
      ref.read(selectionBarProvider.notifier).state = null;

      ref.read(hoveredEditTargetProvider.notifier).state = null;
    });

    void go(AppSection s) {
      ref.read(appSectionProvider.notifier).state = s;
    }

    return Row(
      children: [
        if (sidebarOpen &&
            isWide &&
            effective != AppSection.terminals &&
            effective != AppSection.remotes &&
            effective != AppSection.sftp)
          Sidebar(current: effective, onSelect: go),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: IndexedStack(
                  index: effective.index,
                  children: [
                    const HostsScreen(),
                    const MetricsScreen(),
                    const KeysScreen(),
                    const TunnelsScreen(),
                    const SnippetsScreen(),
                    const KnownHostsScreen(),
                    const LogsScreen(),
                    const TeamsScreen(),
                    const SettingsScreen(),
                    hasSessions
                        ? (isDesktop || liveView
                              ? TerminalScreen()
                              : const ActiveConnectionsScreen(
                                  kind: ActiveConnectionKind.terminals,
                                ))
                        : const SizedBox.shrink(),
                    isDesktop || (hasRemotes && liveView)
                        ? const RemoteScreen()
                        : const ActiveConnectionsScreen(
                            kind: ActiveConnectionKind.remotes,
                          ),
                    const SftpScreen(),
                  ],
                ),
              ),
              if (selection != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Center(
                    child: MultiSelectBar(
                      count: selection.count,
                      actions: selection.actions,
                      onClose: selection.onClose,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
