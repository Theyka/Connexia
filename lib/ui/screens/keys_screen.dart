import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../state/nav.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';
import '../widgets/band_selection.dart';
import '../widgets/key_details_panel.dart';
import '../widgets/multi_select_bar.dart';

enum _KeyPanelMode { none, manual, generate }

class KeysScreen extends ConsumerStatefulWidget {
  const KeysScreen({super.key});

  @override
  ConsumerState<KeysScreen> createState() => _KeysScreenState();
}

class _KeysScreenState extends ConsumerState<KeysScreen>
    with BandSelection<KeysScreen> {
  final _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _query = '';
  _KeyPanelMode _panelMode = _KeyPanelMode.none;
  String? _editId;
  String? _pendingImportPem;
  final Set<String> _encrypted = {};
  bool _selectionBarScheduled = false;

  @override
  void initState() {
    super.initState();
    bandScrollController = _scrollController;
    _scanEncryptedKeys();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _scanEncryptedKeys() async {
    final identities = await ref.read(appDatabaseProvider).allIdentities();
    final vault = ref.read(vaultProvider);
    final encrypted = <String>{};
    for (final identity in identities) {
      try {
        final pem = await vault.decrypt(identity.encryptedKeyPem);
        if (SSHKeyPair.isEncryptedPem(pem)) encrypted.add(identity.id);
      } catch (_) {}
    }
    if (mounted) setState(() => _encrypted.addAll(encrypted));
  }

  void _closePanel() {
    setState(() {
      _panelMode = _KeyPanelMode.none;
      _editId = null;
      _pendingImportPem = null;
    });
  }

  void _openEditor(Identity identity) {
    setState(() {
      _editId = identity.id;
      _pendingImportPem = null;
      _panelMode = _KeyPanelMode.manual;
    });
  }

  void _openEditorById(String id) {
    final identities =
        ref.read(identitiesProvider).valueOrNull ?? const <Identity>[];
    for (final identity in identities) {
      if (identity.id == id) {
        _openEditor(identity);
        return;
      }
    }
  }

  void _onKeyTap(Identity identity) {
    if (HardwareKeyboard.instance.isControlPressed) {
      setState(() {
        multiSelected.contains(identity.id)
            ? multiSelected.remove(identity.id)
            : multiSelected.add(identity.id);
      });
    } else if (multiSelected.isNotEmpty) {
      setState(multiSelected.clear);
      _openEditor(identity);
    } else {
      _openEditor(identity);
    }
  }

  Future<void> _deleteSelection() async {
    final identities =
        ref.read(identitiesProvider).valueOrNull ?? const <Identity>[];
    final selected =
        identities.where((i) => multiSelected.contains(i.id)).toList();
    if (selected.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete keys?'),
        content: Text('Delete ${selected.length} key(s)? This cannot be '
            'undone.'),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final db = ref.read(appDatabaseProvider);
    for (final identity in selected) {
      await db.deleteIdentity(identity.id);
    }
    if (mounted) {
      setState(multiSelected.clear);
      if (_editId != null && selected.any((i) => i.id == _editId)) {
        _closePanel();
      }
    }
  }

  Future<void> _setPassphrase(Identity identity) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set passphrase'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Passphrase'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final vault = ref.read(vaultProvider);
      final encrypted = await vault.encrypt(controller.text);
      await ref
          .read(appDatabaseProvider)
          .upsertIdentity(
            IdentitiesCompanion(
              id: drift.Value(identity.id),
              encryptedPassphrase: drift.Value(encrypted),
            ),
          );
      controller.dispose();
    }
  }

  Future<void> _delete(Identity identity) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete key?'),
        content: Text('Delete "${identity.name}"?'),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(appDatabaseProvider).deleteIdentity(identity.id);
      if (mounted && _editId == identity.id) {
        _closePanel();
      }
    }
  }

  void _syncSelectionBar() {
    final notifier = ref.read(selectionBarProvider.notifier);
    // Hidden screens in the IndexedStack stay alive; only the active
    // section may publish the bar.
    if (ref.read(appSectionProvider) != AppSection.keys) {
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
          // Icon only: the trash can already reads as "delete".
          label: 'Delete',
          danger: true,
          onTap: _deleteSelection,
        ),
      ],
      onClose: () => setState(multiSelected.clear),
    );
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
    ref.listen<String?>(keyEditorRequestProvider, (_, next) {
      if (next == null) return;
      ref.read(keyEditorRequestProvider.notifier).state = null;
      _openEditorById(next);
    });
    final identitiesAsync = ref.watch(identitiesProvider);

    return identitiesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (identities) {
        Identity? editing;
        if (_editId != null) {
          for (final identity in identities) {
            if (identity.id == _editId) {
              editing = identity;
              break;
            }
          }
          if (editing == null && _panelMode == _KeyPanelMode.manual) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _editId != null) {
                setState(() => _closePanel());
              }
            });
          }
        }

        final panelOpen = _panelMode != _KeyPanelMode.none;
        final q = _query.trim().toLowerCase();
        final filtered = q.isEmpty
            ? identities
            : identities
                  .where(
                    (id) =>
                        id.name.toLowerCase().contains(q) ||
                        id.comment.toLowerCase().contains(q) ||
                        id.publicKey.toLowerCase().contains(q),
                  )
                  .toList();

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
                                _editId = null;
                                _pendingImportPem = null;
                                _panelMode = _KeyPanelMode.manual;
                              }),
                              icon: const Icon(
                                Icons.vpn_key_outlined,
                                size: 16,
                              ),
                              label: const Text('New Key'),
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
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              onPressed: () => setState(
                                () => _panelMode = _KeyPanelMode.generate,
                              ),
                              icon: const Icon(Icons.autorenew, size: 16),
                              label: const Text('Generate Key'),
                              style: OutlinedButton.styleFrom(
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
                            child: identities.isEmpty
                                ? _EmptyState(
                                    onNewKey: () => setState(
                                      () => _panelMode = _KeyPanelMode.manual,
                                    ),
                                  )
                                : filtered.isEmpty
                                ? _NoResults()
                                : GridView.builder(
                                    controller: _scrollController,
                                    physics: bandScrollPhysics,
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      14,
                                      16,
                                      20,
                                    ),
                                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 300,
                                      mainAxisExtent: 60,
                                      mainAxisSpacing: 10,
                                      crossAxisSpacing: 10,
                                    ),
                                    itemCount: filtered.length,
                                    itemBuilder: (context, index) {
                                      final identity = filtered[index];
                                      return _KeyCard(
                                        key: bandCardKey(identity.id),
                                        identity: identity,
                                        selected: multiSelected.contains(
                                          identity.id,
                                        ),
                                        hasPassphrase: _encrypted.contains(
                                          identity.id,
                                        ),
                                        onSelect: () => _onKeyTap(identity),
                                        onSetPassphrase: () =>
                                            _setPassphrase(identity),
                                        onDelete: () => _delete(identity),
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
                  onTap: _closePanel,
                  child: const ColoredBox(color: Color(0x66000000)),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _panelMode == _KeyPanelMode.generate
                    ? KeyGeneratePanel(
                        onClose: _closePanel,
                        onGenerated: (id) => setState(() {
                          _editId = id;
                          _pendingImportPem = null;
                          _panelMode = _KeyPanelMode.manual;
                        }),
                      )
                    : KeyFormPanel(
                        identity: editing,
                        initialPrivateKey: _pendingImportPem,
                        onClose: _closePanel,
                        onDelete: editing == null
                            ? null
                            : () => _delete(editing!),
                      ),
              ),
            ],
          ],
        );
      },
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
        hintText: 'Search keys...',
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

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 40, color: AppColors.textFaint),
          SizedBox(height: 12),
          Text(
            'No keys match your search',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onNewKey;

  const _EmptyState({required this.onNewKey});

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
              Icons.vpn_key_outlined,
              size: 30,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No keys yet',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Add an existing SSH key or generate a new one.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onNewKey,
            icon: const Icon(Icons.vpn_key_outlined, size: 16),
            label: const Text('New Key'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyCard extends ConsumerStatefulWidget {
  final Identity identity;
  final bool selected;
  final bool hasPassphrase;
  final VoidCallback onSelect;
  final VoidCallback onSetPassphrase;
  final VoidCallback onDelete;

  const _KeyCard({
    super.key,
    required this.identity,
    required this.selected,
    required this.hasPassphrase,
    required this.onSelect,
    required this.onSetPassphrase,
    required this.onDelete,
  });

  @override
  ConsumerState<_KeyCard> createState() => _KeyCardState();
}

class _KeyCardState extends ConsumerState<_KeyCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final identity = widget.identity;
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        ref.read(hoveredEditTargetProvider.notifier).state =
            HoveredEditTarget(HoveredEditKind.key, identity.id);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        final t = HoveredEditTarget(HoveredEditKind.key, identity.id);
        if (ref.read(hoveredEditTargetProvider) == t) {
          ref.read(hoveredEditTargetProvider.notifier).state = null;
        }
      },
      child: InkWell(
        onTap: widget.onSelect,
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: widget.selected ? AppColors.surfaceAlt : AppColors.card,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: widget.selected ? AppColors.accentBorder : AppColors.border,
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
                  Icons.vpn_key,
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
                            identity.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (widget.hasPassphrase) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.lock,
                            size: 12,
                            color: AppColors.warning,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      identity.comment.isEmpty
                          ? _formatDate(identity.createdAt)
                          : identity.comment,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'JetBrainsMono',
                        color: AppColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (_hovered)
                _CardActionButton(
                  icon: Icons.edit_outlined,
                  tooltip: 'Edit key',
                  onTap: widget.onSelect,
                )
              else
                const SizedBox(width: 28),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: const [
        PopupMenuItem(
          value: 'edit',
          child: _MenuItemRow(icon: Icons.edit_outlined, label: 'Edit'),
        ),
        PopupMenuItem(
          value: 'passphrase',
          child: _MenuItemRow(
            icon: Icons.lock_outline,
            label: 'Set passphrase',
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: _MenuItemRow(icon: Icons.delete_outline, label: 'Delete'),
        ),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'edit':
        widget.onSelect();
      case 'passphrase':
        widget.onSetPassphrase();
      case 'delete':
        widget.onDelete();
    }
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}

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
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hovered ? AppColors.cardHover : AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _hovered
                    ? AppColors.accentBorder
                    : AppColors.border,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: _hovered ? AppColors.accent : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuItemRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuItemRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
