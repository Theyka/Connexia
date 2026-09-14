import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/ssh/metrics_controller.dart';
import '../../core/ssh/metrics_service.dart';
import '../state/connection_helpers.dart';
import '../state/providers.dart';
import '../../core/sync/team_providers.dart'
    show scopedGroupsProvider, scopedHostsProvider;
import '../theme/app_colors.dart';

/// Host Metrics tab: a per-server live dashboard (CPU, memory, disks,
/// network, temperature, load, uptime, processes, ports, logins, system
/// info), device-local history graphs, and manager cards for systemd
/// services and the crontab.
class MetricsScreen extends ConsumerWidget {
  const MetricsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(metricsControllerProvider);
    final hosts = ref.watch(scopedHostsProvider).valueOrNull ?? const <Host>[];
    final selected = controller.selectedHostId;

    // Tracked hosts in watchlist order, resolved against saved hosts.
    final tracked = [
      for (final id in controller.watchlist)
        if (hosts.any((h) => h.id == id)) hosts.firstWhere((h) => h.id == id),
    ].cast<Host>();

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final dashboard = _Dashboard(selectedHostId: selected, hosts: hosts);

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 264,
                child: _Rail(
                  selected: selected,
                  tracked: tracked,
                  allHosts: hosts,
                ),
              ),
              VerticalDivider(width: 1, color: AppColors.border),
              Expanded(child: dashboard),
            ],
          );
        }

        // Mobile / narrow: tracked hosts as a horizontal chip strip.
        return Column(
          children: [
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                children: [
                  for (final h in tracked)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _HostChip(
                        host: h,
                        selected: h.id == selected,
                        state: controller.stateOf(h.id),
                        onTap: () => controller.select(h.id),
                        onRemove: () => controller.toggleWatch(h.id),
                      ),
                    ),
                  _AddChip(onPick: () => _pickHosts(context, hosts)),
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            Expanded(child: dashboard),
          ],
        );
      },
    );
  }

  /// Opens the picker dialog listing saved hosts that can be tracked.
  Future<void> _pickHosts(BuildContext context, List<Host> hosts) async {
    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder: (_) => const _TrackHostDialog(),
    );
  }
}

// ---------------------------------------------------------------------------
// Left rail (desktop)
// ---------------------------------------------------------------------------

class _Rail extends ConsumerWidget {
  final String? selected;
  final List<Host> tracked;
  final List<Host> allHosts;

  const _Rail({
    required this.selected,
    required this.tracked,
    required this.allHosts,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(metricsControllerProvider);
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'SERVERS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Add server',
                  child: InkWell(
                    onTap: () async {
                      if (!context.mounted) return;
                      await showDialog(
                        context: context,
                        builder: (_) => const _TrackHostDialog(),
                      );
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.border),
                        color: AppColors.surfaceAlt,
                      ),
                      child: Icon(
                        Icons.add,
                        size: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          Expanded(
            child: tracked.isEmpty
                ? _RailEmpty()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    itemCount: tracked.length,
                    itemBuilder: (context, i) => _RailTile(
                      host: tracked[i],
                      selected: tracked[i].id == selected,
                      state: controller.stateOf(tracked[i].id),
                      onTap: () => controller.select(tracked[i].id),
                      onRemove: () => controller.toggleWatch(tracked[i].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _RailEmpty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.query_stats_outlined,
              size: 32,
              color: AppColors.textFaint,
            ),
            const SizedBox(height: 10),
            Text(
              'No servers tracked',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Add a saved host to start collecting metrics.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailTile extends StatefulWidget {
  final Host host;
  final bool selected;
  final HostMetricsState state;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _RailTile({
    required this.host,
    required this.selected,
    required this.state,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_RailTile> createState() => _RailTileState();
}

class _RailTileState extends State<_RailTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final sample = s.last;
    final memPct = (sample?.memTotalMb ?? 0) > 0 ? sample!.memPct : null;
    // Status line replaces the address while connecting or failing.
    final (statusText, statusColor) = switch (s.pollState) {
      HostPollState.error => (s.error ?? 'Offline', AppColors.danger),
      HostPollState.connecting => ('Connecting…', AppColors.warning),
      _ => (
        '${widget.host.username}@${widget.host.address}',
        AppColors.textFaint,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: widget.selected
                  ? AppColors.accentMuted
                  : _hover
                  ? AppColors.cardHover
                  : null,
              border: Border.all(
                color: widget.selected
                    ? AppColors.accentBorder
                    : Colors.transparent,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _pollDotColor(s),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.host.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: widget.selected
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                    // Fixed slot so the row doesn't reflow on hover.
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: _hover
                          ? Tooltip(
                              message: 'Stop tracking',
                              child: InkWell(
                                onTap: widget.onRemove,
                                borderRadius: BorderRadius.circular(4),
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: AppColors.textFaint,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 1),
                  child: Text(
                    statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: statusColor),
                  ),
                ),
                if (sample != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, top: 8),
                    child: Opacity(
                      // Dim stale readings while the host is unreachable.
                      opacity: s.pollState == HostPollState.error ? 0.5 : 1,
                      child: Column(
                        children: [
                          _RailMeter(label: 'CPU', pct: sample.cpuPct),
                          const SizedBox(height: 5),
                          _RailMeter(label: 'RAM', pct: memPct),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              _rate(
                                Icons.arrow_downward,
                                AppColors.success,
                                sample.netRxRate,
                                'Download',
                              ),
                              const SizedBox(width: 10),
                              _rate(
                                Icons.arrow_upward,
                                AppColors.info,
                                sample.netTxRate,
                                'Upload',
                              ),
                            ],
                          ),
                        ],
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

  Widget _rate(IconData icon, Color color, double bytesPerSec, String what) {
    return Expanded(
      child: Tooltip(
        message: '$what speed',
        child: Row(
          children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                '${bytesF(bytesPerSec)}/s',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact labelled usage bar for the server list ("CPU ▮▮▮▯▯ 42%").
class _RailMeter extends StatelessWidget {
  final String label;
  final double? pct;

  const _RailMeter({required this.label, required this.pct});

  @override
  Widget build(BuildContext context) {
    final value = pct;
    return Row(
      children: [
        SizedBox(
          width: 30,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.textFaint,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 4,
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: _barTrackColor,
              borderRadius: BorderRadius.circular(2),
            ),
            child: FractionallySizedBox(
              widthFactor: (value ?? 0).clamp(0, 100) / 100,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _levelColor(_pctLevel(value ?? 0)),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value == null ? '--' : '${value.toStringAsFixed(0)}%',
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

Color _pollDotColor(HostMetricsState s) => switch (s.pollState) {
  HostPollState.ok => AppColors.success,
  HostPollState.error => AppColors.danger,
  HostPollState.connecting => AppColors.warning,
  HostPollState.idle => AppColors.textFaint,
};

class _HostChip extends StatelessWidget {
  final Host host;
  final bool selected;
  final HostMetricsState state;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _HostChip({
    required this.host,
    required this.selected,
    required this.state,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected ? AppColors.accentMuted : Colors.transparent,
          border: Border.all(
            color: selected ? AppColors.accentBorder : AppColors.border,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _pollDotColor(state),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              host.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 6),
            InkWell(
              onTap: onRemove,
              child: Icon(Icons.close, size: 13, color: AppColors.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddChip extends StatelessWidget {
  final VoidCallback onPick;

  const _AddChip({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 4),
            Text(
              'Add',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog listing saved hosts that aren't tracked yet; tapping adds them.
class _TrackHostDialog extends ConsumerStatefulWidget {
  const _TrackHostDialog();

  @override
  ConsumerState<_TrackHostDialog> createState() => _TrackHostDialogState();
}

/// Browses saved hosts the way the Hosts page does: groups first (open one
/// to see inside), hosts after, and a search across names, addresses, users
/// and tags that also surfaces the groups holding matches.
class _TrackHostDialogState extends ConsumerState<_TrackHostDialog> {
  String _query = '';
  String? _openGroupId;

  Future<void> _setTracked(List<Host> hosts, bool track) async {
    final controller = ref.read(metricsControllerProvider);
    for (final h in hosts) {
      if (controller.watchlist.contains(h.id) != track) {
        await controller.toggleWatch(h.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(metricsControllerProvider);
    final allHosts =
        ref.watch(scopedHostsProvider).valueOrNull ?? const <Host>[];
    final groups =
        ref.watch(scopedGroupsProvider).valueOrNull ?? const <Group>[];
    final groupIds = {for (final g in groups) g.id};
    final openGroup = groups.where((g) => g.id == _openGroupId).firstOrNull;
    final q = _query.trim().toLowerCase();
    final searching = q.isNotEmpty;

    // [groupId] plus every group nested inside it.
    Set<String> subtree(String groupId) {
      final ids = {groupId};
      var grew = true;
      while (grew) {
        grew = false;
        for (final g in groups) {
          if (g.parentId != null && ids.contains(g.parentId) && ids.add(g.id)) {
            grew = true;
          }
        }
      }
      return ids;
    }

    List<Host> hostsIn(String groupId) {
      final ids = subtree(groupId);
      return [
        for (final h in allHosts)
          if (h.groupId != null && ids.contains(h.groupId)) h,
      ];
    }

    bool matches(Host h) =>
        h.name.toLowerCase().contains(q) ||
        h.address.toLowerCase().contains(q) ||
        h.username.toLowerCase().contains(q) ||
        h.tags.toLowerCase().contains(q);

    final List<Group> shownGroups;
    final List<Host> shownHosts;
    if (searching) {
      final scopeIds = openGroup == null ? null : subtree(openGroup.id);
      shownHosts = [
        for (final h in openGroup == null ? allHosts : hostsIn(openGroup.id))
          if (matches(h)) h,
      ];
      final holding = {for (final h in shownHosts) h.groupId};
      shownGroups = [
        for (final g in groups)
          if (g.id != openGroup?.id &&
              (scopeIds == null || scopeIds.contains(g.id)) &&
              (g.name.toLowerCase().contains(q) || holding.contains(g.id)))
            g,
      ];
    } else {
      shownGroups = [
        for (final g in groups)
          if (openGroup == null
              ? (g.parentId == null || !groupIds.contains(g.parentId))
              : g.parentId == openGroup.id)
            g,
      ];
      shownHosts = [
        for (final h in allHosts)
          if (openGroup == null
              ? (h.groupId == null || !groupIds.contains(h.groupId))
              : h.groupId == openGroup.id)
            h,
      ];
    }
    int byName(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    shownGroups.sort((a, b) => byName(a.name, b.name));
    shownHosts.sort((a, b) => byName(a.name, b.name));

    Widget groupRow(Group g) {
      final inGroup = hostsIn(g.id);
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: _GroupPickRow(
          group: g,
          hostCount: inGroup.length,
          trackedCount: inGroup
              .where((h) => controller.watchlist.contains(h.id))
              .length,
          onOpen: () => setState(() => _openGroupId = g.id),
          onSetTracked: (track) => _setTracked(inGroup, track),
        ),
      );
    }

    final items = <Widget>[
      if (shownGroups.isNotEmpty) ...[
        const _PickSectionLabel('Groups'),
        for (final g in shownGroups) groupRow(g),
      ],
      if (shownHosts.isNotEmpty) ...[
        if (shownGroups.isNotEmpty) const SizedBox(height: 8),
        const _PickSectionLabel('Hosts'),
        for (final h in shownHosts)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _HostPickRow(
              host: h,
              tracked: controller.watchlist.contains(h.id),
              onToggle: () => controller.toggleWatch(h.id),
            ),
          ),
      ],
    ];

    final trackedCount = allHosts
        .where((h) => controller.watchlist.contains(h.id))
        .length;

    return Dialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 660),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.accentMuted,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.query_stats,
                      size: 19,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add servers to monitor',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Pick from your saved hosts. Metrics are collected '
                          'over SSH.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: AppColors.textFaint,
                    ),
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (allHosts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      Icon(
                        Icons.dns_outlined,
                        size: 36,
                        color: AppColors.textFaint,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'No saved hosts yet',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Add a host on the Hosts tab first, then come back '
                        'here.',
                        textAlign: TextAlign.center,
                        style: _labelStyle,
                      ),
                    ],
                  ),
                )
              else ...[
                TextField(
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(
                      Icons.search,
                      size: 17,
                      color: AppColors.textFaint,
                    ),
                    hintText: 'Search hosts, groups, addresses, tags...',
                    hintStyle: _labelStyle.copyWith(fontSize: 12.5),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    filled: true,
                    fillColor: AppColors.surfaceAlt,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
                if (openGroup != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back,
                          size: 17,
                          color: AppColors.textSecondary,
                        ),
                        tooltip: 'Back',
                        constraints: const BoxConstraints(
                          minWidth: 30,
                          minHeight: 30,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: () => setState(
                          () => _openGroupId =
                              groupIds.contains(openGroup.parentId)
                              ? openGroup.parentId
                              : null,
                        ),
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        onTap: () => setState(() => _openGroupId = null),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            'All servers',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: AppColors.textFaint,
                      ),
                      Expanded(
                        child: Text(
                          openGroup.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Flexible(
                  child: items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              searching
                                  ? 'No servers match "$_query".'
                                  : 'This group is empty.',
                              style: _cellStyle,
                            ),
                          ),
                        )
                      : ListView(shrinkWrap: true, children: items),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      trackedCount == 0
                          ? 'No servers tracked yet'
                          : '$trackedCount '
                                '${trackedCount == 1 ? 'server' : 'servers'} '
                                'tracked',
                      style: _labelStyle,
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickSectionLabel extends StatelessWidget {
  final String text;

  const _PickSectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: AppColors.textFaint,
        ),
      ),
    );
  }
}

/// A group in the add-servers dialog: tap to open it, or use the pill to
/// track / untrack every host inside (nested groups included).
class _GroupPickRow extends StatefulWidget {
  final Group group;
  final int hostCount;
  final int trackedCount;
  final VoidCallback onOpen;
  final ValueChanged<bool> onSetTracked;

  const _GroupPickRow({
    required this.group,
    required this.hostCount,
    required this.trackedCount,
    required this.onOpen,
    required this.onSetTracked,
  });

  @override
  State<_GroupPickRow> createState() => _GroupPickRowState();
}

class _GroupPickRowState extends State<_GroupPickRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final color = g.color != null ? Color(g.color!) : AppColors.accent;
    final allTracked =
        widget.hostCount > 0 && widget.trackedCount == widget.hostCount;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _hover ? AppColors.cardHover : AppColors.surfaceAlt,
            border: Border.all(
              color: _hover ? AppColors.borderStrong : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(Icons.folder_outlined, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '${widget.hostCount} '
                            '${widget.hostCount == 1 ? 'host' : 'hosts'}',
                        if (widget.trackedCount > 0)
                          '${widget.trackedCount} tracked',
                      ].join(' · '),
                      style: _labelStyle,
                    ),
                  ],
                ),
              ),
              if (widget.hostCount > 0) ...[
                const SizedBox(width: 12),
                _TrackPill(
                  tracked: allTracked,
                  addLabel: 'Add all',
                  trackedLabel: 'All tracked',
                  removeLabel: 'Remove all',
                  onTap: () => widget.onSetTracked(!allTracked),
                ),
              ],
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 18, color: AppColors.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// Add / Tracking toggle pill with its own hover (Remove while tracked).
class _TrackPill extends StatefulWidget {
  final bool tracked;
  final String addLabel;
  final String trackedLabel;
  final String removeLabel;
  final VoidCallback onTap;

  const _TrackPill({
    required this.tracked,
    required this.addLabel,
    required this.trackedLabel,
    required this.removeLabel,
    required this.onTap,
  });

  @override
  State<_TrackPill> createState() => _TrackPillState();
}

class _TrackPillState extends State<_TrackPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.tracked || _hover;
    final (icon, text, color) = widget.tracked
        ? (_hover
              ? (Icons.close, widget.removeLabel, AppColors.danger)
              : (Icons.check, widget.trackedLabel, AppColors.accent))
        : (
            Icons.add,
            widget.addLabel,
            _hover ? AppColors.accent : AppColors.textSecondary,
          );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: color.withValues(alpha: lit ? 0.14 : 0),
            border: Border.all(
              color: lit ? color.withValues(alpha: 0.4) : AppColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
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

/// One saved host in the add-servers dialog: colour initial, name, address,
/// tags, and an Add / Tracking toggle (Remove on hover).
class _HostPickRow extends StatefulWidget {
  final Host host;
  final bool tracked;
  final VoidCallback onToggle;

  const _HostPickRow({
    required this.host,
    required this.tracked,
    required this.onToggle,
  });

  @override
  State<_HostPickRow> createState() => _HostPickRowState();
}

class _HostPickRowState extends State<_HostPickRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    final tracked = widget.tracked;
    final color = h.color != null ? Color(h.color!) : AppColors.accent;
    final name = h.name.trim();
    final initial = name.isEmpty
        ? '?'
        : String.fromCharCode(name.runes.first).toUpperCase();
    final tags = h.tags
        .split(RegExp(r'[,;]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .take(3)
        .toList();

    final (actionIcon, actionText, actionColor) = tracked
        ? (_hover
              ? (Icons.close, 'Remove', AppColors.danger)
              : (Icons.check, 'Tracking', AppColors.accent))
        : (Icons.add, 'Add', AppColors.textSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: tracked
                ? AppColors.accentMuted
                : _hover
                ? AppColors.cardHover
                : AppColors.surfaceAlt,
            border: Border.all(
              color: tracked
                  ? AppColors.accentBorder
                  : _hover
                  ? AppColors.borderStrong
                  : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      h.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${h.username}@${h.address}'
                      '${h.port == 22 ? '' : ':${h.port}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _monoStyle.copyWith(color: AppColors.textFaint),
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final t in tags)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.card,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Text(
                                t,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: actionColor.withValues(alpha: tracked ? 0.14 : 0),
                  border: Border.all(
                    color: tracked
                        ? actionColor.withValues(alpha: 0.4)
                        : AppColors.border,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(actionIcon, size: 14, color: actionColor),
                    const SizedBox(width: 4),
                    Text(
                      actionText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: actionColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

class _Dashboard extends ConsumerStatefulWidget {
  final String? selectedHostId;
  final List<Host> hosts;

  const _Dashboard({required this.selectedHostId, required this.hosts});

  @override
  ConsumerState<_Dashboard> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<_Dashboard> {
  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(metricsControllerProvider);
    final selected = widget.selectedHostId;
    if (selected == null) return const _EmptyDashboard();

    final host = widget.hosts
        .where((h) => h.id == selected)
        .cast<Host?>()
        .firstOrNull;
    if (host == null) return const _EmptyDashboard();

    final state = controller.stateOf(selected);
    final s = state.last;

    // A plain scroll view rather than a lazy ListView: the sections differ
    // wildly in height, and a lazy list re-estimates its length as you
    // scroll, which made the page jump near the bottom. Building every
    // section also keeps card state (filters, pages, history) alive.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeaderCard(host: host, state: state),
          const _SectionHeader(
            title: 'At a glance',
            subtitle: 'Live readings, refreshed automatically.',
          ),
          _CardGrid(
            minTileWidth: 210,
            children: [
              _CpuTile(s: s),
              _MemoryTile(s: s),
              _StorageTile(s: s),
              _NetworkTile(s: s),
            ],
          ),
          const _SectionHeader(
            title: 'About this server',
            subtitle: 'The hardware and software this server runs on.',
          ),
          _AboutCard(s: s),
          const _SectionHeader(
            title: 'Workload & temperature',
            subtitle: 'How hard the server is working and how warm it runs.',
          ),
          _CardGrid(
            minTileWidth: 380,
            children: [
              _WorkloadCard(s: s),
              _TempsCard(s: s),
            ],
          ),
          const _SectionHeader(
            title: 'Storage',
            subtitle: 'Space used and free on each disk.',
          ),
          _DisksCard(s: s),
          const _SectionHeader(
            title: "What's running",
            subtitle:
                'Programs using the most processor time, and the '
                'ports other computers can connect to.',
          ),
          _CardGrid(
            minTileWidth: 380,
            children: [
              _ProcsCard(s: s),
              _PortsCard(s: s),
            ],
          ),
          const _SectionHeader(
            title: 'Sign-ins',
            subtitle: 'Who is signed in to this server now, and recently.',
          ),
          _LoginsCard(s: s),
          const _SectionHeader(
            title: 'History',
            subtitle:
                'Readings saved on this device while the server is '
                'tracked.',
          ),
          _HistorySection(hostId: selected),
          const _SectionHeader(
            title: 'Services',
            subtitle:
                'Background programs managed by systemd. You can '
                'start, stop or restart them here.',
          ),
          _ServicesCard(host: host),
          const _SectionHeader(
            title: 'Scheduled tasks',
            subtitle:
                'Commands that run automatically on a schedule '
                '(this user\'s crontab).',
          ),
          _CronCard(host: host),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _EmptyDashboard extends StatelessWidget {
  const _EmptyDashboard();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.query_stats_outlined,
            size: 42,
            color: AppColors.textFaint,
          ),
          const SizedBox(height: 12),
          Text(
            'Track a server to see its metrics',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Use the add button to pick from your saved hosts.\n'
            'Each host is polled over SSH; history is stored on this device.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.textFaint),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Layout building blocks
// ---------------------------------------------------------------------------

BoxDecoration _cardDecoration() => BoxDecoration(
  color: AppColors.card,
  borderRadius: BorderRadius.circular(12),
  border: Border.all(color: AppColors.border),
);

/// Unfilled part of usage bars. A translucent tint of the faint text
/// colour stays visible on every card and theme (surfaceAlt blended into
/// the card, hiding how much space is left).
Color get _barTrackColor => AppColors.textFaint.withValues(alpha: 0.25);

final _labelStyle = TextStyle(fontSize: 11, color: AppColors.textFaint);
final _cellStyle = TextStyle(fontSize: 12, color: AppColors.textSecondary);
final _monoStyle = TextStyle(
  fontFamily: 'JetBrainsMono',
  fontSize: 11,
  color: AppColors.textSecondary,
);

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 26, 2, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: AppColors.textFaint),
          ),
        ],
      ),
    );
  }
}

/// Lays cards out in equal-height rows. The column count shrinks with the
/// available width and always divides the card count evenly, so four tiles
/// become 4, 2 or 1 per row — never a lone straggler.
class _CardGrid extends StatelessWidget {
  final double minTileWidth;
  final List<Widget> children;

  const _CardGrid({required this.minTileWidth, required this.children});

  @override
  Widget build(BuildContext context) {
    const gap = 12.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        var columns = ((constraints.maxWidth + gap) ~/ (minTileWidth + gap))
            .clamp(1, children.length);
        while (columns > 1 && children.length % columns != 0) {
          columns--;
        }
        return Column(
          children: [
            for (var start = 0; start < children.length; start += columns) ...[
              if (start > 0) const SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = start; i < start + columns; i++) ...[
                      if (i > start) const SizedBox(width: gap),
                      Expanded(child: children[i]),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String title;

  /// Plain-language explanation shown from a help icon next to the title.
  final String? help;
  final Widget? trailing;
  final List<Widget> children;

  const _MetricCard({
    required this.icon,
    required this.title,
    this.help,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              // Title + help share one Expanded so [trailing] is pinned to
              // the right edge (a Flexible + Spacer pair splits the free
              // space and strands it mid-card).
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (help != null) ...[
                      const SizedBox(width: 6),
                      _HelpIcon(message: help!),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _HelpIcon extends StatelessWidget {
  final String message;

  const _HelpIcon({required this.message});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 250),
      child: Icon(Icons.help_outline, size: 13, color: AppColors.textFaint),
    );
  }
}

/// Square icon button with a hover highlight. While the action returned by
/// [onPressed] runs (or while [busy]), a spinner replaces the icon so it's
/// clear the refresh is happening.
class _IconAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Future<void> Function()? onPressed;
  final bool busy;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
  });

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hover = false;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      // Keep the spinner up briefly so very fast refreshes still register.
      await Future.wait([
        widget.onPressed!(),
        Future<void>.delayed(const Duration(milliseconds: 400)),
      ]);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.busy || _running;
    final enabled = widget.onPressed != null && !busy;
    final hot = _hover && enabled;
    return Tooltip(
      message: busy ? 'Refreshing…' : widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: enabled ? _run : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: hot ? AppColors.borderStrong : AppColors.border,
              ),
              color: hot ? AppColors.cardHover : AppColors.surfaceAlt,
            ),
            child: busy
                ? SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  )
                : Icon(
                    widget.icon,
                    size: 15,
                    color: hot
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }
}

class _BigValue extends StatelessWidget {
  final String value;
  final String unit;

  const _BigValue({required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    // One paragraph so value and unit share a baseline and ellipsize
    // together instead of overflowing narrow tiles.
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              height: 1.05,
              color: AppColors.textPrimary,
            ),
          ),
          if (unit.isNotEmpty)
            TextSpan(
              text: '  $unit',
              style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final double pct;
  final Color? color;

  const _ProgressBar({required this.pct, this.color});

  static const double _height = 7;

  @override
  Widget build(BuildContext context) {
    // FractionallySizedBox rather than LayoutBuilder: bars sit inside
    // IntrinsicHeight rows, which can't measure a LayoutBuilder.
    return Container(
      height: _height,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: _barTrackColor,
        borderRadius: BorderRadius.circular(_height / 2),
      ),
      child: FractionallySizedBox(
        widthFactor: pct.clamp(0, 100) / 100,
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? _levelColor(_pctLevel(pct)),
            borderRadius: BorderRadius.circular(_height / 2),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;

  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const _Pill({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final fg = color ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 11.5, color: fg)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Health levels
// ---------------------------------------------------------------------------

enum _Level { good, warn, bad }

_Level _pctLevel(double pct) => pct >= 90
    ? _Level.bad
    : pct >= 80
    ? _Level.warn
    : _Level.good;

Color _levelColor(_Level l) => switch (l) {
  _Level.good => AppColors.success,
  _Level.warn => AppColors.warning,
  _Level.bad => AppColors.danger,
};

String _pctWord(_Level l) => switch (l) {
  _Level.good => 'Normal',
  _Level.warn => 'High',
  _Level.bad => 'Critical',
};

int? _coresOf(MetricSample? s) {
  final c = int.tryParse(s?.sysInfo?.cores ?? '');
  return (c == null || c <= 0) ? null : c;
}

/// 1-minute load relative to the core count: 1.0 means every core is busy.
double? _loadRatio(MetricSample? s) {
  final load = s?.load1;
  if (load == null) return null;
  return load / (_coresOf(s) ?? 1);
}

(_Level, String) _workloadWord(double ratio) {
  if (ratio < 0.5) return (_Level.good, 'Light');
  if (ratio < 1) return (_Level.good, 'Moderate');
  if (ratio < 1.5) return (_Level.warn, 'Heavy');
  return (_Level.bad, 'Overloaded');
}

(_Level, String) _tempWord(double celsius) {
  if (celsius < 60) return (_Level.good, 'Cool');
  if (celsius < 75) return (_Level.good, 'Warm');
  if (celsius < 85) return (_Level.warn, 'Hot');
  return (_Level.bad, 'Too hot');
}

/// The disk mounted at `/`, or the largest one when there's no root mount.
DiskInfo? _mainDisk(MetricSample? s) {
  final disks = s?.disks ?? const <DiskInfo>[];
  if (disks.isEmpty) return null;
  return disks.where((d) => d.mount == '/').firstOrNull ?? disks.first;
}

String _diskName(DiskInfo d) {
  if (d.mount == '/') return 'System disk';
  if (d.mount == '/boot' || d.mount == '/boot/efi') return 'Boot partition';
  if (d.mount == '/home') return 'User files';
  if (d.device.contains(':')) return 'Network share';
  return d.mount;
}

/// Problems worth a plain-language warning, most severe first.
List<(_Level, String)> _healthIssues(MetricSample s) {
  final issues = <(_Level, String)>[];

  final cpu = s.cpuPct;
  if (cpu != null && _pctLevel(cpu) != _Level.good) {
    issues.add((
      _pctLevel(cpu),
      'The processor is very busy (${cpu.toStringAsFixed(0)}% in use).',
    ));
  }

  if ((s.memTotalMb ?? 0) > 0 && _pctLevel(s.memPct) != _Level.good) {
    issues.add((
      _pctLevel(s.memPct),
      'Memory is ${s.memPct >= 90 ? 'almost full' : 'running low'} '
          '(${s.memPct.toStringAsFixed(0)}% used).',
    ));
  }

  for (final d in s.disks) {
    if (_pctLevel(d.pct) == _Level.good) continue;
    issues.add((
      _pctLevel(d.pct),
      '${_diskName(d) == d.mount ? 'Disk ${d.mount}' : '${_diskName(d)} (${d.mount})'} is '
          '${d.pct >= 90 ? 'almost full' : 'filling up'} — '
          'only ${memF(math.max(0, d.totalMb - d.usedMb))} free.',
    ));
  }

  final ratio = _loadRatio(s);
  if (ratio != null && ratio >= 1) {
    issues.add(
      ratio >= 1.5
          ? (_Level.bad, 'The server has more work than it can keep up with.')
          : (_Level.warn, 'The server is working at full capacity.'),
    );
  }

  final hot = s.hottestTemp;
  if (hot != null) {
    final (level, _) = _tempWord(hot.celsius);
    if (level != _Level.good) {
      issues.add((
        level,
        'It is running hot (${hot.celsius.toStringAsFixed(0)}°C).',
      ));
    }
  }

  issues.sort((a, b) => b.$1.index.compareTo(a.$1.index));
  return issues;
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _HeaderCard extends ConsumerWidget {
  final Host host;
  final HostMetricsState state;

  const _HeaderCard({required this.host, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(metricsControllerProvider);
    final s = state.last;
    final os = s?.sysInfo?.prettyName ?? '';
    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.accentMuted,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.dns_outlined,
                  size: 22,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      host.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      '${host.username}@${host.address}'
                      '${host.port == 22 ? '' : ':${host.port}'}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => connectSavedHost(context, ref, host),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: Icon(
                  Icons.terminal,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                label: Text(
                  'Terminal',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _IconAction(
                icon: Icons.refresh,
                tooltip: 'Refresh now',
                busy: state.pollState == HostPollState.connecting,
                onPressed: () => controller.poll(host.id),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusPill(),
              if (s?.uptimeSec != null)
                _Pill(
                  icon: Icons.schedule,
                  text: 'Running for ${formatUptime(s!.uptimeSec!)}',
                ),
              if (os.isNotEmpty) _Pill(icon: Icons.computer_outlined, text: os),
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.dangerMuted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 15, color: AppColors.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.error!,
                      style: TextStyle(fontSize: 12, color: AppColors.danger),
                      softWrap: true,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (controller.needsCredentials(host.id)) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Sign-in needed',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Metrics are paused for this server. Enter its '
                          'username and password; they are kept only until '
                          'the app closes.',
                          style: _cellStyle,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () async {
                      final result = await promptCredentials(
                        context,
                        ref,
                        host,
                      );
                      if (result != null) {
                        controller.provideCredentials(
                          host.id,
                          result.username,
                          result.password,
                        );
                      }
                    },
                    icon: const Icon(Icons.key, size: 15),
                    label: const Text('Enter password'),
                  ),
                ],
              ),
            ),
          ],
          if (s != null) ...[const SizedBox(height: 12), _HealthSummary(s: s)],
        ],
      ),
    );
  }

  Widget _statusPill() {
    final updated = state.lastUpdated;
    return switch (state.pollState) {
      HostPollState.ok => _Pill(
        icon: Icons.circle,
        color: AppColors.success,
        text: updated == null ? 'Online' : 'Online · updated ${_ago(updated)}',
      ),
      HostPollState.connecting => _Pill(
        icon: Icons.circle,
        color: AppColors.warning,
        text: 'Connecting…',
      ),
      HostPollState.error => _Pill(
        icon: Icons.circle,
        color: AppColors.danger,
        text: 'Offline',
      ),
      HostPollState.idle => _Pill(icon: Icons.circle, text: 'Waiting'),
    };
  }
}

/// One-line verdict on the server's health, with the reasons when it isn't
/// all good.
class _HealthSummary extends StatelessWidget {
  final MetricSample s;

  const _HealthSummary({required this.s});

  @override
  Widget build(BuildContext context) {
    final issues = _healthIssues(s);
    final level = issues.isEmpty ? _Level.good : issues.first.$1;
    final color = _levelColor(level);
    final title = switch (level) {
      _Level.good => 'Everything looks healthy',
      _Level.warn => 'Worth keeping an eye on',
      _Level.bad => 'Needs attention',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            level == _Level.good
                ? Icons.check_circle_outline
                : Icons.warning_amber_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                if (issues.isEmpty)
                  Text(
                    'Processor, memory, disks and temperature are all within '
                    'normal ranges.',
                    style: _cellStyle,
                  )
                else
                  for (final (l, text) in issues)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _levelColor(l),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(text, style: _cellStyle)),
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
}

// ---------------------------------------------------------------------------
// At a glance tiles
// ---------------------------------------------------------------------------

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String help;
  final String value;
  final String unit;
  final String caption;
  final _Level? level;

  /// Bar fill; null hides the bar.
  final double? pct;

  const _StatTile({
    required this.icon,
    required this.title,
    required this.help,
    required this.value,
    required this.unit,
    required this.caption,
    this.level,
    this.pct,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _HelpIcon(message: help),
                  ],
                ),
              ),
              if (level != null)
                _Badge(text: _pctWord(level!), color: _levelColor(level!)),
            ],
          ),
          const SizedBox(height: 12),
          _BigValue(value: value, unit: unit),
          const SizedBox(height: 4),
          Text(
            caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _labelStyle,
          ),
          if (pct != null) ...[
            const Spacer(),
            const SizedBox(height: 10),
            _ProgressBar(pct: pct!),
          ],
        ],
      ),
    );
  }
}

class _CpuTile extends StatelessWidget {
  final MetricSample? s;

  const _CpuTile({required this.s});

  @override
  Widget build(BuildContext context) {
    final cpu = s?.cpuPct;
    final cores = _coresOf(s);
    return _StatTile(
      icon: Icons.memory_outlined,
      title: 'Processor',
      help:
          'How much of the processor (CPU) is in use right now. '
          'Short spikes are normal; staying above 80% slows things down.',
      value: cpu == null ? '--' : cpu.toStringAsFixed(cpu < 10 ? 1 : 0),
      unit: '% in use',
      caption: cpu == null
          ? 'Measuring…'
          : cores == null
          ? 'Across all cores'
          : 'Across $cores ${cores == 1 ? 'core' : 'cores'}',
      level: cpu == null ? null : _pctLevel(cpu),
      pct: cpu ?? 0,
    );
  }
}

class _MemoryTile extends StatelessWidget {
  final MetricSample? s;

  const _MemoryTile({required this.s});

  @override
  Widget build(BuildContext context) {
    final used = s?.memUsedMb;
    final total = s?.memTotalMb;
    final pct = (s == null || (total ?? 0) <= 0) ? null : s!.memPct;
    return _StatTile(
      icon: Icons.developer_board_outlined,
      title: 'Memory',
      help:
          'Working memory (RAM) used by running programs. When it fills '
          'up, the server slows down or starts closing programs.',
      value: pct == null ? '--' : pct.toStringAsFixed(0),
      unit: '% used',
      caption: used == null || total == null
          ? 'Waiting for data…'
          : '${memF(used)} of ${memF(total)}',
      level: pct == null ? null : _pctLevel(pct),
      pct: pct ?? 0,
    );
  }
}

class _StorageTile extends StatelessWidget {
  final MetricSample? s;

  const _StorageTile({required this.s});

  @override
  Widget build(BuildContext context) {
    final d = _mainDisk(s);
    return _StatTile(
      icon: Icons.save_outlined,
      title: 'Storage',
      help:
          'Space used on the main disk. Every disk is listed under '
          'Storage below.',
      value: d == null ? '--' : d.pct.toStringAsFixed(0),
      unit: '% used',
      caption: d == null
          ? 'Waiting for data…'
          : '${memF(math.max(0, d.totalMb - d.usedMb))} free of '
                '${memF(d.totalMb)}',
      level: d == null ? null : _pctLevel(d.pct),
      pct: d?.pct ?? 0,
    );
  }
}

class _NetworkTile extends StatelessWidget {
  final MetricSample? s;

  const _NetworkTile({required this.s});

  @override
  Widget build(BuildContext context) {
    return _StatTile(
      icon: Icons.swap_vert,
      title: 'Network',
      help:
          'Data the server is downloading and uploading per second, '
          'across all network cards.',
      value: s == null ? '--' : '↓ ${bytesF(s!.netRxRate)}/s',
      unit: '',
      caption: s == null
          ? 'Waiting for data…'
          : '↑ ${bytesF(s!.netTxRate)}/s upload',
    );
  }
}

// ---------------------------------------------------------------------------
// About this server
// ---------------------------------------------------------------------------

class _AboutCard extends StatelessWidget {
  final MetricSample? s;

  const _AboutCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final sys = s?.sysInfo;
    if (s == null || sys == null) {
      return Container(
        decoration: _cardDecoration(),
        padding: const EdgeInsets.all(16),
        child: Text('Waiting for the first reading…', style: _labelStyle),
      );
    }
    final cores = _coresOf(s);
    final disks = s!.disks;
    final storageTotal = disks.fold<double>(0, (sum, d) => sum + d.totalMb);
    final items = <(IconData, String, String)>[
      (Icons.computer_outlined, 'Operating system', sys.prettyName),
      (Icons.memory_outlined, 'Processor', _cleanCpuModel(sys.cpuModel)),
      (
        Icons.grid_view,
        'Processor cores',
        cores == null ? '' : '$cores ${cores == 1 ? 'core' : 'cores'}',
      ),
      (
        Icons.developer_board_outlined,
        'Memory (RAM)',
        s!.memTotalMb == null ? '' : memF(s!.memTotalMb!),
      ),
      (
        Icons.save_outlined,
        'Total storage',
        disks.isEmpty
            ? ''
            : '${memF(storageTotal)}'
                  '${disks.length > 1 ? ' on ${disks.length} disks' : ''}',
      ),
      (
        Icons.schedule,
        'Running for',
        s!.uptimeSec == null
            ? ''
            : '${formatUptime(s!.uptimeSec!)} '
                  '(since ${_sinceDate(s!.uptimeSec!)})',
      ),
      (Icons.badge_outlined, 'Server name', sys.hostname),
      (Icons.architecture, 'Architecture', _archName(sys.arch)),
      (Icons.settings_suggest_outlined, 'Linux kernel', sys.kernel),
    ];

    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 16.0;
          final columns = constraints.maxWidth >= 720
              ? 3
              : constraints.maxWidth >= 440
              ? 2
              : 1;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: 14,
            children: [
              for (final (icon, label, value) in items)
                SizedBox(
                  width: width,
                  child: _InfoItem(icon: icon, label: label, value: value),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 15, color: AppColors.textSecondary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: _labelStyle),
              const SizedBox(height: 2),
              SelectableText(
                value.isEmpty ? 'Unknown' : value,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: value.isEmpty
                      ? AppColors.textFaint
                      : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Workload & temperature
// ---------------------------------------------------------------------------

class _WorkloadCard extends StatelessWidget {
  final MetricSample? s;

  const _WorkloadCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final ratio = _loadRatio(s);
    final cores = _coresOf(s);
    final word = ratio == null ? null : _workloadWord(ratio);
    return _MetricCard(
      icon: Icons.speed,
      title: 'Workload',
      help:
          'How many tasks want the processor compared to how many it can '
          'run at once (Linux "load average"). Above 100% means tasks are '
          'queuing up and the server feels slow.',
      trailing: word == null
          ? null
          : _Badge(text: word.$2, color: _levelColor(word.$1)),
      children: [
        if (ratio == null)
          Text('Waiting for data…', style: _labelStyle)
        else ...[
          _BigValue(value: '${(ratio * 100).round()}%', unit: 'of capacity'),
          const SizedBox(height: 4),
          Text(
            ratio <= 1
                ? 'The server could take on more work.'
                : 'More work than ${cores == null ? 'it' : 'its $cores cores'} '
                      'can handle — some tasks are waiting.',
            style: _labelStyle,
          ),
          const SizedBox(height: 10),
          _ProgressBar(pct: ratio * 100, color: _levelColor(word!.$1)),
          const SizedBox(height: 14),
          Row(
            children: [
              _trendCol('Last minute', s!.load1),
              _trendCol('Last 5 minutes', s!.load5),
              _trendCol('Last 15 minutes', s!.load15),
            ],
          ),
          const Spacer(),
          const SizedBox(height: 10),
          Text(
            'Load average: ${[s!.load1, s!.load5, s!.load15].map((v) => v?.toStringAsFixed(2) ?? '--').join(' · ')}'
            '${cores == null ? '' : ' on $cores ${cores == 1 ? 'core' : 'cores'}'}',
            style: TextStyle(fontSize: 10.5, color: AppColors.textFaint),
          ),
        ],
      ],
    );
  }

  Widget _trendCol(String label, double? load) {
    final pct = load == null ? null : load / (_coresOf(s) ?? 1) * 100;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _labelStyle),
          const SizedBox(height: 2),
          Text(
            pct == null ? '--' : '${pct.round()}%',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _TempsCard extends StatelessWidget {
  final MetricSample? s;

  const _TempsCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final temps = [...?s?.temps]
      ..sort((a, b) => b.celsius.compareTo(a.celsius));
    final hottest = temps.firstOrNull;
    final word = hottest == null ? null : _tempWord(hottest.celsius);
    return _MetricCard(
      icon: Icons.thermostat,
      title: 'Temperature',
      help:
          'Readings from the hardware sensors. Most servers are fine below '
          '75°C.',
      trailing: word == null
          ? null
          : _Badge(text: word.$2, color: _levelColor(word.$1)),
      children: [
        if (s == null)
          Text('Waiting for data…', style: _labelStyle)
        else if (hottest == null)
          Text(
            'This server doesn\'t report any temperature sensors. '
            'That\'s normal for virtual and cloud servers.',
            style: _cellStyle,
          )
        else ...[
          _BigValue(
            value: '${hottest.celsius.toStringAsFixed(0)}°C',
            unit: 'hottest · ${_sensorName(hottest)}',
          ),
          const SizedBox(height: 12),
          for (final t in temps.skip(1).take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _sensorName(t),
                      overflow: TextOverflow.ellipsis,
                      style: _cellStyle,
                    ),
                  ),
                  Text(
                    '${t.celsius.toStringAsFixed(0)}°C',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _tempWord(t.celsius).$1 == _Level.good
                          ? AppColors.textSecondary
                          : _levelColor(_tempWord(t.celsius).$1),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

class _DisksCard extends StatelessWidget {
  final MetricSample? s;

  const _DisksCard({required this.s});

  @override
  Widget build(BuildContext context) {
    // System disk first, then largest first.
    final disks = [...?s?.disks]
      ..sort((a, b) {
        if ((a.mount == '/') != (b.mount == '/')) {
          return a.mount == '/' ? -1 : 1;
        }
        return b.totalMb.compareTo(a.totalMb);
      });
    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(16),
      child: disks.isEmpty
          ? Text(
              s == null ? 'Waiting for data…' : 'No disks found',
              style: _labelStyle,
            )
          : Column(
              children: [
                for (var i = 0; i < disks.length && i < 8; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Divider(height: 1, color: AppColors.border),
                    ),
                  _DiskRow(disk: disks[i]),
                ],
              ],
            ),
    );
  }
}

class _DiskRow extends StatelessWidget {
  final DiskInfo disk;

  const _DiskRow({required this.disk});

  @override
  Widget build(BuildContext context) {
    final free = math.max(0.0, disk.totalMb - disk.usedMb);
    final level = _pctLevel(disk.pct);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              disk.device.contains(':')
                  ? Icons.cloud_outlined
                  : Icons.save_outlined,
              size: 16,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            // Name + path share one Expanded so "% used" sits at the right
            // edge instead of floating mid-row.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      _diskName(disk),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 2,
                    child: Text(
                      disk.mount == _diskName(disk)
                          ? disk.device
                          : '${disk.mount} · ${disk.device}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _labelStyle,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (level != _Level.good) ...[
              _Badge(
                text: level == _Level.bad ? 'Almost full' : 'Filling up',
                color: _levelColor(level),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              '${disk.pct.toStringAsFixed(0)}% used',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ProgressBar(pct: disk.pct),
        const SizedBox(height: 6),
        Text(
          '${memF(disk.usedMb)} used · ${memF(free)} free · '
          '${memF(disk.totalMb)} total',
          style: _labelStyle,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// What's running
// ---------------------------------------------------------------------------

class _ProcsCard extends StatelessWidget {
  final MetricSample? s;

  const _ProcsCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final procs = s?.procs ?? const <ProcRow>[];
    final hasMem = procs.any((p) => p.mem != null);
    final hasElapsed = procs.any((p) => p.elapsed.isNotEmpty);
    final headStyle = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      color: AppColors.textFaint,
    );
    return _MetricCard(
      icon: Icons.apps,
      title: 'Busiest programs',
      help: 'The programs using the most processor time right now.',
      trailing: s?.procCount == null
          ? null
          : Text('${s!.procCount} running in total', style: _labelStyle),
      children: [
        if (procs.isEmpty)
          Text('Waiting for data…', style: _labelStyle)
        else ...[
          Row(
            children: [
              Expanded(child: Text('Program', style: headStyle)),
              SizedBox(
                width: 64,
                child: Text(
                  'Processor',
                  textAlign: TextAlign.right,
                  style: headStyle,
                ),
              ),
              if (hasMem)
                SizedBox(
                  width: 60,
                  child: Text(
                    'Memory',
                    textAlign: TextAlign.right,
                    style: headStyle,
                  ),
                ),
              if (hasElapsed)
                SizedBox(
                  width: 78,
                  child: Text(
                    'Running for',
                    textAlign: TextAlign.right,
                    style: headStyle,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (final p in procs.take(10))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      p.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(
                      p.cpu == null ? '--' : '${p.cpu!.toStringAsFixed(1)}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        color: (p.cpu ?? 0) > 50
                            ? AppColors.warning
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                  if (hasMem)
                    SizedBox(
                      width: 60,
                      child: Text(
                        p.mem == null ? '--' : '${p.mem!.toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: _cellStyle,
                      ),
                    ),
                  if (hasElapsed)
                    SizedBox(
                      width: 78,
                      child: Text(
                        _friendlyElapsed(p.elapsed),
                        textAlign: TextAlign.right,
                        style: _labelStyle,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _PortsCard extends StatelessWidget {
  final MetricSample? s;

  const _PortsCard({required this.s});

  static const _preview = 10;

  @override
  Widget build(BuildContext context) {
    final ports = [...?s?.ports]..sort((a, b) => a.port.compareTo(b.port));
    return _MetricCard(
      icon: Icons.cable,
      title: 'Open ports',
      help:
          'Ports are doors that let other computers reach a program on '
          'this server. "Reachable" ports accept outside connections; '
          '"This server only" ports can only be used locally.',
      trailing: ports.isEmpty
          ? null
          : Text('${ports.length} open', style: _labelStyle),
      children: [
        if (s == null)
          Text('Waiting for data…', style: _labelStyle)
        else if (ports.isEmpty)
          Text(
            'No open ports reported (listing them may need admin rights).',
            style: _cellStyle,
          )
        else ...[
          for (final p in ports.take(_preview)) _PortRowView(port: p),
          if (ports.length > _preview) ...[
            const Spacer(),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => _PortsDialog(ports: ports),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                ),
                icon: Icon(Icons.list, size: 15, color: AppColors.accent),
                label: Text(
                  'Show all ${ports.length} ports',
                  style: TextStyle(fontSize: 12, color: AppColors.accent),
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _PortRowView extends StatelessWidget {
  final PortRow port;

  const _PortRowView({required this.port});

  @override
  Widget build(BuildContext context) {
    final p = port;
    final service = _portService(p);
    final details = [
      p.proto.toUpperCase(),
      if (p.process.isNotEmpty && service != p.process) p.process,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              '${p.port}',
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: service,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  TextSpan(text: '  $details', style: _labelStyle),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _portIsPublic(p)
              ? _Badge(text: 'Reachable', color: AppColors.info)
              : _Badge(text: 'This server only', color: AppColors.textFaint),
        ],
      ),
    );
  }
}

/// Every open port, searchable by number, service or program.
class _PortsDialog extends StatefulWidget {
  final List<PortRow> ports;

  const _PortsDialog({required this.ports});

  @override
  State<_PortsDialog> createState() => _PortsDialogState();
}

class _PortsDialogState extends State<_PortsDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = widget.ports
        .where(
          (p) =>
              q.isEmpty ||
              '${p.port} ${_portService(p)} ${p.process} ${p.proto}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList();
    final reachable = widget.ports.where(_portIsPublic).length;
    return AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(
        'Open ports',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 580,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.ports.length} open · $reachable reachable from '
              'other computers',
              style: _labelStyle,
            ),
            const SizedBox(height: 10),
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: Icon(
                  Icons.search,
                  size: 16,
                  color: AppColors.textFaint,
                ),
                hintText: 'Search by port, service or program',
                hintStyle: _labelStyle,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                filled: true,
                fillColor: AppColors.surfaceAlt,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppColors.border),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: shown.isEmpty
                  ? Center(child: Text('No matching ports', style: _labelStyle))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) => _PortRowView(port: shown[i]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sign-ins
// ---------------------------------------------------------------------------

class _LoginsCard extends StatelessWidget {
  final MetricSample? s;

  const _LoginsCard({required this.s});

  @override
  Widget build(BuildContext context) {
    final logins = s?.logins ?? const <LoginRow>[];
    final active = logins.where((l) => l.active).toList();
    final recent = logins.where((l) => !l.active).take(10).toList();
    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(16),
      child: s == null
          ? Text('Waiting for data…', style: _labelStyle)
          : LayoutBuilder(
              builder: (context, constraints) {
                // Wide cards use aligned columns so the row fills the card;
                // narrow ones fall back to two-line rows.
                final wide = constraints.maxWidth >= 640;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _groupTitle('Signed in now', active.length),
                    if (active.isEmpty)
                      Text('Nobody is signed in right now.', style: _cellStyle)
                    else ...[
                      if (wide) const _LoginHeaderRow(),
                      for (final l in active)
                        _LoginRowView(login: l, wide: wide),
                    ],
                    const SizedBox(height: 18),
                    _groupTitle('Recent sign-ins', recent.length),
                    if (recent.isEmpty)
                      Text('No recent sign-ins recorded.', style: _cellStyle)
                    else ...[
                      if (wide) const _LoginHeaderRow(),
                      for (final l in recent)
                        _LoginRowView(login: l, wide: wide),
                    ],
                  ],
                );
              },
            ),
    );
  }

  Widget _groupTitle(String title, int count) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(width: 6),
        Text('$count', style: _labelStyle),
      ],
    ),
  );
}

// Shared column widths for the wide sign-in table.
const double _loginAvatarCol = 36;
const double _loginUserCol = 150;
const double _loginStatusCol = 160;

class _LoginHeaderRow extends StatelessWidget {
  const _LoginHeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      color: AppColors.textFaint,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          const SizedBox(width: _loginAvatarCol),
          SizedBox(
            width: _loginUserCol,
            child: Text('User', style: style),
          ),
          Expanded(child: Text('Connected from', style: style)),
          Expanded(child: Text('Signed in at', style: style)),
          SizedBox(
            width: _loginStatusCol,
            child: Text('Session', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}

class _LoginRowView extends StatelessWidget {
  final LoginRow login;
  final bool wide;

  const _LoginRowView({required this.login, required this.wide});

  @override
  Widget build(BuildContext context) {
    final info = _describeLogin(login);
    final avatar = Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: login.active
            ? AppColors.success.withValues(alpha: 0.15)
            : AppColors.surfaceAlt,
      ),
      child: Icon(
        Icons.person_outline,
        size: 14,
        color: login.active ? AppColors.success : AppColors.textFaint,
      ),
    );
    final userStyle = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
    );
    final status = login.active
        ? _Badge(text: 'Active now', color: AppColors.success)
        : Text(
            info.status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: _cellStyle,
          );

    if (wide) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: _loginAvatarCol,
              child: Align(alignment: Alignment.centerLeft, child: avatar),
            ),
            SizedBox(
              width: _loginUserCol,
              child: Text(
                login.user,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: userStyle,
              ),
            ),
            Expanded(
              child: Text(
                info.from,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _cellStyle,
              ),
            ),
            Expanded(
              child: Text(
                info.at.isEmpty ? '—' : info.at,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _cellStyle,
              ),
            ),
            SizedBox(
              width: _loginStatusCol,
              child: Align(alignment: Alignment.centerRight, child: status),
            ),
          ],
        ),
      );
    }

    final second = [
      if (info.at.isNotEmpty) info.at,
      if (!login.active && info.status.isNotEmpty) info.status,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: login.user, style: userStyle),
                      if (info.from.isNotEmpty)
                        TextSpan(text: '  ${info.from}', style: _cellStyle),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (second.isNotEmpty)
                  Text(
                    second,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _labelStyle,
                  ),
              ],
            ),
          ),
          if (login.active) ...[const SizedBox(width: 8), status],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// History charts
// ---------------------------------------------------------------------------

class _HistorySection extends ConsumerStatefulWidget {
  final String hostId;

  const _HistorySection({required this.hostId});

  @override
  ConsumerState<_HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends ConsumerState<_HistorySection> {
  int _rangeHours = 24;
  List<HostMetric>? _rows;
  String? _error;
  Timer? _timer;

  static const _ranges = [
    (1, 'Last hour'),
    (24, 'Last day'),
    (168, 'Last week'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
    // Samples are saved every few seconds; refresh the charts on a relaxed
    // cadence so they stay current without a reload button.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void didUpdateWidget(_HistorySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostId != widget.hostId) {
      _rows = null;
      _load();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final hostId = widget.hostId;
    try {
      final controller = ref.read(metricsControllerProvider);
      final rows = await controller.history(hostId, limit: 6000);
      if (!mounted || hostId != widget.hostId) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final since = DateTime.now().subtract(Duration(hours: _rangeHours));
    final rows = (_rows ?? const <HostMetric>[])
        .where((r) => r.ts.isAfter(since))
        .toList();

    String pctF(double v) => '${v.toStringAsFixed(0)}%';
    String rateF(double v) => '${bytesF(v)}/s';

    final charts = <Widget>[
      _HistoryChart(
        title: 'Processor usage',
        series: [
          for (final r in rows)
            if (r.cpuPct != null) (r.ts, r.cpuPct!),
        ],
        color: AppColors.success,
        format: pctF,
      ),
      _HistoryChart(
        title: 'Memory usage',
        series: [for (final r in rows) (r.ts, r.memPct)],
        color: AppColors.accent,
        format: pctF,
      ),
      _HistoryChart(
        title: 'System disk usage',
        series: [
          for (final r in rows)
            if (r.diskPct != null) (r.ts, r.diskPct!),
        ],
        color: AppColors.warning,
        format: pctF,
      ),
      _HistoryChart(
        title: 'Workload (load average)',
        series: [
          for (final r in rows)
            if (r.load1 != null) (r.ts, r.load1!),
        ],
        color: AppColors.warning,
        format: (v) => v.toStringAsFixed(2),
      ),
      _HistoryChart(
        title: 'Download speed',
        series: [
          for (final r in rows)
            if (r.netRx != null) (r.ts, r.netRx!),
        ],
        color: AppColors.info,
        format: rateF,
      ),
      _HistoryChart(
        title: 'Upload speed',
        series: [
          for (final r in rows)
            if (r.netTx != null) (r.ts, r.netTx!),
        ],
        color: AppColors.accent,
        format: rateF,
      ),
      if (rows.where((r) => r.temp != null).length >= 2)
        _HistoryChart(
          title: 'Temperature',
          series: [
            for (final r in rows)
              if (r.temp != null) (r.ts, r.temp!),
          ],
          color: AppColors.danger,
          format: (v) => '${v.toStringAsFixed(0)}°C',
        ),
    ];

    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  runSpacing: 6,
                  children: [
                    for (final (h, label) in _ranges)
                      _RangeChip(
                        label: label,
                        selected: h == _rangeHours,
                        onTap: () => setState(() => _rangeHours = h),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('Updates automatically', style: _labelStyle),
            ],
          ),
          const SizedBox(height: 14),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(fontSize: 12, color: AppColors.danger),
            )
          else if (_rows == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  'No readings in this time range yet.\n'
                  'Tracked servers record data automatically.',
                  textAlign: TextAlign.center,
                  style: _labelStyle,
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 16.0;
                final columns = constraints.maxWidth >= 760 ? 2 : 1;
                final width =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: 18,
                  children: [
                    for (final chart in charts)
                      SizedBox(width: width, child: chart),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _HistoryChart extends StatelessWidget {
  final String title;
  final List<(DateTime, double)> series;
  final Color color;
  final String Function(double) format;

  const _HistoryChart({
    required this.title,
    required this.series,
    required this.color,
    required this.format,
  });

  @override
  Widget build(BuildContext context) {
    var sum = 0.0;
    var peak = double.negativeInfinity;
    for (final (_, v) in series) {
      sum += v;
      peak = math.max(peak, v);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            if (series.isNotEmpty)
              Text(
                'average ${format(sum / series.length)} · peak ${format(peak)}',
                style: _labelStyle,
              ),
          ],
        ),
        const SizedBox(height: 6),
        _MetricChart(series: series, color: color),
      ],
    );
  }
}

class _RangeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected ? AppColors.accentMuted : Colors.transparent,
            border: Border.all(
              color: selected ? AppColors.accentBorder : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.accent : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Painter for the history graphs. No charting dependency: a simple line
/// chart with an area fill and a few horizontal guides.
class _MetricChart extends StatelessWidget {
  /// Chronological series (x = real timestamps).
  final List<(DateTime, double)> series;
  final Color color;

  const _MetricChart({required this.series, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 100,
      child: CustomPaint(
        painter: _LinePainter(series: series, accent: color),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final List<(DateTime, double)> series;
  final Color accent;

  _LinePainter({required this.series, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2) {
      final paint = TextPainter()
        ..text = TextSpan(
          text: 'Not enough readings yet',
          style: TextStyle(fontSize: 11, color: AppColors.textFaint),
        )
        ..textDirection = TextDirection.ltr;
      paint.layout();
      paint.paint(
        canvas,
        Offset(
          (size.width - paint.width) / 2,
          (size.height - paint.height) / 2,
        ),
      );
      return;
    }

    const padL = 4.0;
    const padR = 4.0;
    const padT = 6.0;
    const padB = 6.0;
    final w = size.width - padL - padR;
    final h = size.height - padT - padB;

    // Downsample to ~240 points by averaging buckets.
    final target = 240;
    List<(DateTime, double)> pts = series;
    if (series.length > target) {
      final bucket = series.length / target;
      pts = [
        for (var i = 0; i < target; i++)
          () {
            final start = (i * bucket).floor();
            final end = math.min(((i + 1) * bucket).ceil(), series.length);
            var sum = 0.0;
            var n = 0;
            for (var j = start; j < end; j++) {
              sum += series[j].$2;
              n++;
            }
            return (
              series[start == end ? end : start].$1,
              sum / math.max(1, n),
            );
          }(),
      ];
    }

    final minX = pts.first.$1.millisecondsSinceEpoch.toDouble();
    final maxX = pts.last.$1.millisecondsSinceEpoch.toDouble();
    double xPos(DateTime t) {
      final span = math.max(1.0, maxX - minX);
      return padL + w * ((t.millisecondsSinceEpoch - minX) / span);
    }

    double maxYv = 1.0;
    for (final (_, v) in pts) {
      if (v > maxYv) maxYv = v;
    }
    maxYv *= 1.15;
    double yPos(double v) => padT + h * (1 - (v.clamp(0, maxYv) / maxYv));

    final guidePaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    for (final frac in [0.25, 0.5, 0.75, 1.0]) {
      final y = padT + h * frac;
      canvas.drawLine(Offset(padL, y), Offset(padL + w, y), guidePaint);
    }

    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final p = Offset(xPos(pts[i].$1), yPos(pts[i].$2));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }

    final fill = Path.from(path)
      ..lineTo(padL + w, padT + h)
      ..lineTo(padL, padT + h)
      ..close();
    canvas.drawPath(fill, Paint()..color = accent.withValues(alpha: 0.14));

    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_LinePainter oldDelegate) =>
      oldDelegate.series != series || oldDelegate.accent != accent;
}

// ---------------------------------------------------------------------------
// Plain-language helpers
// ---------------------------------------------------------------------------

/// "Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz" → "Intel Xeon E5-2680 v4 @ 2.40GHz".
String _cleanCpuModel(String model) => model
    .replaceAll(RegExp(r'\((R|TM)\)', caseSensitive: false), '')
    .replaceAll(RegExp(r'\s+CPU\b'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _archName(String arch) => switch (arch) {
  '' => '',
  'x86_64' || 'amd64' => '64-bit Intel/AMD ($arch)',
  'aarch64' || 'arm64' => '64-bit ARM ($arch)',
  'i386' || 'i686' => '32-bit Intel/AMD ($arch)',
  _ when arch.startsWith('arm') => '32-bit ARM ($arch)',
  _ => arch,
};

String _sensorName(TempReading t) {
  final raw = t.label.isEmpty ? t.zone : t.label;
  final l = raw.toLowerCase();
  final core = RegExp(r'^core (\d+)$').firstMatch(l);
  if (core != null) return 'Processor core ${core.group(1)}';
  // Intel "Package id N" is a whole CPU socket; number them from 1.
  final pkg = RegExp(r'^package id (\d+)$').firstMatch(l);
  if (pkg != null) return 'Processor ${int.parse(pkg.group(1)!) + 1}';
  if (l.contains('pkg') ||
      l.contains('package') ||
      l.contains('coretemp') ||
      l.contains('k10temp') ||
      l.contains('cpu') ||
      l == 'tctl' ||
      l == 'tdie') {
    return 'Processor';
  }
  if (l == 'acpitz') return 'Motherboard';
  if (l.contains('nvme') || l == 'composite') return 'SSD';
  if (l.contains('pch')) return 'Chipset';
  if (l.contains('wifi')) return 'Wi-Fi card';
  if (l.contains('gpu')) return 'Graphics';
  if (l.contains('soc')) return 'Main chip';
  return raw;
}

const _knownPorts = <int, String>{
  20: 'File transfer (FTP)',
  21: 'File transfer (FTP)',
  22: 'Remote login (SSH)',
  25: 'Email sending (SMTP)',
  53: 'Domain names (DNS)',
  67: 'IP addresses (DHCP)',
  68: 'IP addresses (DHCP)',
  80: 'Website (HTTP)',
  110: 'Email (POP3)',
  111: 'RPC',
  123: 'Time sync (NTP)',
  143: 'Email (IMAP)',
  443: 'Secure website (HTTPS)',
  465: 'Email sending (SMTPS)',
  587: 'Email sending (SMTP)',
  631: 'Printing (CUPS)',
  993: 'Email (IMAPS)',
  995: 'Email (POP3S)',
  1194: 'VPN (OpenVPN)',
  2375: 'Docker',
  2376: 'Docker',
  3306: 'MySQL database',
  3389: 'Remote desktop (RDP)',
  5353: 'Local discovery (mDNS)',
  5432: 'PostgreSQL database',
  5900: 'Remote desktop (VNC)',
  6379: 'Redis',
  8080: 'Web (alternate)',
  8443: 'Secure web (alternate)',
  9090: 'Prometheus',
  9100: 'Node exporter',
  9200: 'Elasticsearch',
  11211: 'Memcached',
  25565: 'Minecraft server',
  27017: 'MongoDB database',
  51820: 'VPN (WireGuard)',
};

String _portService(PortRow p) =>
    _knownPorts[p.port] ??
    (p.process.isNotEmpty ? p.process : 'Unknown program');

/// Whether a listening socket accepts connections from other machines,
/// judged from its bind address.
bool _portIsPublic(PortRow p) {
  final i = p.bind.lastIndexOf(':');
  if (i <= 0) return true;
  final host = p.bind
      .substring(0, i)
      .replaceAll(RegExp(r'[\[\]]'), '')
      .split('%')
      .first;
  return !(host.startsWith('127.') || host == '::1' || host == 'localhost');
}

final _weekdayStart = RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b');
final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
// Needs "::" or 3+ colons so clock times like 11:07:22 don't match.
final _ipv6 = RegExp(
  r'^[0-9a-fA-F:]*::[0-9a-fA-F:.]*$|^([0-9a-fA-F]{1,4}:){3,}[0-9a-fA-F.:]*$',
);
final _dnsName = RegExp(r'^[A-Za-z][\w-]*(\.[\w-]+)+$');

bool _looksLikeHost(String s) =>
    _ipv4.hasMatch(s) || _ipv6.hasMatch(s) || _dnsName.hasMatch(s);

String _ttyWhere(String tty) {
  if (tty.startsWith('pts/')) return 'Remote session';
  if (tty.startsWith('tty') || tty == 'console') return 'Server console';
  return tty;
}

/// Splits a raw `who` / `last` row into where it came from ("10.1.13.6"),
/// when it started ("Fri Sep 15 11:07") and how it went ("Lasted 2h 07m").
({String from, String at, String status}) _describeLogin(LoginRow l) {
  if (l.active) {
    final tokens = l.detail.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final host = tokens
        .map((t) => t.replaceAll(RegExp(r'[()]'), ''))
        .where(_looksLikeHost)
        .firstOrNull;
    return (
      from: host ?? (tokens.isEmpty ? '' : _ttyWhere(tokens.first)),
      at: '',
      status: 'Active now',
    );
  }

  final parts = l.detail
      .split(' | ')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty);
  if (parts.isEmpty) return (from: '', at: '', status: '');
  final host = parts.skip(1).where(_looksLikeHost).firstOrNull;
  final loginAt = parts
      .where(_weekdayStart.hasMatch)
      .firstOrNull
      ?.split(' - ')
      .first
      .trim();
  if (host == null && loginAt == null) {
    return (from: l.detail, at: '', status: '');
  }

  final duration = RegExp(r'\((?:(\d+)\+)?(\d+):(\d+)\)').firstMatch(l.detail);
  final status = l.detail.contains('still logged in')
      ? 'Still signed in'
      : duration == null
      ? ''
      : 'Lasted ${_formatDuration(int.parse(duration.group(1) ?? '0'), int.parse(duration.group(2)!), int.parse(duration.group(3)!))}';
  return (
    from: host ?? _ttyWhere(parts.first),
    at: loginAt ?? '',
    status: status,
  );
}

String _formatDuration(int days, int hours, int minutes) {
  if (days > 0) return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  if (hours > 0) return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  if (minutes > 0) return '$minutes min';
  return 'under a minute';
}

/// ps `etime` ("[[dd-]hh:]mm:ss") → "2d 4h", "3h 07m", "12 min".
String _friendlyElapsed(String etime) {
  final m = RegExp(
    r'^(?:(\d+)-)?(\d+):(\d+)(?::(\d+))?$',
  ).firstMatch(etime.trim());
  if (m == null) return etime;
  final days = int.parse(m.group(1) ?? '0');
  final a = int.parse(m.group(2)!);
  final b = int.parse(m.group(3)!);
  final hasThree = m.group(4) != null;
  // Three fields are hh:mm:ss; two are mm:ss, or hh:mm once days appear.
  final hours = hasThree || days > 0 ? a : 0;
  final minutes = hasThree || days > 0 ? b : a;
  return _formatDuration(days, hours, minutes);
}

String _ago(DateTime t) {
  final secs = DateTime.now().difference(t).inSeconds;
  if (secs < 5) return 'just now';
  if (secs < 60) return '${secs}s ago';
  if (secs < 3600) return '${secs ~/ 60} min ago';
  return '${secs ~/ 3600}h ago';
}

String _sinceDate(int uptimeSec) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final d = DateTime.now().subtract(Duration(seconds: uptimeSec));
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

// ---------------------------------------------------------------------------
// Services manager card (systemd)
// ---------------------------------------------------------------------------

class _ServicesCard extends ConsumerStatefulWidget {
  final Host host;

  const _ServicesCard({required this.host});

  @override
  ConsumerState<_ServicesCard> createState() => _ServicesCardState();
}

class _ServicesCardState extends ConsumerState<_ServicesCard> {
  String _query = '';
  int _page = 0;
  int _pageSize = 10;

  static const _pageSizes = [10, 20, 40, 80];

  @override
  void didUpdateWidget(_ServicesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.id != widget.host.id) _page = 0;
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(metricsControllerProvider);
    final state = controller.servicesOf(widget.host.id);
    final q = _query.toLowerCase();
    final units = state.units
        .where(
          (s) =>
              s.unit.toLowerCase().contains(q) ||
              s.description.toLowerCase().contains(q),
        )
        .toList();
    final pageCount = math.max(1, (units.length / _pageSize).ceil());
    // A refresh or filter can shrink the list; never sit past the end.
    final page = _page.clamp(0, pageCount - 1);
    final first = page * _pageSize;
    final visible = units.skip(first).take(_pageSize).toList();

    return _MetricCard(
      icon: Icons.settings,
      title: 'System services',
      trailing: _IconAction(
        icon: Icons.refresh,
        tooltip: 'Refresh services',
        busy: state.loading,
        onPressed: () => controller.loadServices(widget.host.id),
      ),
      children: [
        if (controller.cardsPending(widget.host.id) &&
            controller.stateOf(widget.host.id).pollState ==
                HostPollState.error &&
            state.units.isEmpty)
          Text(
            "Can't reach the server right now. Services will load as soon "
            'as it connects.',
            style: _cellStyle,
          )
        else if ((state.loading || controller.cardsPending(widget.host.id)) &&
            state.units.isEmpty)
          const Padding(
            padding: EdgeInsets.all(18),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (state.error != null)
          _errorRow(state.error!)
        else if (state.unsupported)
          Text(
            'This server doesn\'t use systemd, so services can\'t be '
            'managed from here.',
            style: _cellStyle,
          )
        else if (state.units.isEmpty)
          Text('No services found.', style: _cellStyle)
        else ...[
          TextField(
            onChanged: (v) => setState(() {
              _query = v;
              _page = 0;
            }),
            style: const TextStyle(fontSize: 12.5),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: Icon(
                Icons.search,
                size: 16,
                color: AppColors.textFaint,
              ),
              hintText: 'Filter services',
              hintStyle: _labelStyle,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.border),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (units.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No services match "$_query".', style: _cellStyle),
            )
          else ...[
            for (final u in visible)
              _ServiceRow(
                unit: u,
                busy: state.loading,
                onAction: (a) =>
                    controller.serviceAction(widget.host.id, u.unit, a),
              ),
            const SizedBox(height: 6),
            _Pager(
              total: units.length,
              page: page,
              pageSize: _pageSize,
              pageSizes: _pageSizes,
              onPage: (p) => setState(() => _page = p),
              onPageSize: (size) => setState(() {
                // Keep the first visible service on screen after resizing.
                _page = first ~/ size;
                _pageSize = size;
              }),
            ),
          ],
        ],
      ],
    );
  }
}

/// Footer for paged lists: rows-per-page menu, "11–20 of 245", prev/next.
class _Pager extends StatelessWidget {
  final int total;
  final int page;
  final int pageSize;
  final List<int> pageSizes;
  final ValueChanged<int> onPage;
  final ValueChanged<int> onPageSize;

  const _Pager({
    required this.total,
    required this.page,
    required this.pageSize,
    required this.pageSizes,
    required this.onPage,
    required this.onPageSize,
  });

  @override
  Widget build(BuildContext context) {
    final pageCount = math.max(1, (total / pageSize).ceil());
    final from = total == 0 ? 0 : page * pageSize + 1;
    final to = math.min(total, (page + 1) * pageSize);

    Widget navButton(IconData icon, String tooltip, int? target) => IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      color: AppColors.textSecondary,
      disabledColor: AppColors.textFaint.withValues(alpha: 0.4),
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      padding: EdgeInsets.zero,
      onPressed: target == null ? null : () => onPage(target),
    );

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 6,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Rows per page', style: _labelStyle),
            const SizedBox(width: 8),
            Container(
              height: 28,
              padding: const EdgeInsets.only(left: 10, right: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.border),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: pageSize,
                  isDense: true,
                  dropdownColor: AppColors.card,
                  borderRadius: BorderRadius.circular(8),
                  icon: Icon(
                    Icons.expand_more,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
                  items: [
                    for (final size in pageSizes)
                      DropdownMenuItem(value: size, child: Text('$size')),
                  ],
                  onChanged: (size) {
                    if (size != null && size != pageSize) onPageSize(size);
                  },
                ),
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$from–$to of $total',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 8),
            navButton(Icons.first_page, 'First page', page > 0 ? 0 : null),
            navButton(
              Icons.chevron_left,
              'Previous page',
              page > 0 ? page - 1 : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('Page ${page + 1} of $pageCount', style: _labelStyle),
            ),
            navButton(
              Icons.chevron_right,
              'Next page',
              page < pageCount - 1 ? page + 1 : null,
            ),
            navButton(
              Icons.last_page,
              'Last page',
              page < pageCount - 1 ? pageCount - 1 : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  final ServiceInfo unit;
  final bool busy;
  final ValueChanged<String> onAction;

  const _ServiceRow({
    required this.unit,
    required this.busy,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final failed = unit.isFailed;
    final running = unit.isRunning;
    final actions = running
        ? const [('Restart', 'restart'), ('Stop', 'stop')]
        : const [('Start', 'start'), ('Enable', 'enable')];
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: failed
                  ? AppColors.danger
                  : running
                  ? AppColors.success
                  : AppColors.textFaint,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  unit.description.isEmpty ? unit.unit : unit.description,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
                ),
                if (unit.description.isNotEmpty)
                  Text(
                    unit.unit,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10,
                      color: AppColors.textFaint,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            switch (unit.active) {
              'active' => 'Running',
              'inactive' => 'Stopped',
              'failed' => 'Failed',
              'activating' => 'Starting…',
              'deactivating' => 'Stopping…',
              final other => other,
            },
            style: TextStyle(
              fontSize: 10.5,
              color: failed
                  ? AppColors.danger
                  : running
                  ? AppColors.success
                  : AppColors.textFaint,
            ),
          ),
          const SizedBox(width: 8),
          for (final (label, action) in actions)
            Tooltip(
              message: 'systemctl $action',
              child: InkWell(
                onTap: busy ? null : () => onAction(action),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  margin: const EdgeInsets.only(left: 5),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.border),
                    color: AppColors.surfaceAlt,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cron manager card
// ---------------------------------------------------------------------------

Widget _errorRow(String message) {
  return Row(
    children: [
      Icon(Icons.error_outline, size: 14, color: AppColors.danger),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          message,
          style: TextStyle(fontSize: 12, color: AppColors.danger),
          softWrap: true,
        ),
      ),
    ],
  );
}

class _CronCard extends ConsumerStatefulWidget {
  final Host host;

  const _CronCard({required this.host});

  @override
  ConsumerState<_CronCard> createState() => _CronCardState();
}

class _CronCardState extends ConsumerState<_CronCard> {
  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(metricsControllerProvider);
    final state = controller.cronOf(widget.host.id);
    return _MetricCard(
      icon: Icons.schedule,
      title: 'Crontab',
      trailing: _IconAction(
        icon: Icons.refresh,
        tooltip: 'Refresh scheduled tasks',
        busy: state.loading,
        onPressed: () => controller.loadCron(widget.host.id),
      ),
      children: [
        if (controller.cardsPending(widget.host.id) &&
            controller.stateOf(widget.host.id).pollState ==
                HostPollState.error &&
            state.crontab.trim().isEmpty)
          Text(
            "Can't reach the server right now. Scheduled tasks will load "
            'as soon as it connects.',
            style: _cellStyle,
          )
        else if ((state.loading || controller.cardsPending(widget.host.id)) &&
            state.crontab.trim().isEmpty)
          const Padding(
            padding: EdgeInsets.all(18),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (state.error != null)
          _errorRow(state.error!)
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _addJob(context),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                icon: Icon(Icons.add, size: 13, color: AppColors.textSecondary),
                label: Text(
                  'Add task',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (state.crontab.trim().isEmpty)
            Text('No scheduled tasks yet.', style: _cellStyle)
          else
            for (var i = 0; i < state.cronLines.length; i++)
              _CronRow(
                raw: state.cronLines[i],
                busy: state.loading,
                onDelete: () async {
                  final lines = state.cronLines;
                  lines
                    ..removeAt(i)
                    ..removeWhere((l) => l.trim().isEmpty);
                  final err = await controller.writeCron(
                    widget.host.id,
                    lines.join('\n'),
                  );
                  if (!context.mounted) return;
                  if (err != null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to write crontab: $err')),
                    );
                  }
                },
              ),
        ],
      ],
    );
  }

  Future<void> _addJob(BuildContext context) async {
    final controller = ref.read(metricsControllerProvider);
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _CronEntryDialog(),
    );
    if (result == null) return;
    final (schedule, command) = result;
    if (schedule.isEmpty || command.isEmpty) return;
    final state = controller.cronOf(widget.host.id);
    var body = state.crontab.trimRight();
    final line = '$schedule $command';
    body = body.isEmpty ? line : '$body\n$line';
    final err = await controller.writeCron(widget.host.id, body);
    if (!context.mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to write crontab: $err')));
    }
  }
}

/// A single cron line, commented or real. Real jobs get a delete button.
class _CronRow extends StatelessWidget {
  final String raw;
  final bool busy;
  final VoidCallback onDelete;

  const _CronRow({
    required this.raw,
    required this.busy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isComment = raw.trimLeft().startsWith('#');
    final job = isComment ? null : _splitCronLine(raw);
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
        color: isComment ? null : AppColors.surfaceAlt,
      ),
      child: Row(
        children: [
          Expanded(
            child: job == null
                ? SelectableText(
                    raw,
                    style: _monoStyle.copyWith(
                      color: isComment ? AppColors.textFaint : null,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: _describeSchedule(job.$1),
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            if (_describeSchedule(job.$1) != job.$1)
                              TextSpan(
                                text: '   ${job.$1}',
                                style: _monoStyle.copyWith(
                                  fontSize: 10,
                                  color: AppColors.textFaint,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(job.$2, style: _monoStyle),
                    ],
                  ),
          ),
          if (!isComment)
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                size: 14,
                color: AppColors.textFaint,
              ),
              tooltip: 'Delete job',
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              padding: EdgeInsets.zero,
              onPressed: busy ? null : onDelete,
            ),
        ],
      ),
    );
  }
}

/// Add-cron-job dialog: schedule presets + custom expression + command.
class _CronEntryDialog extends StatefulWidget {
  const _CronEntryDialog();

  @override
  State<_CronEntryDialog> createState() => _CronEntryDialogState();
}

class _CronEntryDialogState extends State<_CronEntryDialog> {
  static const _presets = [
    ('Every minute', '* * * * *'),
    ('Every hour', '0 * * * *'),
    ('Daily at midnight', '0 0 * * *'),
    ('Weekly (Sunday 00:00)', '0 0 * * 0'),
    ('Monthly (1st 00:00)', '0 0 1 * *'),
  ];

  String _schedule = '';
  final _exprController = TextEditingController();
  final _cmdController = TextEditingController();
  bool _custom = false;

  @override
  void dispose() {
    _exprController.dispose();
    _cmdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(
        'Add cron job',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, expr) in _presets)
                  ChoiceChip(
                    label: Text(label, style: TextStyle(fontSize: 11.5)),
                    selected: !_custom && expr == _schedule,
                    onSelected: (_) => setState(() {
                      _custom = false;
                      _schedule = expr;
                    }),
                  ),
                ChoiceChip(
                  label: Text('Custom', style: TextStyle(fontSize: 11.5)),
                  selected: _custom,
                  onSelected: (_) => setState(() {
                    _custom = true;
                    _schedule = _exprController.text.trim();
                  }),
                ),
              ],
            ),
            if (_custom) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _exprController,
                onChanged: (v) => setState(() => _schedule = v.trim()),
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Cron expression',
                  hintText: '* * * * *',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text('Command', style: _labelStyle),
            const SizedBox(height: 4),
            TextField(
              controller: _cmdController,
              maxLines: 3,
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText:
                    'e.g. /usr/local/bin/backup.sh > /var/log/backup.log 2>&1',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _custom && _schedule.isEmpty
                  ? 'Preset or expression required.'
                  : 'Preview: ${_schedule.isEmpty ? '<schedule>' : _schedule} '
                        '${_cmdController.text.isEmpty ? '<command>' : _cmdController.text}',
              style: _labelStyle,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _cmdController.text.trim().isEmpty || _schedule.trim().isEmpty
              ? null
              : () {
                  Navigator.pop(context, (
                    _schedule.trim(),
                    _cmdController.text.trim(),
                  ));
                },
          child: Text('Add'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

String memF(double mb) {
  if (mb >= 1024 * 1024) {
    return '${(mb / 1024 / 1024).toStringAsFixed(1)} TB';
  }
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb.toStringAsFixed(0)} MB';
}

String bytesF(double b) {
  if (b >= 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
  if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${b.toStringAsFixed(0)} B';
}

String formatUptime(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return '$d d $h h';
  if (h > 0) return '$h h $m m';
  return '$m m';
}

/// Splits a crontab job line into (schedule, command); null for lines that
/// aren't jobs (blank lines, variable assignments like MAILTO=...).
(String, String)? _splitCronLine(String raw) {
  final line = raw.trim();
  final m =
      RegExp(r'^(@\w+)\s+(.+)$').firstMatch(line) ??
      RegExp(r'^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$').firstMatch(line);
  if (m == null || m.group(1)!.contains('=')) return null;
  return (m.group(1)!.replaceAll(RegExp(r'\s+'), ' '), m.group(2)!);
}

/// Plain-language reading of common cron schedules; anything unusual is
/// returned unchanged.
String _describeSchedule(String expr) {
  const specials = {
    '@reboot': 'When the server starts',
    '@yearly': 'Once a year',
    '@annually': 'Once a year',
    '@monthly': 'Once a month',
    '@weekly': 'Once a week',
    '@daily': 'Every day at midnight',
    '@midnight': 'Every day at midnight',
    '@hourly': 'Every hour',
  };
  if (expr.startsWith('@')) return specials[expr] ?? expr;

  final f = expr.split(' ');
  if (f.length != 5) return expr;
  final [min, hour, dom, mon, dow] = f;
  bool isNum(String v) => RegExp(r'^\d+$').hasMatch(v);
  final step = RegExp(r'^\*/(\d+)$');
  final anyDay = dom == '*' && mon == '*' && dow == '*';
  String time() => '${hour.padLeft(2, '0')}:${min.padLeft(2, '0')}';
  const weekdays = [
    'Sunday',
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  if (min == '*' && hour == '*' && anyDay) return 'Every minute';
  if (step.hasMatch(min) && hour == '*' && anyDay) {
    return 'Every ${step.firstMatch(min)!.group(1)} minutes';
  }
  if (isNum(min) && hour == '*' && anyDay) {
    return min == '0' ? 'Every hour' : 'Every hour at :${min.padLeft(2, '0')}';
  }
  if (isNum(min) && step.hasMatch(hour) && anyDay) {
    return 'Every ${step.firstMatch(hour)!.group(1)} hours';
  }
  if (isNum(min) && isNum(hour) && mon == '*') {
    if (dom == '*' && dow == '*') return 'Every day at ${time()}';
    if (dom == '*' && dow == '1-5') return 'Weekdays at ${time()}';
    if (dom == '*' && isNum(dow) && int.parse(dow) <= 7) {
      return 'Every ${weekdays[int.parse(dow)]} at ${time()}';
    }
    if (isNum(dom) && dow == '*') return 'Monthly on day $dom at ${time()}';
  }
  return expr;
}
