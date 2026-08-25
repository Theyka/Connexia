import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/db/database.dart';
import '../state/connection_helpers.dart';
import '../state/nav.dart';
import '../../core/sync/team_providers.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';
import '../widgets/host_details_panel.dart';
import '../widgets/multi_select_bar.dart';

enum _DeleteGroupChoice { keepHosts, withHosts }

/// Editor overlay state for the hosts screen. Kept in a [ValueNotifier] so
/// opening/closing the editor panel rebuilds only the overlay (via
/// [ValueListenableBuilder]) and not the whole host/group card list, which
/// previously made the panel feel slow to open on large lists.
class _EditorState {
  final bool creating;
  final bool editing;
  final String? editHostId;
  final String? editingGroupId;
  final bool creatingGroup;
  final String? newHostGroupId;

  const _EditorState({
    this.creating = false,
    this.editing = false,
    this.editHostId,
    this.editingGroupId,
    this.creatingGroup = false,
    this.newHostGroupId,
  });
}

class HostsScreen extends ConsumerStatefulWidget {
  const HostsScreen({super.key});

  @override
  ConsumerState<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends ConsumerState<HostsScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _selectedId;
  String? _openGroupId;
  final _editorState = ValueNotifier<_EditorState?>(null);

  final Set<String> _multiSelected = {};
  final Map<String, GlobalKey> _cardKeys = {};
  final GlobalKey _bandStackKey = GlobalKey();
  final ScrollController _bandScrollController = ScrollController();
  Offset? _bandStart;
  Offset? _bandCurrent;
  bool _banding = false;
  bool _bandMoved = false;
  bool _selectionBarScheduled = false;
  Timer? _bandScrollTimer;
  double _bandScrollVelocity = 0;
  double _bandStartScrollOffset = 0;
  bool _bandScrolled = false;
  Timer? _bandArmTimer;
  Offset _bandArmPosition = Offset.zero;

  static String _hKey(String id) => 'h:$id';
  static String _gKey(String id) => 'g:$id';

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _consumeEditorRequests());
  }

  @override
  void dispose() {
    _bandArmTimer?.cancel();
    _bandScrollTimer?.cancel();
    _bandScrollController.dispose();
    _searchController.dispose();
    _editorState.dispose();
    super.dispose();
  }

  void _consumeEditorRequests() {
    _handleHostRequest(ref.read(hostEditorRequestProvider));
    _handleGroupRequest(ref.read(groupEditorRequestProvider));
  }

  @override
  Widget build(BuildContext context) {
    _scheduleSelectionBarSync();
    ref.listen<HostEditorRequest?>(hostEditorRequestProvider, (_, next) {
      if (next == null) return;
      ref.read(hostEditorRequestProvider.notifier).state = null;
      _handleHostRequest(next);
    });
    ref.listen<GroupEditorRequest?>(groupEditorRequestProvider, (_, next) {
      if (next == null) return;
      ref.read(groupEditorRequestProvider.notifier).state = null;
      _handleGroupRequest(next);
    });

    final hostsAsync = ref.watch(scopedHostsProvider);
    final groupsAsync = ref.watch(scopedGroupsProvider);
    final identitiesAsync = ref.watch(scopedIdentitiesProvider);

    return hostsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (hosts) => groupsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (groups) => identitiesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (identities) {
            Group? openGroup;
            if (_openGroupId != null) {
              for (final group in groups) {
                if (group.id == _openGroupId) {
                  openGroup = group;
                  break;
                }
              }
              if (openGroup == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _openGroupId != null) {
                    setState(() => _openGroupId = null);
                  }
                });
              }
            }

            final filtered = _filterHosts(hosts);
            final filteredGroups = _filterGroups(groups);

            return Stack(
              children: [
                Positioned.fill(
                  child: _hostsArea(
                    hosts: hosts,
                    filtered: filtered,
                    filteredGroups: filteredGroups,
                    groups: groups,
                    openGroup: openGroup,
                  ),
                ),
                Positioned.fill(
                  child: ValueListenableBuilder<_EditorState?>(
                    valueListenable: _editorState,
                    builder: (context, editorState, _) {
                      if (editorState == null) return const SizedBox.shrink();
                    Host? editingHost;
                    if (editorState.editHostId != null) {
                      for (final host in hosts) {
                        if (host.id == editorState.editHostId) {
                          editingHost = host;
                          break;
                        }
                      }
                      if (editingHost == null && !editorState.creating) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _closePanel();
                        });
                      }
                    }
                    Group? editingGroup;
                    if (editorState.editingGroupId != null) {
                      for (final group in groups) {
                        if (group.id == editorState.editingGroupId) {
                          editingGroup = group;
                          break;
                        }
                      }
                      if (editingGroup == null) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _closePanel();
                        });
                      }
                    }
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: _closePanel,
                            child: const ColoredBox(
                              color: Color(0x66000000),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          child: HostDetailsPanel(
                            host: editingHost,
                            editing: editorState.editing &&
                                editingHost != null,
                            creating: editorState.creating,
                            group: editingGroup,
                            groupCreating: editorState.creatingGroup,
                            groups: groups,
                            identities: identities,
                            initialGroupId: editorState.creating
                                ? editorState.newHostGroupId
                                : null,
                            onClose: _closePanel,
                          ),
                        ),
                      ],
                    );
                  },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _handleHostRequest(HostEditorRequest? request) {
    if (request == null || !mounted) return;
    _editorState.value = _EditorState(
      creating: request.hostId == null,
      editing: request.hostId != null,
      editHostId: request.hostId,
      newHostGroupId: request.groupId,
    );
  }

  void _handleGroupRequest(GroupEditorRequest? request) {
    if (request == null || !mounted) return;
    _editorState.value = _EditorState(
      creatingGroup: request.groupId == null,
      editingGroupId: request.groupId,
    );
  }

  void _closePanel() {
    _editorState.value = null;
  }

  Widget _hostsArea({
    required List<Host> hosts,
    required List<Host> filtered,
    required List<Group> filteredGroups,
    required List<Group> groups,
    required Group? openGroup,
  }) {
    return Column(
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
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SmallButton(
                    icon: Icons.add,
                    label: 'New host',
                    primary: true,
                    onTap: () => showHostEditor(ref, groupId: _openGroupId),
                  ),
                  const SizedBox(width: 8),
                  _SmallButton(
                    icon: Icons.create_new_folder_outlined,
                    label: 'New group',
                    onTap: () => showGroupEditor(ref),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (openGroup != null)
          _Breadcrumb(
            groupName: openGroup.name,
            onBack: () => setState(() => _openGroupId = null),
          ),
        Expanded(
          child: Stack(
            key: _bandStackKey,
            children: [
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _onBandPointerDown,
                  onPointerMove: _onBandPointerMove,
                  onPointerUp: _onBandPointerUp,
                  onPointerCancel: _onBandPointerCancel,
                  child: _contentList(
                    hosts: hosts,
                    filtered: filtered,
                    filteredGroups: filteredGroups,
                    groups: groups,
                    openGroup: openGroup,
                  ),
                ),
              ),
              if (_banding) ...[
                Positioned.fromRect(
                  rect: _bandRectLocal(),
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0x335B9DF7),
                        border: Border.all(color: const Color(0xFF5B9DF7)),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _contentList({
    required List<Host> hosts,
    required List<Host> filtered,
    required List<Group> filteredGroups,
    required List<Group> groups,
    required Group? openGroup,
  }) {
    final searching = _query.trim().isNotEmpty;

    // When searching from the top level, group hosts inside their group's
    // folder container instead of pasting the group name into each card.
    if (searching && openGroup == null) {
      return _searchGroupedResults(filtered: filtered, groups: groups, allHosts: hosts);
    }

    final slivers = <Widget>[];
    if (openGroup != null) {
      if (filtered.isEmpty) {
        slivers.add(
          SliverFillRemaining(
            hasScrollBody: false,
            child: searching
                ? const _NoResults()
                : _GroupEmptyState(
                    groupName: openGroup.name,
                    onAddHost: () => showHostEditor(ref, groupId: openGroup.id),
                  ),
          ),
        );
      } else {
        slivers.add(const SliverToBoxAdapter(child: _SectionHeader('Hosts')));
        slivers.add(_hostGrid(filtered));
      }
    } else {
      if (filteredGroups.isNotEmpty) {
        slivers.add(const SliverToBoxAdapter(child: _SectionHeader('Groups')));
        slivers.add(_groupGrid(filteredGroups, hosts));
      }
      if (filtered.isNotEmpty) {
        slivers.add(const SliverToBoxAdapter(child: _SectionHeader('Hosts')));
        slivers.add(_hostGrid(filtered));
      } else if (filteredGroups.isEmpty && groups.isEmpty && hosts.isEmpty) {
        slivers.add(
          const SliverFillRemaining(hasScrollBody: false, child: _EmptyState()),
        );
      } else if (searching) {
        slivers.add(
          const SliverFillRemaining(hasScrollBody: false, child: _NoResults()),
        );
      }
    }

    return CustomScrollView(
      controller: _bandScrollController,
      physics: _bandScrollPhysics,
      slivers: slivers,
    );
  }

  Widget _sectionPadding(Widget child) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
    sliver: child,
  );

  Widget _hostGrid(List<Host> hosts) {
    return _sectionPadding(
      SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 300,
          mainAxisExtent: 64,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final host = hosts[index];
          return _HostCard(
            key: _cardKey(_hKey(host.id)),
            host: host,
            selected: _multiSelected.contains(_hKey(host.id)) ||
                (_multiSelected.isEmpty && host.id == _selectedId),
            inSelection: _multiSelected.contains(_hKey(host.id)),
            canConnectSelection: _selectedHostIds().isNotEmpty,
            onSelect: () => _onHostTap(host),
            onConnectSelection: _connectSelection,
            onDeleteSelection: _deleteSelection,
          );
        }, childCount: hosts.length),
      ),
    );
  }

  /// When searching at the top level, the Groups section shows only the
  /// groups that contain at least one matching host (with their default
  /// folder cards, same look as when nothing is searched), and the Hosts
  /// section shows the matching hosts.
  Widget _searchGroupedResults({
    required List<Host> filtered,
    required List<Group> groups,
    required List<Host> allHosts,
  }) {
    final slivers = <Widget>[];

    final matchedGroupIds = filtered.map((h) => h.groupId).whereType<String>().toSet();
    final matchedGroups = [
      for (final group in groups)
        if (matchedGroupIds.contains(group.id)) group,
    ];

    if (matchedGroups.isNotEmpty) {
      slivers.add(const SliverToBoxAdapter(child: _SectionHeader('Groups')));
      slivers.add(_groupGrid(matchedGroups, allHosts));
    }

    if (filtered.isNotEmpty) {
      slivers.add(const SliverToBoxAdapter(child: _SectionHeader('Hosts')));
      slivers.add(_hostGrid(filtered));
    }

    if (slivers.isEmpty) {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: _NoResults(),
      ));
    }

    return CustomScrollView(
      controller: _bandScrollController,
      physics: _bandScrollPhysics,
      slivers: slivers,
    );
  }

  Widget _groupGrid(List<Group> groups, List<Host> hosts) {
    return _sectionPadding(
      SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 300,
          mainAxisExtent: 64,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final group = groups[index];
          final count = hosts.where((h) => h.groupId == group.id).length;
          final key = _gKey(group.id);
          final multi = _multiSelected.contains(key);
          return _GroupCard(
            key: _cardKey(key),
            group: group,
            hostCount: count,
            selected:
                multi || (_multiSelected.isEmpty && group.id == _selectedId),
            inSelection: multi,
            canConnectSelection: _selectedHostIds().isNotEmpty,
            onSelect: () => _onGroupTap(group),
            onConnectAll: () => _connectAllInGroup(group),
            onConnectSelection: _connectSelection,
            onDeleteSelection: _deleteSelection,
            onOpen: () => setState(() {
              _openGroupId = group.id;
              _selectedId = null;
              _multiSelected.clear();
            }),
            onEdit: () => showGroupEditor(ref, group: group),
            onDelete: () async {
              final choice = await _confirmDeleteGroup(context, group);
              if (choice == null || !mounted) return;
              final db = ref.read(appDatabaseProvider);
              if (choice == _DeleteGroupChoice.withHosts) {
                await db.deleteHostsInGroup(group.id);
              }
              await db.deleteGroup(group.id);
              if (mounted && _openGroupId == group.id) {
                setState(() => _openGroupId = null);
              }
            },
          );
        }, childCount: groups.length),
      ),
    );
  }

  Future<_DeleteGroupChoice?> _confirmDeleteGroup(
    BuildContext context,
    Group group,
  ) {
    return showDialog<_DeleteGroupChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete group?'),
        content: Text(
          'What should happen to hosts inside "${group.name}"?',
        ),
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: () =>
                Navigator.of(context).pop(_DeleteGroupChoice.keepHosts),
            child: const Text('Delete, keep hosts'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: () =>
                Navigator.of(context).pop(_DeleteGroupChoice.withHosts),
            child: const Text('Delete with hosts'),
          ),
        ],
      ),
    );
  }

  List<Host> _filterHosts(List<Host> hosts) {
    final q = _query.trim().toLowerCase();
    return hosts.where((h) {
      if (_openGroupId != null && h.groupId != _openGroupId) return false;
      if (q.isEmpty) return true;
      return h.name.toLowerCase().contains(q) ||
          h.address.toLowerCase().contains(q) ||
          h.username.toLowerCase().contains(q) ||
          h.tags.toLowerCase().contains(q);
    }).toList();
  }

  List<Group> _filterGroups(List<Group> groups) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return groups;
    return groups
        .where((g) => g.name.toLowerCase().contains(q))
        .toList();
  }

  GlobalKey _cardKey(String key) =>
      _cardKeys.putIfAbsent(key, () => GlobalKey());

  bool _pointOverCard(Offset globalPosition) {
    for (final key in _cardKeys.values) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final local = box.globalToLocal(globalPosition);
      if (local.dx >= 0 &&
          local.dy >= 0 &&
          local.dx <= box.size.width &&
          local.dy <= box.size.height) {
        return true;
      }
    }
    return false;
  }

  Rect _bandRectLocal() {
    final box = _bandStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _bandStart == null || _bandCurrent == null) {
      return Rect.zero;
    }
    final a = box.globalToLocal(_bandStart!);
    final b = box.globalToLocal(_bandCurrent!);
    return Rect.fromPoints(a, b);
  }

  void _onBandPointerDown(PointerDownEvent event) {
    if ((event.buttons & 1) == 0) return;
    if (_pointOverCard(event.position)) return;
    if (_isTouch) {
      // Touch devices arm the band with a long press so ordinary
      // scrolling never starts a rubber-band by accident.
      _bandArmPosition = event.position;
      _bandArmTimer?.cancel();
      _bandArmTimer = Timer(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        _startBand(_bandArmPosition);
      });
      return;
    }
    _startBand(event.position);
  }

  void _startBand(Offset position) {
    _bandArmTimer?.cancel();
    _bandArmTimer = null;
    _bandStart = position;
    _bandCurrent = position;
    _bandMoved = false;
    _banding = true;
    _bandScrolled = false;
    _bandStartScrollOffset = _bandScrollController.hasClients
        ? _bandScrollController.position.pixels
        : 0;
    setState(() {});
  }

  void _cancelBandArm() {
    _bandArmTimer?.cancel();
    _bandArmTimer = null;
  }

  void _onBandPointerMove(PointerMoveEvent event) {
    if (!_banding) {
      if (_bandArmTimer != null &&
          (event.position - _bandArmPosition).distance > 18) {
        // The finger moved before the long press completed: a scroll.
        _cancelBandArm();
      }
      return;
    }
    if (_bandStart == null) return;
    _updateBandScrollVelocity(event.position);
    if ((event.position - _bandStart!).distance > 4) {
      _bandMoved = true;
      _bandCurrent = event.position;
      _applyBandHits();
    }
  }

  void _onBandPointerCancel(PointerCancelEvent event) {
    _cancelBandArm();
    _bandScrollTimer?.cancel();
    _bandScrollTimer = null;
    _bandScrollVelocity = 0;
    if (!_banding) return;
    _banding = false;
    _bandStart = null;
    _bandCurrent = null;
    setState(() {});
  }

  void _applyBandHits() {
    if (_bandScrollController.hasClients &&
        _bandScrollController.position.pixels != _bandStartScrollOffset) {
      _bandScrolled = true;
    }
    final replace =
        !_bandScrolled && !HardwareKeyboard.instance.isControlPressed;
    final next = _bandHitCards();
    final newSet = replace ? next : {..._multiSelected, ...next};
    if (!setEquals(newSet, _multiSelected)) {
      setState(() {
        _multiSelected
          ..clear()
          ..addAll(newSet);
      });
    } else {
      setState(() {});
    }
  }

  void _updateBandScrollVelocity(Offset position) {
    final box = _bandStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(position);
    const edge = 48.0;
    final double velocity;
    if (local.dy < edge) {
      velocity = -(edge - local.dy) / edge * 14.0;
    } else if (local.dy > box.size.height - edge) {
      velocity = (local.dy - (box.size.height - edge)) / edge * 14.0;
    } else {
      velocity = 0;
    }
    if (velocity == _bandScrollVelocity) return;
    _bandScrollVelocity = velocity;
    if (velocity == 0) {
      _bandScrollTimer?.cancel();
      _bandScrollTimer = null;
      return;
    }
    _bandScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _bandScrollTick(),
    );
  }

  void _bandScrollTick() {
    if (!_banding ||
        !_bandScrollController.hasClients ||
        _bandScrollVelocity == 0) {
      return;
    }
    final position = _bandScrollController.position;
    final target = (position.pixels + _bandScrollVelocity)
        .clamp(0.0, position.maxScrollExtent);
    if (target == position.pixels) return;
    _bandScrollController.jumpTo(target);
    _applyBandHits();
  }

  void _onBandPointerUp(PointerUpEvent event) {
    _cancelBandArm();
    _bandScrollTimer?.cancel();
    _bandScrollTimer = null;
    _bandScrollVelocity = 0;
    if (!_banding) return;
    _banding = false;
    _bandStart = null;
    _bandCurrent = null;
    if (!_bandMoved && _multiSelected.isNotEmpty) {
      setState(_multiSelected.clear);
    } else if (_bandMoved) {
      setState(() {});
    }
  }

  Set<String> _bandHitCards() {
    if (_bandStart == null || _bandCurrent == null) return {};
    var rect = Rect.fromPoints(_bandStart!, _bandCurrent!);
    if (_bandScrollController.hasClients) {
      final delta =
          _bandScrollController.position.pixels - _bandStartScrollOffset;
      if (delta > 0) {
        rect = Rect.fromLTRB(
          rect.left,
          double.negativeInfinity,
          rect.right,
          rect.bottom,
        );
      } else if (delta < 0) {
        rect = Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right,
          double.infinity,
        );
      }
    }
    final hits = <String>{};
    for (final entry in _cardKeys.entries) {
      final box =
          entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final cardRect = box.localToGlobal(Offset.zero) & box.size;
      if (cardRect.overlaps(rect)) hits.add(entry.key);
    }
    return hits;
  }

  void _onHostTap(Host host) {
    final key = _hKey(host.id);
    if (HardwareKeyboard.instance.isControlPressed) {
      setState(() {
        _multiSelected.contains(key)
            ? _multiSelected.remove(key)
            : _multiSelected.add(key);
      });
    } else if (_multiSelected.isNotEmpty) {
      setState(() {
        _multiSelected.clear();
        _selectedId = host.id;
      });
    } else if (_isTouch) {
      // No hover or right-click on touch devices: a tap opens the editor
      // (long-press still opens the context menu).
      setState(() => _selectedId = host.id);
      ref.read(hostEditorRequestProvider.notifier).state =
          HostEditorRequest(hostId: host.id);
    } else {
      setState(() => _selectedId = host.id);
    }
  }

  static bool get _isTouch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  ScrollPhysics? get _bandScrollPhysics =>
      _isTouch && _banding ? const NeverScrollableScrollPhysics() : null;

  void _onGroupTap(Group group) {
    final key = _gKey(group.id);
    if (HardwareKeyboard.instance.isControlPressed) {
      setState(() {
        _multiSelected.contains(key)
            ? _multiSelected.remove(key)
            : _multiSelected.add(key);
      });
    } else if (_multiSelected.isNotEmpty) {
      setState(() {
        _multiSelected.clear();
        _selectedId = group.id;
      });
    } else {
      setState(() => _selectedId = group.id);
    }
  }

  /// Hosts reachable from the current selection: directly selected hosts
  /// plus every host inside selected groups. Deduplicated so a host is never
  /// connected twice when both it and its group are selected.
  Set<String> _selectedHostIds() {
    final hosts = ref.read(scopedHostsProvider).valueOrNull ?? const <Host>[];
    final ids = <String>{};
    for (final key in _multiSelected) {
      if (key.startsWith('h:')) {
        ids.add(key.substring(2));
      } else if (key.startsWith('g:')) {
        final groupId = key.substring(2);
        for (final host in hosts) {
          if (host.groupId == groupId) ids.add(host.id);
        }
      }
    }
    return ids;
  }

  void _connectSelection() {
    final hosts = ref.read(scopedHostsProvider).valueOrNull ?? const <Host>[];
    final ids = _selectedHostIds();
    for (final host in hosts) {
      if (!ids.contains(host.id)) continue;
      try {
        connectSavedHost(context, ref, host);
      } catch (_) {
        // A single host failing to connect must not break the batch.
      }
    }
  }

  void _connectAllInGroup(Group group) {
    // Mark the group as the active selection (same as left-clicking it) so
    // the card stays highlighted after the right-click "Connect to all".
    setState(() {
      _selectedId = group.id;
      _multiSelected.clear();
    });
    final hosts = ref.read(scopedHostsProvider).valueOrNull ?? const <Host>[];
    for (final host in hosts) {
      if (host.groupId != group.id) continue;
      try {
        connectSavedHost(context, ref, host);
      } catch (_) {
        // A single host failing to connect must not break the batch.
      }
    }
  }

  Future<void> _deleteSelection() {
    return _deleteSelected(
      ref.read(scopedHostsProvider).valueOrNull ?? const [],
      ref.read(scopedGroupsProvider).valueOrNull ?? const [],
    );
  }

  Future<void> _deleteSelected(
    List<Host> hosts,
    List<Group> groups,
  ) async {
    final selectedHosts = hosts
        .where((h) => _multiSelected.contains(_hKey(h.id)))
        .toList();
    final selectedGroups = groups
        .where((g) => _multiSelected.contains(_gKey(g.id)))
        .toList();
    if (selectedHosts.isEmpty && selectedGroups.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete selection?'),
        content: Text(
          selectedGroups.isEmpty
              ? 'Delete ${selectedHosts.length} host(s)? This cannot be undone.'
              : 'Delete ${selectedGroups.length} group(s) and '
                  '${selectedHosts.length} host(s)? Hosts in groups stay, '
                  'but lose their group. This cannot be undone.',
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final db = ref.read(appDatabaseProvider);
    for (final host in selectedHosts) {
      await db.deleteHost(host.id);
    }
    for (final group in selectedGroups) {
      await db.deleteGroup(group.id);
      if (mounted && _openGroupId == group.id) {
        setState(() => _openGroupId = null);
      }
    }
    if (mounted) {
      setState(_multiSelected.clear);
    }
  }

  /// Writes the selection bar to the shared provider. Never called during
  /// build - owners schedule it post-frame so a mid-build provider write
  /// cannot mark the shell dirty inside its own build.
  void _syncSelectionBar() {
    final notifier = ref.read(selectionBarProvider.notifier);
    // Hidden screens in the IndexedStack stay alive; only the active
    // section may publish the bar.
    if (ref.read(appSectionProvider) != AppSection.hosts) {
      if (notifier.state != null) notifier.state = null;
      return;
    }
    if (_multiSelected.isEmpty) {
      if (notifier.state != null) notifier.state = null;
      return;
    }
    final connectable = _selectedHostIds().length;
    notifier.state = SelectionBarData(
      count: _multiSelected.length,
      actions: [
        MultiSelectAction(
          icon: Icons.terminal,
          label: 'Connect',
          onTap: connectable == 0 ? null : _connectSelection,
        ),
        MultiSelectAction(
          icon: Icons.delete_outline,
          label: 'Delete',
          danger: true,
          onTap: _deleteSelection,
        ),
      ],
      onClose: () => setState(_multiSelected.clear),
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
}

class _SmallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;

  const _SmallButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    if (primary) {
      return FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 15),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
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
        hintText: 'Search hosts, groups, addresses, tags...',
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

class _Breadcrumb extends StatelessWidget {
  final String groupName;
  final VoidCallback onBack;

  const _Breadcrumb({required this.groupName, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            InkWell(
              onTap: onBack,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.arrow_back_ios_new,
                      size: 13,
                      color: AppColors.textSecondary,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Groups',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: AppColors.textFaint,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                groupName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: AppColors.textFaint,
        ),
      ),
    );
  }
}

class _GroupCard extends ConsumerStatefulWidget {
  final Group group;
  final int hostCount;
  final bool selected;

  /// Whether this card is part of the current multi-selection.
  final bool inSelection;
  final bool canConnectSelection;
  final VoidCallback onSelect;

  /// Connects every host inside this group.
  final VoidCallback onConnectAll;

  /// Connects the entire multi-selection (deduplicated).
  final VoidCallback onConnectSelection;

  /// Deletes the entire multi-selection.
  final VoidCallback onDeleteSelection;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _GroupCard({
    super.key,
    required this.group,
    required this.hostCount,
    required this.selected,
    required this.inSelection,
    required this.canConnectSelection,
    required this.onSelect,
    required this.onConnectAll,
    required this.onConnectSelection,
    required this.onDeleteSelection,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  ConsumerState<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends ConsumerState<_GroupCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        ref.read(hoveredEditTargetProvider.notifier).state =
            HoveredEditTarget(HoveredEditKind.group, group.id);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        final t = HoveredEditTarget(HoveredEditKind.group, group.id);
        if (ref.read(hoveredEditTargetProvider) == t) {
          ref.read(hoveredEditTargetProvider.notifier).state = null;
        }
      },
      child: GestureDetector(
        onLongPressStart: (details) =>
            _showContextMenu(context, details.globalPosition),
        child: InkWell(
          onTap: widget.onSelect,
          onDoubleTap: widget.onOpen,
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
              width: widget.selected ? 1.4 : 1,
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
                  Icons.folder_outlined,
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
                      group.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.hostCount == 1
                          ? '1 host'
                          : '${widget.hostCount} hosts',
                      style: TextStyle(
                        fontSize: 11,
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
                  tooltip: 'Edit Group',
                  onTap: widget.onEdit,
                )
              else
                const SizedBox(width: 28),
            ],
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
      items: [
        if (widget.inSelection)
          if (widget.canConnectSelection)
            const PopupMenuItem(
              value: 'connectSelection',
              child: _MenuItemRow(
                icon: Icons.play_arrow_outlined,
                label: 'Connect selection',
              ),
            ),
        if (widget.inSelection)
          const PopupMenuItem(
            value: 'deleteSelection',
            child: _MenuItemRow(
              icon: Icons.delete_outline,
              label: 'Delete selection',
            ),
          )
        else ...[
          const PopupMenuItem(
            value: 'connectAll',
            child: _MenuItemRow(
              icon: Icons.play_arrow_outlined,
              label: 'Connect to all hosts',
            ),
          ),
          const PopupMenuItem(
            value: 'open',
            child: _MenuItemRow(
              icon: Icons.folder_open_outlined,
              label: 'Open',
            ),
          ),
          const PopupMenuItem(
            value: 'rename',
            child: _MenuItemRow(icon: Icons.edit_outlined, label: 'Rename'),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: _MenuItemRow(icon: Icons.delete_outline, label: 'Delete'),
          ),
        ],
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'connectAll':
        widget.onConnectAll();
      case 'connectSelection':
        widget.onConnectSelection();
      case 'deleteSelection':
        widget.onDeleteSelection();
      case 'open':
        widget.onOpen();
      case 'rename':
        widget.onEdit();
      case 'delete':
        widget.onDelete();
    }
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
              size: 13.5,
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

class _HostCard extends ConsumerStatefulWidget {
  final Host host;
  final bool selected;
  final bool inSelection;
  final bool canConnectSelection;
  final VoidCallback onSelect;

  /// Connects the entire multi-selection (deduplicated).
  final VoidCallback onConnectSelection;

  /// Deletes the entire multi-selection.
  final VoidCallback onDeleteSelection;

  const _HostCard({
    super.key,
    required this.host,
    required this.selected,
    required this.inSelection,
    required this.canConnectSelection,
    required this.onSelect,
    required this.onConnectSelection,
    required this.onDeleteSelection,
  });

  @override
  ConsumerState<_HostCard> createState() => _HostCardState();
}

class _HostCardState extends ConsumerState<_HostCard> {
  bool _hovered = false;

  Host get host => widget.host;

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final accent = host.color != null ? Color(host.color!) : AppColors.accent;

    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        ref.read(hoveredEditTargetProvider.notifier).state =
            HoveredEditTarget(HoveredEditKind.host, host.id);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        final t = HoveredEditTarget(HoveredEditKind.host, host.id);
        if (ref.read(hoveredEditTargetProvider) == t) {
          ref.read(hoveredEditTargetProvider.notifier).state = null;
        }
      },
      child: GestureDetector(
        onLongPressStart: (details) =>
            _showContextMenu(context, ref, details.globalPosition),
        child: InkWell(
          onTap: widget.onSelect,
          onDoubleTap: () => connectSavedHost(context, ref, host),
          onSecondaryTapDown: (details) =>
              _showContextMenu(context, ref, details.globalPosition),
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
              width: widget.selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Tooltip(
                  message: host.os ?? 'Host',
                  waitDuration: const Duration(milliseconds: 600),
                  child: Icon(
                    osIcon(host.os),
                    size: 15,
                    color: accent,
                  ),
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
                            host.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (host.favorite) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.star,
                            size: 12,
                            color: AppColors.warning,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Flexible(
                      child: Text(
                        host.username.isNotEmpty
                            ? '${host.username}@${host.address}'
                            : host.address,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'JetBrainsMono',
                          color: AppColors.textFaint,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (_hovered)
                _CardActionButton(
                  icon: Icons.edit_outlined,
                  tooltip: 'Edit host',
                  onTap: () =>
                      ref.read(hostEditorRequestProvider.notifier).state =
                          HostEditorRequest(hostId: host.id),
                )
              else
                const SizedBox(width: 28),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) async {
    final action = await showContextMenuAt<String>(
      context: context,
      globalPosition: position,
      items: widget.inSelection
          ? [
              if (widget.canConnectSelection)
                const PopupMenuItem(
                  value: 'connectSelection',
                  child: _MenuItemRow(
                    icon: Icons.play_arrow_outlined,
                    label: 'Connect selection',
                  ),
                ),
              const PopupMenuItem(
                value: 'deleteSelection',
                child: _MenuItemRow(
                  icon: Icons.delete_outline,
                  label: 'Delete selection',
                ),
              ),
            ]
          : const [
              PopupMenuItem(
                value: 'connect',
                child: _MenuItemRow(
                  icon: Icons.play_arrow_outlined,
                  label: 'Connect',
                ),
              ),
              PopupMenuItem(
                value: 'edit',
                child: _MenuItemRow(icon: Icons.edit_outlined, label: 'Edit'),
              ),
              PopupMenuItem(
                value: 'duplicate',
                child: _MenuItemRow(
                  icon: Icons.content_copy_outlined,
                  label: 'Duplicate',
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: _MenuItemRow(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                ),
              ),
            ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'connectSelection':
        widget.onConnectSelection();
      case 'deleteSelection':
        widget.onDeleteSelection();
      case 'connect':
        await connectSavedHost(context, ref, host);
      case 'edit':
        ref.read(hostEditorRequestProvider.notifier).state = HostEditorRequest(
          hostId: host.id,
        );
      case 'duplicate':
        await ref
            .read(appDatabaseProvider)
            .upsertHost(
              HostsCompanion.insert(
                id: const Uuid().v4(),
                name: '${host.name} (copy)',
                address: host.address,
                username: host.username,
                port: drift.Value(host.port),
                authType: drift.Value(host.authType),
                keyId: drift.Value(host.keyId),
                encryptedPassword: drift.Value(host.encryptedPassword),
                groupId: drift.Value(host.groupId),
                tags: drift.Value(host.tags),
                color: drift.Value(host.color),
                notes: drift.Value(host.notes),
                favorite: drift.Value(false),
              ),
            );
      case 'delete':
        await _confirmDelete(context, ref);
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete host?'),
        content: Text('Delete "${host.name}"? This cannot be undone.'),
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
      await ref.read(appDatabaseProvider).deleteHost(host.id);
    }
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              Icons.dns_outlined,
              size: 30,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No hosts yet',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Add your first host to start connecting.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => showHostEditor(ref),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add your first host'),
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

class _GroupEmptyState extends StatelessWidget {
  final String groupName;
  final VoidCallback onAddHost;

  const _GroupEmptyState({required this.groupName, required this.onAddHost});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.folder_open_outlined,
              size: 26,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '"$groupName" is empty',
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Add a host to this group to see it here.',
            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onAddHost,
            icon: const Icon(Icons.add, size: 15),
            label: const Text('New host in this group'),
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

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 40, color: AppColors.textFaint),
          const SizedBox(height: 12),
          Text(
            'No hosts match your search',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Maps a detected OS string to a brand icon for host cards.
IconData osIcon(String? os) {
  if (os == null) return Icons.dns_outlined;
  final lower = os.toLowerCase();
  if (lower.contains('windows') || lower.contains('mingw') || lower.contains('cygwin') || lower.contains('msys')) {
    return FontAwesomeIcons.windows.data;
  }
  if (lower.contains('mac') || lower.contains('darwin')) {
    return FontAwesomeIcons.apple.data;
  }
  if (lower.contains('ubuntu')) return FontAwesomeIcons.ubuntu.data;
  if (lower.contains('debian')) return FontAwesomeIcons.debian.data;
  if (lower.contains('fedora')) return FontAwesomeIcons.fedora.data;
  if (lower.contains('arch')) return FontAwesomeIcons.linux.data;
  if (lower.contains('centos')) return FontAwesomeIcons.centos.data;
  if (lower.contains('red hat')) return FontAwesomeIcons.redhat.data;
  if (lower.contains('freebsd')) return FontAwesomeIcons.freebsd.data;
  if (lower.contains('alpine')) return FontAwesomeIcons.mountainSun.data;
  if (lower.contains('android')) return FontAwesomeIcons.android.data;
  if (lower.contains('linux')) return FontAwesomeIcons.linux.data;
  return Icons.dns_outlined;
}
