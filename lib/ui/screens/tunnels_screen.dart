import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/ssh/tunnel_manager.dart';
import '../state/nav.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';
import '../widgets/band_selection.dart';
import '../widgets/multi_select_bar.dart';
import '../widgets/tunnel_details_panel.dart';

class TunnelsScreen extends ConsumerStatefulWidget {
  const TunnelsScreen({super.key});

  @override
  ConsumerState<TunnelsScreen> createState() => _TunnelsScreenState();
}

class _TunnelsScreenState extends ConsumerState<TunnelsScreen>
    with BandSelection<TunnelsScreen> {
  final _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _query = '';
  String? _editTunnelId;
  bool _creating = false;
  bool _selectionBarScheduled = false;

  @override
  void initState() {
    super.initState();
    bandScrollController = _scrollController;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _close() {
    setState(() {
      _editTunnelId = null;
      _creating = false;
    });
  }

  void _onTunnelTap(Tunnel tunnel) {
    if (HardwareKeyboard.instance.isControlPressed) {
      setState(() {
        multiSelected.contains(tunnel.id)
            ? multiSelected.remove(tunnel.id)
            : multiSelected.add(tunnel.id);
      });
    } else if (multiSelected.isNotEmpty) {
      setState(multiSelected.clear);
    }
  }

  Future<void> _deleteSelection() async {
    final tunnels =
        ref.read(watchTunnelsProvider).valueOrNull ?? const <Tunnel>[];
    final selected = tunnels
        .where((t) => multiSelected.contains(t.id))
        .toList(growable: false);
    if (selected.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete tunnels'),
        content: Text(
          'Delete ${selected.length} tunnel${selected.length == 1 ? '' : 's'}? '
          'Running tunnels will be stopped.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final manager = ref.read(tunnelManagerProvider);
    for (final t in selected) {
      await manager.stop(t.id);
      await ref.read(appDatabaseProvider).deleteTunnel(t.id);
    }
    if (mounted) {
      setState(multiSelected.clear);
      if (_editTunnelId != null &&
          selected.any((t) => t.id == _editTunnelId)) {
        _close();
      }
    }
  }

  void _syncSelectionBar() {
    final notifier = ref.read(selectionBarProvider.notifier);
    if (ref.read(appSectionProvider) != AppSection.tunnels) {
      if (notifier.state != null) notifier.state = null;
      return;
    }
    if (multiSelected.isEmpty) {
      if (notifier.state != null) notifier.state = null;
      return;
    }
    notifier.state = SelectionBarData(
      count: multiSelected.length,
      actions: [
        MultiSelectAction(
          icon: Icons.play_arrow,
          label: 'Start',
          onTap: _startSelection,
        ),
        MultiSelectAction(
          icon: Icons.refresh,
          label: 'Restart',
          onTap: _restartSelection,
        ),
        MultiSelectAction(
          icon: Icons.stop,
          label: 'Stop',
          onTap: _stopSelection,
        ),
        MultiSelectAction(
          icon: Icons.delete_outline,
          label: 'Delete',
          danger: true,
          onTap: _deleteSelection,
        ),
      ],
      onClose: () => setState(multiSelected.clear),
    );
  }

  Future<List<Tunnel>> _selectedTunnels() async {
    final tunnels =
        ref.read(watchTunnelsProvider).valueOrNull ?? const <Tunnel>[];
    return tunnels
        .where((t) => multiSelected.contains(t.id))
        .toList(growable: false);
  }

  Future<void> _startSelection() async {
    final manager = ref.read(tunnelManagerProvider);
    // Running/connecting tunnels are skipped by the manager's guard.
    for (final t in await _selectedTunnels()) {
      unawaited(manager.start(t));
    }
  }

  Future<void> _restartSelection() async {
    final manager = ref.read(tunnelManagerProvider);
    for (final t in await _selectedTunnels()) {
      unawaited(manager.restart(t));
    }
  }

  Future<void> _stopSelection() async {
    final manager = ref.read(tunnelManagerProvider);
    for (final t in await _selectedTunnels()) {
      await manager.stop(t.id);
    }
  }

  void _scheduleSelectionBarSync() {
    if (_selectionBarScheduled) return;
    _selectionBarScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionBarScheduled = false;
      if (!mounted) return;
      _syncSelectionBar();
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleSelectionBarSync();

    // Global 'e' shortcut over a tunnel card: open its editor.
    ref.listen<String?>(tunnelEditRequestProvider, (_, next) {
      if (next == null) return;
      ref.read(tunnelEditRequestProvider.notifier).state = null;
      setState(() {
        _editTunnelId = next;
        _creating = false;
      });
    });

    final tunnelsAsync = ref.watch(watchTunnelsProvider);

    return tunnelsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (tunnels) {
        Tunnel? editing;
        if (_editTunnelId != null) {
          for (final t in tunnels) {
            if (t.id == _editTunnelId) {
              editing = t;
              break;
            }
          }
          if (editing == null && !_creating) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _editTunnelId != null) {
                setState(() => _editTunnelId = null);
              }
            });
          }
        }

        final panelOpen = _creating || editing != null;
        final q = _query.trim().toLowerCase();
        final filtered = q.isEmpty
            ? List<Tunnel>.of(tunnels)
            : tunnels
                  .where(
                    (t) =>
                        t.name.toLowerCase().contains(q) ||
                        t.type.toLowerCase().contains(q) ||
                        t.bindAddress.toLowerCase().contains(q),
                  )
                  .toList();
        filtered.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );

        return Stack(
          children: [
            Positioned.fill(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SearchField(
                          controller: _searchController,
                          query: _query,
                          onChanged: (v) => setState(() => _query = v),
                          onClear: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: () => setState(() {
                                _creating = true;
                                _editTunnelId = null;
                              }),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('New tunnel'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      key: bandStackKey,
                      children: [
                        Positioned.fill(
                          child: Listener(
                            behavior: HitTestBehavior.translucent,
                            onPointerDown: onBandPointerDown,
                            onPointerMove: onBandPointerMove,
                            onPointerUp: onBandPointerUp,
                            onPointerCancel: onBandPointerCancel,
                            child: tunnels.isEmpty
                                ? _EmptyState(
                                    onCreate: () => setState(() {
                                      _creating = true;
                                      _editTunnelId = null;
                                    }),
                                  )
                                : filtered.isEmpty
                                    ? const _NoResults()
                                    : GridView.builder(
                                        controller: _scrollController,
                                        physics: bandScrollPhysics,
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          14,
                                          16,
                                          20,
                                        ),
                                        gridDelegate:
                                            const SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent: 300,
                                          mainAxisExtent: 64,
                                          mainAxisSpacing: 10,
                                          crossAxisSpacing: 10,
                                        ),
                                        itemCount: filtered.length,
                                        itemBuilder: (context, index) {
                                          final t = filtered[index];
                                          return _TunnelCard(
                                            key: bandCardKey(t.id),
                                            tunnel: t,
                                            selected: multiSelected.contains(
                                              t.id,
                                            ),
                                            onTap: () => _onTunnelTap(t),
                                            onToggle: () {
                                              final rt = ref
                                                  .read(tunnelManagerProvider)
                                                  .statusOf(t.id);
                                              if (rt == null ||
                                                  rt.status ==
                                                      TunnelStatus.stopped ||
                                                  rt.status ==
                                                      TunnelStatus.error) {
                                                ref
                                                    .read(tunnelManagerProvider)
                                                    .start(t);
                                              } else {
                                                ref
                                                    .read(tunnelManagerProvider)
                                                    .stop(t.id);
                                              }
                                            },
                                            onRestart: () async {
                                              final manager = ref.read(
                                                tunnelManagerProvider,
                                              );
                                              await manager.stop(t.id);
                                              await manager.start(t);
                                            },
                                            onEdit: () => setState(() {
                                              _editTunnelId = t.id;
                                              _creating = false;
                                            }),
                                            onDelete: () async {
                                              await ref
                                                  .read(tunnelManagerProvider)
                                                  .stop(t.id);
                                              await ref
                                                  .read(appDatabaseProvider)
                                                  .deleteTunnel(t.id);
                                            },
                                          );
                                        },
                                      ),
                          ),
                        ),
                        bandOverlay(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (panelOpen) ...[
              Positioned.fill(
                child: GestureDetector(
                  onTap: _close,
                  child: const ColoredBox(color: Color(0x66000000)),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: TunnelDetailsPanel(
                  tunnel: editing,
                  creating: _creating,
                  onClose: _close,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _TunnelCard extends ConsumerStatefulWidget {
  final Tunnel tunnel;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onRestart;
  final VoidCallback onEdit;
  final Future<void> Function() onDelete;

  const _TunnelCard({
    super.key,
    required this.tunnel,
    required this.selected,
    required this.onTap,
    required this.onToggle,
    required this.onRestart,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  ConsumerState<_TunnelCard> createState() => _TunnelCardState();
}

class _TunnelCardState extends ConsumerState<_TunnelCard> {
  bool _hovered = false;

  IconData _iconFor(String type) {
    switch (type) {
      case 'dynamic':
        return Icons.hub_outlined;
      case 'remote':
        return Icons.arrow_outward_outlined;
      default:
        return Icons.input_outlined;
    }
  }

  /// Maps a tunnel status to its accent color, matching the terminal-tab
  /// status palette used in the window title bar.
  Color _statusColor(TunnelStatus? status) {
    switch (status) {
      case TunnelStatus.running:
        return AppColors.success;
      case TunnelStatus.connecting:
        return AppColors.warning;
      case TunnelStatus.error:
        return AppColors.danger;
      case TunnelStatus.stopped:
      case null:
        return AppColors.border;
    }
  }

  /// Bind port label: actual when running, requested otherwise, "auto"
  /// when the OS assigns one only after start.
  String get portLabel {
    final rt = ref.read(tunnelManagerProvider).statusOf(widget.tunnel.id);
    return rt?.actualBindPort?.toString() ??
        (widget.tunnel.bindPort?.toString() ?? 'auto');
  }

  @override
  Widget build(BuildContext context) {
    final tunnel = widget.tunnel;
    // Listen to the manager so status changes repaint.
    ref.watch(tunnelManagerProvider);
    final rt = ref.read(tunnelManagerProvider).statusOf(tunnel.id);
    final running = rt?.status == TunnelStatus.running;
    final connecting = rt?.status == TunnelStatus.connecting;
    final hasError = rt?.status == TunnelStatus.error;

    return Tooltip(
      message: hasError ? (rt?.error ?? 'Error') : '',
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _hovered = true);
          ref.read(hoveredEditTargetProvider.notifier).state =
              HoveredEditTarget(HoveredEditKind.tunnel, tunnel.id);
        },
        onExit: (_) {
          setState(() => _hovered = false);
          final t = HoveredEditTarget(HoveredEditKind.tunnel, tunnel.id);
          if (ref.read(hoveredEditTargetProvider) == t) {
            ref.read(hoveredEditTargetProvider.notifier).state = null;
          }
        },
        child: InkWell(
          onTap: widget.onTap,
          onSecondaryTapDown: (details) =>
              _showContextMenu(context, details.globalPosition),
          borderRadius: BorderRadius.circular(9),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: widget.selected
                        ? AppColors.surfaceAlt
                        : AppColors.card,
                    border: Border.all(
                      color: widget.selected
                          ? AppColors.accentBorder
                          : AppColors.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: AppColors.accentMuted,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(
                          _iconFor(tunnel.type),
                          size: 15,
                          color: AppColors.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tunnel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Tooltip(
                              message: hasError
                                  ? (rt?.error ?? 'Error')
                                  : '$ruleText\nClick to copy',
                              waitDuration:
                                  const Duration(milliseconds: 500),
                              child: InkWell(
                                onTap: hasError ? null : _copyLocalEndpoint,
                                borderRadius: BorderRadius.circular(4),
                                child: Text(
                                  hasError
                                      ? (rt?.error ?? 'Error')
                                      : ruleText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontFamily: 'JetBrainsMono',
                                    color: hasError
                                        ? Colors.redAccent.shade200
                                        : AppColors.textFaint,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (_hovered)
                        _CardActionButton(
                          icon: running || connecting
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          tooltip:
                              running || connecting ? 'Stop' : 'Start',
                          onTap: widget.onToggle,
                        )
                      else
                        const SizedBox(width: 28),
                    ],
                  ),
                ),
                // Colored bottom edge shows tunnel state - spans the full
                // width and is clipped by the card's rounded corners.
                if (_statusColor(rt?.status) != AppColors.border)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        height: 3,
                        decoration: BoxDecoration(
                          color: _statusColor(rt?.status),
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(9),
                            bottomRight: Radius.circular(9),
                          ),
                        ),
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

  /// The one-line forwarding rule, e.g. `127.0.0.1:8080 → :80`.
  String get ruleText {
    final t = widget.tunnel;
    switch (t.type) {
      case 'local':
        final target = t.targetHost;
        final targetPort = t.targetPort ?? 0;
        final isLocal = target == null ||
            target.isEmpty ||
            target == 'localhost' ||
            target == '127.0.0.1';
        return '${t.bindAddress}:$portLabel → '
            '${isLocal ? '' : '$target:'}$targetPort';
      case 'dynamic':
        return 'SOCKS5 ${t.bindAddress}:$portLabel';
      case 'remote':
        return 'remote ${t.bindAddress}:$portLabel';
      default:
        return t.type;
    }
  }

  /// Copies the local bind endpoint (actual bound port when running).
  Future<void> _copyLocalEndpoint() async {
    if (portLabel == 'auto') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start the tunnel to get its bound port'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final text = '${widget.tunnel.bindAddress}:$portLabel';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $text'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final rt = ref.read(tunnelManagerProvider).statusOf(widget.tunnel.id);
    final active = rt?.status == TunnelStatus.running ||
        rt?.status == TunnelStatus.connecting;
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: [
        const PopupMenuItem(
          value: 'edit',
          child: _MenuItemRow(
            icon: Icons.edit_outlined,
            label: 'Edit',
          ),
        ),
        PopupMenuItem(
          value: 'toggle',
          child: _MenuItemRow(
            icon: active ? Icons.stop_outlined : Icons.play_arrow_outlined,
            label: active ? 'Stop' : 'Start',
          ),
        ),
        const PopupMenuItem(
          value: 'restart',
          child: _MenuItemRow(
            icon: Icons.refresh_outlined,
            label: 'Restart',
          ),
        ),
        PopupMenuItem(
          value: 'copy',
          child: _MenuItemRow(
            icon: Icons.content_copy_outlined,
            label: portLabel == 'auto' ? 'Copy endpoint' : 'Copy $portLabel',
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: _MenuItemRow(
            icon: Icons.delete_outline,
            label: 'Delete',
          ),
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'edit':
        widget.onEdit();
        break;
      case 'toggle':
        widget.onToggle();
        break;
      case 'restart':
        widget.onRestart();
        break;
      case 'copy':
        await _copyLocalEndpoint();
        break;
      case 'delete':
        await widget.onDelete();
        break;
    }
  }
}

/// Icon + label row used by the tunnel context menu (mirrors the hosts
/// screen menu style).
class _MenuItemRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuItemRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.textSecondary),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(fontSize: 12.5),
        ),
      ],
    );
  }
}

/// Bordered hover button matching the hosts screen card actions.
class _CardActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _CardActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_CardActionButton> createState() => _CardActionButtonState();
}

class _CardActionButtonState extends State<_CardActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        // Raw pointer-down bypasses the gesture arena entirely so the
        // action fires immediately, with no recognizer/splash latency.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => widget.onTap(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hovered ? AppColors.cardHover : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _hovered ? AppColors.accentBorder : AppColors.border,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 13.5,
              color: _hovered ? AppColors.accent : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchField({
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: 'Search tunnels...',
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: onClear,
              ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lan_outlined, size: 48, color: AppColors.textFaint),
          const SizedBox(height: 12),
          const Text(
            'No tunnels yet',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Set up SSH port forwarding rules that outlive any single session.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Create your first tunnel'),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No matches',
        style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
      ),
    );
  }
}
