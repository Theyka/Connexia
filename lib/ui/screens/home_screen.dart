import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/sync_controller.dart';
import '../state/nav.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../widgets/multi_select_bar.dart';
import '../widgets/sidebar.dart';
import '../widgets/window_title_bar.dart';
import 'hosts_screen.dart';
import 'keys_screen.dart';
import 'known_hosts_screen.dart';
import 'logs_screen.dart';
import 'settings_screen.dart';
import 'sftp_screen.dart';
import 'snippets_screen.dart';
import 'terminal_screen.dart';

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

/// Mobile header: app title and session tabs on the first row, a scrollable
/// row of section chips on the second. Replaces the desktop window chrome.
class _MobileTitleBar extends ConsumerWidget {
  const _MobileTitleBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(sessionManagerProvider);
    final sessions = manager.sessions;
    final activeId = manager.activeSessionId;
    final section = ref.watch(appSectionProvider);
    final inTerminals = section == AppSection.terminals;

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
                    child: sessions.isEmpty
                        ? const SizedBox.shrink()
                        : ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: sessions.length,
                            itemBuilder: (context, index) {
                              final session = sessions[index];
                              return Center(
                                child: _MobileSessionChip(
                                  label: session.label,
                                  selected: inTerminals &&
                                      session.id == activeId,
                                  onTap: () {
                                    manager.activeSessionId = session.id;
                                    ref
                                        .read(appSectionProvider.notifier)
                                        .state = AppSection.terminals;
                                  },
                                  onClose: () =>
                                      manager.closeSession(session),
                                  onRename: (label) =>
                                      manager.renameSession(session, label),
                                  onDuplicate: () =>
                                      manager.duplicateSession(session),
                                  onReconnect: () =>
                                      manager.reconnect(session),
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
                    if (s != AppSection.terminals ||
                        sessions.isNotEmpty) ...[
                      if (s != AppSection.values.first)
                        const SizedBox(width: 6),
                      _MobileSectionChip(
                        label: s.label,
                        selected: section == s,
                        onTap: () => ref
                            .read(appSectionProvider.notifier)
                            .state = s,
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
            color:
                selected ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _MobileSessionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueChanged<String> onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onReconnect;

  const _MobileSessionChip({
    required this.label,
    required this.selected,
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
              leading: Icon(Icons.drive_file_rename_outline,
                  size: 20, color: AppColors.textSecondary),
              title: const Text('Rename'),
              onTap: () {
                Navigator.of(context).pop();
                _promptRename(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.copy_outlined,
                  size: 20, color: AppColors.textSecondary),
              title: const Text('Duplicate'),
              onTap: () {
                Navigator.of(context).pop();
                onDuplicate();
              },
            ),
            ListTile(
              leading: Icon(Icons.refresh,
                  size: 20, color: AppColors.textSecondary),
              title: const Text('Reconnect'),
              onTap: () {
                Navigator.of(context).pop();
                onReconnect();
              },
            ),
            ListTile(
              leading: Icon(Icons.close,
                  size: 20, color: AppColors.danger),
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
                child: Icon(
                  Icons.close,
                  size: 13,
                  color: AppColors.textFaint,
                ),
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
            ],
          ),
        ),
      ),
    );
  }
}

/// The main app shell: sidebar and the section content. Hosted as the home
/// route of the nested [appNavigatorKey] navigator so that pushed routes
/// (like SFTP) stay below the window title bar.
class _AppShell extends ConsumerWidget {
  const _AppShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionCount =
        ref.watch(sessionManagerProvider.select((m) => m.sessions.length));
    final hasSessions = sessionCount > 0;
    // Keep the sync controller alive for the whole app session: it restores
    // the account, watches local data changes and auto-syncs in the background.
    ref.watch(syncControllerProvider);

    final section = ref.watch(appSectionProvider);
    final sidebarOpen = ref.watch(sidebarOpenProvider);
    final isWide = MediaQuery.sizeOf(context).width >= 760;
    final effective =
        (!hasSessions && section == AppSection.terminals)
            ? AppSection.hosts
            : section;
    final selection = ref.watch(selectionBarProvider);

    // A floating multi-select bar belongs to the screen that published it.
    // Switching sections must dismiss it, otherwise it lingers over the
    // next page (hosts selection showing on keys, etc.).
    ref.listen(appSectionProvider, (_, _) {
      ref.read(selectionBarProvider.notifier).state = null;
      // Clear the hovered card target so a hidden screen's last-hovered card
      // can't trigger the 'e' edit shortcut while typing in another section.
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
                    const KeysScreen(),
                    const KnownHostsScreen(),
                    const SnippetsScreen(),
                    const LogsScreen(),
                    const SettingsScreen(),
                    hasSessions ? TerminalScreen() : const SizedBox.shrink(),
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
