import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/db/database.dart';
import '../state/nav.dart';
import '../../core/sync/team_providers.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';
import '../widgets/band_selection.dart';
import '../widgets/multi_select_bar.dart';

/// Touch devices have no hover affordances or right-click: card taps open
/// the editor and long-presses open the context menu instead.
bool get _isTouch =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

class SnippetsScreen extends ConsumerStatefulWidget {
  const SnippetsScreen({super.key});

  @override
  ConsumerState<SnippetsScreen> createState() => _SnippetsScreenState();
}

class _SnippetsScreenState extends ConsumerState<SnippetsScreen>
    with BandSelection<SnippetsScreen> {
  final _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _query = '';
  String? _editSnippetId;
  bool _creating = false;
  bool _selectionBarScheduled = false;

  @override
  void initState() {
    super.initState();
    bandScrollController = _scrollController;
    _consumeRequests();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _consumeRequests() {
    _handleRequest(ref.read(snippetEditorRequestProvider));
  }

  void _handleRequest(SnippetEditorRequest? request) {
    if (request == null || !mounted) return;
    setState(() {
      _creating = request.snippetId == null;
      _editSnippetId = request.snippetId;
    });
  }

  void _close() {
    setState(() {
      _editSnippetId = null;
      _creating = false;
    });
  }

  void _onSnippetTap(Snippet snippet) {
    if (HardwareKeyboard.instance.isControlPressed) {
      setState(() {
        multiSelected.contains(snippet.id)
            ? multiSelected.remove(snippet.id)
            : multiSelected.add(snippet.id);
      });
    } else if (multiSelected.isNotEmpty) {
      setState(multiSelected.clear);
    } else if (_isTouch) {
      // No hover button or right-click on touch: a tap opens the editor
      // (long-press opens the context menu).
      showSnippetEditor(ref, snippet: snippet);
    }
  }

  Future<void> _deleteSelection() async {
    final snippets =
        ref.read(scopedSnippetsProvider).valueOrNull ?? const <Snippet>[];
    final selected =
        snippets.where((s) => multiSelected.contains(s.id)).toList();
    if (selected.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete snippets?'),
        content: Text('Delete ${selected.length} snippet(s)? This cannot '
            'be undone.'),
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
    for (final snippet in selected) {
      await db.deleteSnippet(snippet.id);
    }
    if (mounted) {
      setState(multiSelected.clear);
      if (_editSnippetId != null &&
          selected.any((s) => s.id == _editSnippetId)) {
        _close();
      }
    }
  }

  int _compare(Snippet a, Snippet b, SnippetSort sort) {
    switch (sort) {
      case SnippetSort.alphaAsc:
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      case SnippetSort.alphaDesc:
        return b.title.toLowerCase().compareTo(a.title.toLowerCase());
      case SnippetSort.newest:
        return _sortTime(b).compareTo(_sortTime(a));
      case SnippetSort.oldest:
        return _sortTime(a).compareTo(_sortTime(b));
    }
  }

  DateTime _sortTime(Snippet s) =>
      s.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  void _syncSelectionBar() {
    final notifier = ref.read(selectionBarProvider.notifier);
    // Hidden screens in the IndexedStack stay alive; only the active
    // section may publish the bar.
    if (ref.read(appSectionProvider) != AppSection.snippets) {
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
    ref.listen<SnippetEditorRequest?>(snippetEditorRequestProvider, (_, next) {
      if (next == null) return;
      ref.read(snippetEditorRequestProvider.notifier).state = null;
      _handleRequest(next);
    });

    final snippetsAsync = ref.watch(scopedSnippetsProvider);
    final sort = ref.watch(snippetSortProvider);

    return snippetsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (snippets) {
        Snippet? editing;
        if (_editSnippetId != null) {
          for (final snippet in snippets) {
            if (snippet.id == _editSnippetId) {
              editing = snippet;
              break;
            }
          }
          if (editing == null && !_creating) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _editSnippetId != null) {
                setState(() => _editSnippetId = null);
              }
            });
          }
        }

        final panelOpen = _creating || editing != null;
        final q = _query.trim().toLowerCase();
        final filtered = q.isEmpty
            ? List<Snippet>.of(snippets)
            : snippets
                  .where(
                    (s) =>
                        s.title.toLowerCase().contains(q) ||
                        s.command.toLowerCase().contains(q),
                  )
                  .toList();
        filtered.sort((a, b) => _compare(a, b, sort));

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
                              onPressed: () => showSnippetEditor(ref),
                              icon: const Icon(Icons.code, size: 16),
                              label: const Text('New snippet'),
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
                            _SortButton(),
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
                            child: snippets.isEmpty
                                ? _EmptyState(
                                    onCreate: () => showSnippetEditor(ref))
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
                                    gridDelegate:
                                        const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 300,
                                      mainAxisExtent: 60,
                                      mainAxisSpacing: 10,
                                      crossAxisSpacing: 10,
                                    ),
                                    itemCount: filtered.length,
                                    itemBuilder: (context, index) {
                                      final snippet = filtered[index];
                                      return _SnippetCard(
                                        key: bandCardKey(snippet.id),
                                        snippet: snippet,
                                        selected: multiSelected.contains(
                                          snippet.id,
                                        ),
                                        onTap: () => _onSnippetTap(snippet),
                                        onPaste: () =>
                                            _paste(context, ref, snippet),
                                        onRunAll: () =>
                                            _runAll(context, ref, snippet),
                                        onEdit: () => showSnippetEditor(
                                          ref,
                                          snippet: snippet,
                                        ),
                                        onCopy: () => _copy(context, snippet),
                                        onViewMore: () =>
                                            _viewMore(context, snippet),
                                        onDelete: () =>
                                            _delete(context, ref, snippet),
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
                child: SnippetEditorPanel(
                  snippet: editing,
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

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _paste(BuildContext context, WidgetRef ref, Snippet snippet) {
    final ok = ref
        .read(sessionManagerProvider)
        .pasteToActiveSession(snippet.command);
    _toast(
      context,
      ok
          ? 'Pasted into the active terminal'
          : 'No connected terminal to paste into',
    );
  }

  void _runAll(BuildContext context, WidgetRef ref, Snippet snippet) {
    final count = ref
        .read(sessionManagerProvider)
        .runInAllConnected(snippet.command);
    if (count == 0) {
      _toast(context, 'No connected terminals');
    }
  }

  Future<void> _copy(BuildContext context, Snippet snippet) async {
    await Clipboard.setData(ClipboardData(text: snippet.command));
    if (!context.mounted) return;
    _toast(context, 'Command copied to clipboard');
  }

  Future<void> _viewMore(BuildContext context, Snippet snippet) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.code, size: 18, color: AppColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                snippet.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
        content: Container(
          constraints: const BoxConstraints(minWidth: 480),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              snippet.command,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(),
            icon: const Icon(Icons.copy_outlined, size: 16),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    Snippet snippet,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete snippet?'),
        content: Text('Delete "${snippet.title}"?'),
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
      await ref.read(appDatabaseProvider).deleteSnippet(snippet.id);
    }
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
        hintText: 'Search snippets...',
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

/// Opens a menu with the available sort orders; the active one is checked.
/// Rendered as a real [OutlinedButton] so it matches the other toolbar
/// buttons (New snippet, New Key, Generate Key, ...).
class _SortButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(snippetSortProvider);
    return OutlinedButton.icon(
      onPressed: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        showMenu<SnippetSort>(
          context: context,
          position: RelativeRect.fromRect(
            Rect.fromPoints(
              box.localToGlobal(Offset.zero),
              box.localToGlobal(box.size.bottomRight(Offset.zero)),
            ),
            Offset.zero & overlay.size,
          ),
          items: [
            _SortItem(
              value: SnippetSort.alphaAsc,
              label: 'A-z',
              current: current,
            ),
            _SortItem(
              value: SnippetSort.alphaDesc,
              label: 'Z-a',
              current: current,
            ),
            _SortItem(
              value: SnippetSort.newest,
              label: 'Newest to oldest',
              current: current,
            ),
            _SortItem(
              value: SnippetSort.oldest,
              label: 'Oldest to newest',
              current: current,
            ),
          ],
        ).then((value) {
          if (value != null) {
            ref.read(snippetSortProvider.notifier).state = value;
          }
        });
      },
      icon: const Icon(Icons.sort, size: 16),
      label: const Text('Sort'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SortItem extends PopupMenuItem<SnippetSort> {
  _SortItem({
    required SnippetSort value,
    required String label,
    required SnippetSort current,
  }) : super(
         value: value,
         child: Row(
           children: [
             SizedBox(
               width: 22,
               child: value == current
                   ? Icon(Icons.check, size: 16, color: AppColors.accent)
                   : null,
             ),
             Text(label, style: const TextStyle(fontSize: 13)),
           ],
         ),
       );
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
            'No snippets match your search',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ],
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
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.accentBorder),
            ),
            child: Icon(Icons.code, size: 30, color: AppColors.accent),
          ),
          const SizedBox(height: 20),
          const Text(
            'No snippets yet',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            'Save reusable commands and run or paste them into any '
            'terminal session with one click.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.code, size: 16),
            label: const Text('New snippet'),
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

class _SnippetCard extends ConsumerStatefulWidget {
  final Snippet snippet;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onPaste;
  final VoidCallback onRunAll;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  final VoidCallback onViewMore;
  final VoidCallback onDelete;

  const _SnippetCard({
    super.key,
    required this.snippet,
    required this.selected,
    required this.onTap,
    required this.onPaste,
    required this.onRunAll,
    required this.onEdit,
    required this.onCopy,
    required this.onViewMore,
    required this.onDelete,
  });

  @override
  ConsumerState<_SnippetCard> createState() => _SnippetCardState();
}

class _SnippetCardState extends ConsumerState<_SnippetCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final snippet = widget.snippet;
    return Tooltip(
      message: snippet.command,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _hovered = true);
          ref.read(hoveredEditTargetProvider.notifier).state =
              HoveredEditTarget(HoveredEditKind.snippet, snippet.id);
        },
        onExit: (_) {
          setState(() => _hovered = false);
          final t = HoveredEditTarget(HoveredEditKind.snippet, snippet.id);
          if (ref.read(hoveredEditTargetProvider) == t) {
            ref.read(hoveredEditTargetProvider.notifier).state = null;
          }
        },
        child: GestureDetector(
          // Touch has no right-click: long-press opens the context menu.
          onLongPressStart: (details) =>
              _showContextMenu(context, details.globalPosition),
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
                  Icons.code,
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
                      snippet.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      snippet.command.replaceAll('\n', ' '),
                      maxLines: 1,
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
              // The edit button is always visible on touch (no hover).
              if (_hovered || _isTouch)
                _CardActionButton(
                  icon: Icons.edit_outlined,
                  tooltip: 'Edit snippet',
                  onTap: widget.onEdit,
                )
              else
                const SizedBox(width: 28),
            ],
          ),
        ),
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
          value: 'runAll',
          child: _MenuItemRow(
            icon: Icons.playlist_play,
            label: 'Run in all tabs',
          ),
        ),
        PopupMenuItem(
          value: 'paste',
          child: _MenuItemRow(icon: Icons.content_paste, label: 'Paste'),
        ),
        PopupMenuItem(
          value: 'copy',
          child: _MenuItemRow(icon: Icons.copy_outlined, label: 'Copy'),
        ),
        PopupMenuItem(
          value: 'viewMore',
          child: _MenuItemRow(
            icon: Icons.visibility_outlined,
            label: 'View more',
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: _MenuItemRow(icon: Icons.delete_outline, label: 'Remove'),
        ),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'edit':
        widget.onEdit();
      case 'runAll':
        widget.onRunAll();
      case 'paste':
        widget.onPaste();
      case 'copy':
        widget.onCopy();
      case 'viewMore':
        widget.onViewMore();
      case 'delete':
        widget.onDelete();
    }
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

/// Requests the snippets screen (or the terminal sidebar) to open the
/// snippet editor panel.
void showSnippetEditor(WidgetRef ref, {Snippet? snippet}) {
  ref.read(snippetEditorRequestProvider.notifier).state = SnippetEditorRequest(
    snippetId: snippet?.id,
  );
}

/// Right-hand editor panel for creating or editing a snippet.
class SnippetEditorPanel extends ConsumerStatefulWidget {
  final Snippet? snippet;
  final bool creating;
  final VoidCallback onClose;

  const SnippetEditorPanel({
    super.key,
    this.snippet,
    this.creating = false,
    required this.onClose,
  });

  @override
  ConsumerState<SnippetEditorPanel> createState() => _SnippetEditorPanelState();
}

class _SnippetEditorPanelState extends ConsumerState<SnippetEditorPanel> {
  late final TextEditingController _title;
  late final TextEditingController _command;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.snippet?.title ?? '');
    _command = TextEditingController(text: widget.snippet?.command ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _command.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final command = _command.text.trim();
    if (command.isEmpty) return;
    var title = _title.text.trim();
    if (title.isEmpty) {
      final firstLine = command.split('\n').first.trim();
      title = firstLine.isEmpty ? 'Untitled' : firstLine;
      if (title.length > 40) title = '${title.substring(0, 40)}…';
    }

    await ref
        .read(appDatabaseProvider)
        .upsertSnippet(
          SnippetsCompanion(
            id: drift.Value(widget.snippet?.id ?? const Uuid().v4()),
            title: drift.Value(title),
            command: drift.Value(command),
            createdAt: drift.Value(widget.snippet?.createdAt ?? DateTime.now()),
            updatedAt: drift.Value(DateTime.now()),
          ),
        );
    if (!mounted) return;
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Theme(
        data: theme.copyWith(
          textTheme: theme.textTheme.copyWith(
            bodyLarge: TextStyle(
              fontSize: 13,
              color: AppColors.textPrimary,
            ),
            bodyMedium: TextStyle(
              fontSize: 13,
              color: AppColors.textPrimary,
            ),
          ),
          inputDecorationTheme: theme.inputDecorationTheme.copyWith(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.creating ? 'New snippet' : 'Edit snippet',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _title,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _command,
                    maxLines: 10,
                    decoration: const InputDecoration(
                      labelText: 'Command',
                      hintText: 'e.g. docker ps --format "table {{.Names}}"',
                      alignLabelWithHint: true,
                    ),
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Save snippet'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(40),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
