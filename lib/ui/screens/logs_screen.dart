import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';

enum _LogTab { sessions, tunnels }

class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final _scrollController = ScrollController();
  _LogTab _tab = _LogTab.sessions;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_tab != _LogTab.sessions) return;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      ref.read(sessionLogsProvider.notifier).loadMore();
    }
  }

  Future<void> _clearLogs() async {
    if (_tab == _LogTab.sessions) {
      await _clearSessionLogs();
    } else {
      await _clearTunnelLogs();
    }
  }

  Future<void> _clearSessionLogs() async {
    final state = ref.read(sessionLogsProvider).valueOrNull;
    final count = state?.total ?? 0;
    final confirmed = await _confirmClear(
      title: 'Clear session logs?',
      message: count == 0
          ? 'All logged sessions will be removed. This cannot be undone.'
          : 'Remove all $count logged session(s)? This cannot be undone.',
    );
    if (confirmed == true) {
      await ref.read(sessionLogsProvider.notifier).clearAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session logs cleared')),
      );
    }
  }

  Future<void> _clearTunnelLogs() async {
    final confirmed = await _confirmClear(
      title: 'Clear tunnel logs?',
      message: 'All tunnel event entries will be removed. '
          'This cannot be undone.',
    );
    if (confirmed == true) {
      await ref.read(appDatabaseProvider).clearTunnelLogs();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tunnel logs cleared')),
      );
    }
  }

  Future<bool?> _confirmClear({
    required String title,
    required String message,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
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
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logsAsync = ref.watch(sessionLogsProvider);
    final tunnelLogsAsync = ref.watch(tunnelLogsProvider);

    final Widget countLabel = _tab == _LogTab.sessions
        ? logsAsync.when(
            skipLoadingOnReload: true,
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            data: (state) => Text(
              '${state.total} total',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textFaint,
              ),
            ),
          )
        : tunnelLogsAsync.when(
            skipLoadingOnReload: true,
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            data: (logs) => Text(
              '${logs.length} recent',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textFaint,
              ),
            ),
          );

    Widget buildClearButton({VisualDensity? density}) => TextButton.icon(
          onPressed: _clearLogs,
          icon: const Icon(Icons.delete_sweep_outlined, size: 15),
          label: const Text('Clear logs'),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.danger,
            visualDensity: density,
          ),
        );

    final Widget content = Expanded(
      child: _tab == _LogTab.sessions
          ? _buildSessions(logsAsync)
          : _buildTunnelLogs(tunnelLogsAsync),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        if (!compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border(bottom: BorderSide(color: AppColors.border)),
                ),
                child: Row(
                  children: [
                    _TabButton(
                      label: 'Sessions',
                      selected: _tab == _LogTab.sessions,
                      onTap: () => setState(() => _tab = _LogTab.sessions),
                    ),
                    const SizedBox(width: 6),
                    _TabButton(
                      label: 'Tunnels',
                      selected: _tab == _LogTab.tunnels,
                      onTap: () => setState(() => _tab = _LogTab.tunnels),
                    ),
                    const Spacer(),
                    countLabel,
                    const SizedBox(width: 12),
                    buildClearButton(),
                  ],
                ),
              ),
              content,
            ],
          );
        }
        // Phones: tabs on the left; Clear logs on the right with the
        // entry count right underneath it.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                children: [
                  _TabButton(
                    label: 'Sessions',
                    selected: _tab == _LogTab.sessions,
                    onTap: () => setState(() => _tab = _LogTab.sessions),
                  ),
                  const SizedBox(width: 6),
                  _TabButton(
                    label: 'Tunnels',
                    selected: _tab == _LogTab.tunnels,
                    onTap: () => setState(() => _tab = _LogTab.tunnels),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      buildClearButton(density: VisualDensity.compact),
                      countLabel,
                    ],
                  ),
                ],
              ),
            ),
            content,
          ],
        );
      },
    );
  }

  Widget _buildSessions(AsyncValue<SessionLogsState> logsAsync) {
    return logsAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (state) {
        if (state.logs.isEmpty) {
          return const _SessionEmptyState();
        }
        return ListView.separated(
          controller: _scrollController,
          padding: const EdgeInsets.all(20),
          itemCount: state.logs.length + (state.hasMore ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            if (index >= state.logs.length) {
              return _LoadMoreTile(
                loading: state.loadingMore,
                onLoadMore: () =>
                    ref.read(sessionLogsProvider.notifier).loadMore(),
              );
            }
            return _LogTile(log: state.logs[index]);
          },
        );
      },
    );
  }

  Widget _buildTunnelLogs(AsyncValue<List<TunnelLog>> logsAsync) {
    return logsAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (logs) {
        if (logs.isEmpty) {
          return const _TunnelEmptyState();
        }
        return ListView.separated(
          padding: const EdgeInsets.all(20),
          itemCount: logs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) =>
              _TunnelLogTile(log: logs[index]),
        );
      },
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentMuted : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected ? AppColors.accentBorder : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.accent : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _LoadMoreTile extends StatelessWidget {
  final bool loading;
  final VoidCallback onLoadMore;

  const _LoadMoreTile({required this.loading, required this.onLoadMore});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: onLoadMore,
              child: const Text('Load more'),
            ),
    );
  }
}

class _SessionEmptyState extends StatelessWidget {
  const _SessionEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.accentBorder),
            ),
            child: Icon(
              Icons.receipt_long_outlined,
              size: 30,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'No sessions logged yet',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            'Every SSH connection is recorded here with its connect and '
            'disconnect times.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _TunnelEmptyState extends StatelessWidget {
  const _TunnelEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.accentBorder),
            ),
            child: Icon(
              Icons.lan_outlined,
              size: 30,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'No tunnel events yet',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            'Tunnel starts, stops and errors are recorded here — including '
            'the full error message and stack trace when a tunnel fails.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final SessionLog log;

  const _LogTile({required this.log});

  @override
  Widget build(BuildContext context) {
    final stillConnected = log.disconnectedAt == null;
    final duration = stillConnected
        ? null
        : log.disconnectedAt!.difference(log.connectedAt);

    final Widget statusIcon = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: stillConnected
            ? AppColors.accentMuted
            : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(
        stillConnected ? Icons.link : Icons.link_off,
        size: 16,
        color: stillConnected ? AppColors.accent : AppColors.textFaint,
      ),
    );

    final Widget title = Text(
      '${log.username}@${log.address}',
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        fontFamily: 'JetBrainsMono',
      ),
    );

    final Widget connectedLine = Text(
      'Connected ${_formatDate(log.connectedAt)}'
      '${stillConnected ? ' — still connected' : ''}',
      style: TextStyle(
        fontSize: 12,
        color: AppColors.textFaint,
      ),
    );

    final Widget activeBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accentMuted,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Text(
        'ACTIVE',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.accent,
        ),
      ),
    );

    // Only build these when the session actually ended: interpolating
    // disconnectedAt/duration eagerly would crash on active tiles.
    Widget? disconnectedDetails({required CrossAxisAlignment align}) =>
        stillConnected
            ? null
            : Column(
                crossAxisAlignment: align,
                children: [
                  Text(
                    'Disconnected ${_formatDate(log.disconnectedAt!)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textFaint,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Duration ${_formatDuration(duration!)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              );

    return LayoutBuilder(
      builder: (context, constraints) {
        // The side-by-side layout (title + a right column of disconnect
        // details) needs ~480px; below that the right column squeezes the
        // middle text into mid-word wrapping ("conne/cted/2026-/..."),
        // so stack everything instead.
        final compact = constraints.maxWidth < 480;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: compact
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    statusIcon,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(child: title),
                              if (stillConnected) ...[
                                const SizedBox(width: 8),
                                activeBadge,
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          connectedLine,
                          // Left-aligned to match the lines above it.
                          if (!stillConnected) ...[
                            const SizedBox(height: 3),
                            disconnectedDetails(
                              align: CrossAxisAlignment.start,
                            )!,
                          ],
                        ],
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    statusIcon,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title,
                          const SizedBox(height: 3),
                          connectedLine,
                        ],
                      ),
                    ),
                    if (stillConnected)
                      activeBadge
                    else
                      disconnectedDetails(
                        align: CrossAxisAlignment.end,
                      )!,
                  ],
                ),
        );
      },
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _formatDuration(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)} h';
    if (minutes > 0) return '$minutes:${two(seconds)} min';
    return '$seconds s';
  }
}

class _TunnelLogTile extends StatelessWidget {
  final TunnelLog log;

  const _TunnelLogTile({required this.log});

  @override
  Widget build(BuildContext context) {
    final isError = log.level == 'error';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError
              ? Colors.redAccent.withValues(alpha: 0.45)
              : AppColors.border,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: isError
                  ? Colors.redAccent.withValues(alpha: 0.14)
                  : AppColors.accentMuted,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              isError ? Icons.bolt : Icons.lan_outlined,
              size: 16,
              color: isError
                  ? Colors.redAccent.shade200
                  : AppColors.accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        log.tunnelName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        log.tunnelType,
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: 'JetBrainsMono',
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    if (isError) ...[
                      const SizedBox(width: 6),
                      Text(
                        'ERROR',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: Colors.redAccent.shade200,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _formatDate(log.createdAt),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textFaint,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 6),
                // Full message — wraps so nothing is cut off.
                SelectableText(
                  log.message,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    fontFamily: 'JetBrainsMono',
                    color: isError
                        ? Colors.redAccent.shade100
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
