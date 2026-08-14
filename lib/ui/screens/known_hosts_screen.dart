import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../state/nav.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';
import '../widgets/band_selection.dart';
import '../widgets/multi_select_bar.dart';

class KnownHostsScreen extends ConsumerStatefulWidget {
  const KnownHostsScreen({super.key});

  @override
  ConsumerState<KnownHostsScreen> createState() => _KnownHostsScreenState();
}

class _KnownHostsScreenState extends ConsumerState<KnownHostsScreen>
    with BandSelection<KnownHostsScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _selectionBarScheduled = false;

  @override
  void initState() {
    super.initState();
    bandScrollController = _scrollController;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
  void _onTileTap(KnownHost host) {
    if (HardwareKeyboard.instance.isControlPressed) {
      setState(() {
        multiSelected.contains(host.hostKey)
            ? multiSelected.remove(host.hostKey)
            : multiSelected.add(host.hostKey);
      });
    } else if (multiSelected.isNotEmpty) {
      setState(multiSelected.clear);
    } else {
      _copyFingerprint(host);
    }
  }

  void _copyFingerprint(KnownHost host) {
    Clipboard.setData(ClipboardData(text: host.fingerprint));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Fingerprint copied to clipboard')),
    );
  }

  Future<void> _removeOne(KnownHost host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove host key?'),
        content: Text(
          'Forgetting "${host.hostKey}" means the next connection '
          'will ask you to verify the host key again.',
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appDatabaseProvider).deleteKnownHost(host.hostKey);
      if (mounted) {
        setState(() => multiSelected.remove(host.hostKey));
      }
    }
  }

  Future<void> _removeSelection() async {
    final hosts = ref.read(knownHostsProvider).valueOrNull ?? const <KnownHost>[];
    final selected =
        hosts.where((h) => multiSelected.contains(h.hostKey)).toList();
    if (selected.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove host keys?'),
        content: Text('Forget ${selected.length} host key(s)? The next '
            'connections will ask you to verify them again.'),
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final db = ref.read(appDatabaseProvider);
    for (final host in selected) {
      await db.deleteKnownHost(host.hostKey);
    }
    if (mounted) {
      setState(multiSelected.clear);
    }
  }

  void _syncSelectionBar() {
    final notifier = ref.read(selectionBarProvider.notifier);
    // Hidden screens in the IndexedStack stay alive; only the active
    // section may publish the bar.
    if (ref.read(appSectionProvider) != AppSection.knownHosts) {
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
          icon: Icons.delete_outline,
          // Icon only: the trash can already reads as "remove host keys".
          label: '',
          danger: true,
          onTap: _removeSelection,
        ),
      ],
      onClose: () => setState(multiSelected.clear),
    );
  }

  @override
  Widget build(BuildContext context) {
    _scheduleSelectionBarSync();
    final hostsAsync = ref.watch(knownHostsProvider);

    return hostsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (hosts) {
        if (hosts.isEmpty) {
          return const _EmptyState();
        }
        return Stack(
          key: bandStackKey,
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: onBandPointerDown,
                onPointerMove: onBandPointerMove,
                onPointerUp: onBandPointerUp,
                onPointerCancel: onBandPointerCancel,
                child: GridView.builder(
                  controller: _scrollController,
                  physics: bandScrollPhysics,
                  padding: const EdgeInsets.all(20),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 300,
                    mainAxisExtent: 62,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: hosts.length,
                  itemBuilder: (context, index) {
                    final host = hosts[index];
                    return _KnownHostTile(
                      key: bandCardKey(host.hostKey),
                      host: host,
                      selected: multiSelected.contains(host.hostKey),
                      onTap: () => _onTileTap(host),
                      onCopy: () => _copyFingerprint(host),
                      onRemove: () => _removeOne(host),
                    );
                  },
                ),
              ),
            ),
            bandOverlay(),
          ],
        );
      },
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
              Icons.shield_outlined,
              size: 30,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No known hosts yet',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Host keys are recorded here after you accept the security '
            'prompt of a first connection.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _KnownHostTile extends ConsumerStatefulWidget {
  final KnownHost host;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onRemove;

  const _KnownHostTile({
    super.key,
    required this.host,
    required this.selected,
    required this.onTap,
    required this.onCopy,
    required this.onRemove,
  });

  @override
  ConsumerState<_KnownHostTile> createState() => _KnownHostTileState();
}

class _KnownHostTileState extends ConsumerState<_KnownHostTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    return Tooltip(
      message:
          'First seen: ${_formatDate(host.firstSeen)}\n'
          'Last seen: ${_formatDate(host.lastSeen)}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          onSecondaryTapDown: (details) =>
              _showContextMenu(context, details.globalPosition),
          borderRadius: BorderRadius.circular(9),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: widget.selected ? AppColors.surfaceAlt : AppColors.card,
              borderRadius: BorderRadius.circular(9),
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
                    Icons.dns_outlined,
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              host.hostKey,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          _TypeChip(keyType: host.keyType),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        host.fingerprint,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          fontFamily: 'JetBrainsMono',
                          color: AppColors.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (_hovered)
                  _RemoveButton(onTap: widget.onRemove)
                else
                  const SizedBox(width: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset position,
  ) async {
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: [
        PopupMenuItem(
          value: 'copy',
          child: Row(
            children: [
              Icon(
                Icons.copy_outlined,
                size: 16,
                color: AppColors.textSecondary,
              ),
              SizedBox(width: 10),
              Text('Copy fingerprint', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              Icon(
                Icons.delete_outline,
                size: 16,
                color: AppColors.textSecondary,
              ),
              SizedBox(width: 10),
              Text('Remove', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'copy':
        widget.onCopy();
      case 'remove':
        widget.onRemove();
    }
  }
}

class _RemoveButton extends StatelessWidget {
  final VoidCallback onTap;

  const _RemoveButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Remove host key',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.border),
          ),
          child: Icon(
            Icons.delete_outline,
            size: 14,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String keyType;

  const _TypeChip({required this.keyType});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        keyType,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          color: AppColors.textSecondary,
          fontFamily: 'JetBrainsMono',
        ),
      ),
    );
  }
}

