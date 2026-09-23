import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/host_protocol.dart';
import '../../core/remote/remote_session.dart';
import '../../core/ssh/session_manager.dart';
import '../state/nav.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../widgets/list_tiles.dart';
import '../widgets/new_output_dot.dart';

/// Which kind of live connections the list page shows.
enum ActiveConnectionKind { terminals, remotes }

/// A Hosts-style in-shell page listing every live connection of one kind.
/// Tapping a card switches the section to that session's live view.
class ActiveConnectionsScreen extends ConsumerStatefulWidget {
  const ActiveConnectionsScreen({super.key, required this.kind});

  final ActiveConnectionKind kind;

  @override
  ConsumerState<ActiveConnectionsScreen> createState() =>
      _ActiveConnectionsScreenState();
}

class _ActiveConnectionsScreenState
    extends ConsumerState<ActiveConnectionsScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  bool get _isTerminals => widget.kind == ActiveConnectionKind.terminals;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
          ),
          child: ListSearchField(
            controller: _searchController,
            query: _query,
            hintText: _isTerminals
                ? 'Search sessions, users, hosts...'
                : 'Search desktops, users, hosts...',
            onChanged: (value) => setState(() => _query = value),
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
        ),
        Expanded(
          child: _isTerminals
              ? _TerminalConnectionsList(query: _query)
              : _RemoteConnectionsList(query: _query),
        ),
      ],
    );
  }
}

bool _matchesQuery(String query, List<String> fields) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return fields.any((field) => field.toLowerCase().contains(q));
}

void _openTerminal(WidgetRef ref, TerminalSession session) {
  ref.read(sessionManagerProvider).activeSessionId = session.id;
  ref.read(appSectionProvider.notifier).state = AppSection.terminals;
  ref.read(liveSessionViewProvider.notifier).state = true;
}

void _openRemote(WidgetRef ref, RemoteSession session) {
  ref.read(remoteManagerProvider).setActive(session.id);
  ref.read(appSectionProvider.notifier).state = AppSection.remotes;
  ref.read(liveSessionViewProvider.notifier).state = true;
}

class _TerminalConnectionsList extends ConsumerWidget {
  const _TerminalConnectionsList({required this.query});

  final String query;

  void _showMenu(BuildContext context, WidgetRef ref, TerminalSession session) {
    final manager = ref.read(sessionManagerProvider);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetTitle(session.label),
            ListTile(
              leading: Icon(
                Icons.open_in_new,
                size: 20,
                color: AppColors.textSecondary,
              ),
              title: const Text('Open'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openTerminal(ref, session);
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
                Navigator.of(sheetContext).pop();
                manager.reconnect(session);
              },
            ),
            ListTile(
              leading: Icon(Icons.close, size: 20, color: AppColors.danger),
              title: const Text('Close'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                manager.closeSession(session);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(sessionManagerProvider);
    final rows = <Widget>[
      for (final session in manager.sessions)
        if (!session.isClosed &&
            _matchesQuery(query, [
              session.label,
              session.request.username,
              session.request.address,
              session.request.displayName,
            ]))
          ListCard(
            icon: Icons.terminal,
            iconColor: _terminalStatusColor(session.status),
            title: session.label,
            subtitle: '${session.request.username}@${session.request.address}',
            trailing: session.hasUnseenOutput ? const NewOutputDot() : null,
            onTap: () => _openTerminal(ref, session),
            onLongPress: (_) => _showMenu(context, ref, session),
          ),
    ];

    if (rows.isEmpty) {
      return const _EmptyState(kind: ActiveConnectionKind.terminals);
    }
    return _SessionGrid(rows: rows);
  }
}

class _RemoteConnectionsList extends ConsumerWidget {
  const _RemoteConnectionsList({required this.query});

  final String query;

  void _showMenu(BuildContext context, WidgetRef ref, RemoteSession session) {
    final manager = ref.read(remoteManagerProvider);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetTitle(session.title),
            ListTile(
              leading: Icon(
                Icons.open_in_new,
                size: 20,
                color: AppColors.textSecondary,
              ),
              title: const Text('Open'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _openRemote(ref, session);
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
                Navigator.of(sheetContext).pop();
                manager.reconnect(session.id);
              },
            ),
            ListTile(
              leading: Icon(Icons.close, size: 20, color: AppColors.danger),
              title: const Text('Close'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                manager.close(session.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(remoteManagerProvider);
    final rows = <Widget>[
      for (final session in manager.sessions)
        if (_matchesQuery(query, [
          session.title,
          session.username ?? '',
          session.address,
        ]))
          ListCard(
            icon: session.protocol == HostProtocol.vnc
                ? Icons.screen_share_outlined
                : Icons.desktop_windows_outlined,
            iconColor: _remoteStatusColor(session.status),
            title: session.title,
            subtitle: (session.username ?? '').isEmpty
                ? session.address
                : '${session.username}@${session.address}',
            onTap: () => _openRemote(ref, session),
            onLongPress: (_) => _showMenu(context, ref, session),
          ),
    ];

    if (rows.isEmpty) {
      return const _EmptyState(kind: ActiveConnectionKind.remotes);
    }
    return _SessionGrid(rows: rows);
  }
}

class _SessionGrid extends StatelessWidget {
  const _SessionGrid({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: ListSectionHeader('Sessions')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 300,
              mainAxisExtent: 64,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => rows[index],
              childCount: rows.length,
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

Color _terminalStatusColor(SessionStatus status) => switch (status) {
  SessionStatus.connected => AppColors.accent,
  SessionStatus.connecting => AppColors.warning,
  SessionStatus.verifyingHostKey => AppColors.warning,
  SessionStatus.disconnected => AppColors.textFaint,
  SessionStatus.error => AppColors.danger,
};

Color _remoteStatusColor(RemoteStatus status) => switch (status) {
  RemoteStatus.connected => AppColors.accent,
  RemoteStatus.connecting => AppColors.warning,
  RemoteStatus.disconnected => AppColors.textFaint,
  RemoteStatus.error => AppColors.danger,
};

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.kind});

  final ActiveConnectionKind kind;

  @override
  Widget build(BuildContext context) {
    final isTerminals = kind == ActiveConnectionKind.terminals;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isTerminals ? Icons.terminal : Icons.desktop_windows_outlined,
              size: 44,
              color: AppColors.textFaint,
            ),
            const SizedBox(height: 12),
            Text(
              'No active connections',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isTerminals
                  ? 'Open a session from the Hosts tab'
                  : 'Connect to a host from the Hosts tab',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
