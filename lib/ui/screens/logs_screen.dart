import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';

class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final _scrollController = ScrollController();

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
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      ref.read(sessionLogsProvider.notifier).loadMore();
    }
  }

  Future<void> _clearLogs() async {
    final state = ref.read(sessionLogsProvider).valueOrNull;
    final count = state?.total ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear session logs?'),
        content: Text(
          count == 0
              ? 'All logged sessions will be removed. This cannot be undone.'
              : 'Remove all $count logged session(s)? This cannot be undone.',
        ),
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
    if (confirmed == true) {
      await ref.read(sessionLogsProvider.notifier).clearAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session logs cleared')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final logsAsync = ref.watch(sessionLogsProvider);

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
              Icon(
                Icons.receipt_long_outlined,
                size: 16,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Session logs',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              logsAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (state) => Text(
                  '${state.total} total',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: _clearLogs,
                icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                label: const Text('Clear logs'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.danger,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: logsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (state) {
              if (state.logs.isEmpty) {
                return const _EmptyState();
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
          ),
        ),
      ],
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

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

class _LogTile extends StatelessWidget {
  final SessionLog log;

  const _LogTile({required this.log});

  @override
  Widget build(BuildContext context) {
    final stillConnected = log.disconnectedAt == null;
    final duration = stillConnected
        ? null
        : log.disconnectedAt!.difference(log.connectedAt);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
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
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${log.username}@${log.address}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Connected ${_formatDate(log.connectedAt)}'
                  '${stillConnected ? ' — still connected' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textFaint,
                  ),
                ),
              ],
            ),
          ),
          if (stillConnected)
            Container(
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
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
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
