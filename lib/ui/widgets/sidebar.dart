import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/sync_controller.dart';
import '../state/nav.dart';
import '../theme/app_colors.dart';

class Sidebar extends ConsumerWidget {
  final AppSection current;
  final ValueChanged<AppSection> onSelect;

  const Sidebar({super.key, required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final expanded = width >= 1160;
    final padding = expanded
        ? const EdgeInsets.symmetric(horizontal: 12)
        : const EdgeInsets.symmetric(horizontal: 6);

    return Container(
      width: expanded ? 224 : 64,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 10),
              children: [
                for (final s in const [
                  AppSection.hosts,
                  AppSection.metrics,
                  AppSection.keys,
                  AppSection.tunnels,
                  AppSection.snippets,
                  AppSection.knownHosts,
                  AppSection.logs,
                  AppSection.teams,
                ])
                  Padding(
                    padding: padding,
                    child: _NavButton(
                      icon: s.icon,
                      label: s.label,
                      expanded: expanded,
                      selected: current == s,
                      onTap: () => onSelect(s),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: padding.add(const EdgeInsets.symmetric(vertical: 8)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SyncStatusTile(expanded: expanded, onSelect: onSelect),
                const SizedBox(height: 2),
                _NavButton(
                  icon: AppSection.settings.icon,
                  label: AppSection.settings.label,
                  expanded: expanded,
                  selected: current == AppSection.settings,
                  onTap: () => onSelect(AppSection.settings),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncStatusTile extends ConsumerStatefulWidget {
  final bool expanded;
  final ValueChanged<AppSection> onSelect;

  const _SyncStatusTile({required this.expanded, required this.onSelect});

  @override
  ConsumerState<_SyncStatusTile> createState() => _SyncStatusTileState();
}

class _SyncStatusTileState extends ConsumerState<_SyncStatusTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncControllerProvider);
    final signedIn = sync.status == SyncStatus.signedIn;
    final status = _resolveStatus(sync, signedIn);

    return _StatusButton(
      expanded: widget.expanded,
      label: _label(sync, status, signedIn),
      status: status,
      sync: sync,
      signedIn: signedIn,
      onOpenSettings: () => widget.onSelect(AppSection.settings),
      onSyncNow: signedIn && !sync.busy
          ? () => ref.read(syncControllerProvider.notifier).syncNow()
          : null,
    );
  }

  _StatusKind _resolveStatus(SyncState sync, bool signedIn) {
    if (!signedIn) return _StatusKind.off;
    if (sync.busy) return _StatusKind.busy;
    if (sync.error != null) return _StatusKind.error;
    if (sync.pendingSync) return _StatusKind.pending;
    return _StatusKind.synced;
  }

  String _label(SyncState sync, _StatusKind status, bool signedIn) {
    switch (status) {
      case _StatusKind.off:
        return 'Sync off';
      case _StatusKind.busy:
        return 'Syncing…';
      case _StatusKind.error:
        return 'Sync error';
      case _StatusKind.pending:
        return 'Pending changes';
      case _StatusKind.synced:
        final at = sync.lastSyncedAt;
        if (at == null) return 'Never synced';
        return 'Synced ${_relative(at)}';
    }
  }

  String _relative(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

enum _StatusKind { off, busy, error, pending, synced }

class _StatusButton extends StatelessWidget {
  final bool expanded;
  final String label;
  final _StatusKind status;
  final SyncState sync;
  final bool signedIn;
  final VoidCallback onOpenSettings;
  final VoidCallback? onSyncNow;

  const _StatusButton({
    required this.expanded,
    required this.label,
    required this.status,
    required this.sync,
    required this.signedIn,
    required this.onOpenSettings,
    required this.onSyncNow,
  });

  Color get _color {
    switch (status) {
      case _StatusKind.off:
        return AppColors.textFaint;
      case _StatusKind.busy:
        return AppColors.accent;
      case _StatusKind.error:
        return AppColors.danger;
      case _StatusKind.pending:
        return AppColors.warning;
      case _StatusKind.synced:
        return AppColors.success;
    }
  }

  IconData get _icon {
    switch (status) {
      case _StatusKind.off:
        return Icons.cloud_off_outlined;
      case _StatusKind.busy:
        return Icons.cloud_sync_outlined;
      case _StatusKind.error:
        return Icons.cloud_off_outlined;
      case _StatusKind.pending:
        return Icons.cloud_upload_outlined;
      case _StatusKind.synced:
        return Icons.cloud_done_outlined;
    }
  }

  String get _tooltip {
    final parts = <String>[label];
    if (signedIn) {
      if (sync.email != null) parts.add(sync.email!);
      parts.add('Auto-sync every 2 min');
    }
    if (sync.error != null) parts.add(sync.error!);
    return parts.join(' · ');
  }

  Widget _statusIcon() {
    if (status == _StatusKind.busy) {
      return SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(strokeWidth: 2, color: _color),
      );
    }
    return Icon(_icon, size: 18, color: _color);
  }

  @override
  Widget build(BuildContext context) {
    if (!expanded) {
      return Tooltip(
        message: signedIn ? '$_tooltip\nClick to sync now' : _tooltip,
        child: InkWell(
          onTap: signedIn ? onSyncNow : onOpenSettings,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(height: 38, child: Center(child: _statusIcon())),
        ),
      );
    }

    final statusTile = Tooltip(
      message: _tooltip,
      child: InkWell(
        onTap: onOpenSettings,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              SizedBox(width: 18, child: Center(child: _statusIcon())),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: status == _StatusKind.error
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: status == _StatusKind.off
                        ? AppColors.textFaint
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Row(
      children: [
        Expanded(child: statusTile),
        if (signedIn) ...[
          const SizedBox(width: 2),
          _SyncNowButton(busy: sync.busy, onPressed: onSyncNow),
        ],
      ],
    );
  }
}

class _SyncNowButton extends StatelessWidget {
  final bool busy;
  final VoidCallback? onPressed;

  const _SyncNowButton({required this.busy, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: busy ? 'Syncing…' : 'Sync now',
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(
            Icons.sync_rounded,
            size: 16,
            color: busy ? AppColors.textFaint : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;

  const _NavButton({
    required this.icon,
    required this.label,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 38,
        padding: expanded ? const EdgeInsets.symmetric(horizontal: 10) : null,
        decoration: BoxDecoration(
          color: selected ? AppColors.accentMuted : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.accentBorder : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? AppColors.accent : AppColors.textSecondary,
            ),
            if (expanded) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (expanded) return content;
    return Tooltip(message: label, child: content);
  }
}
