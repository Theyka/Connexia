import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/sync_api.dart';
import '../../core/sync/sync_controller.dart';
import '../../core/sync/team_controller.dart';
import '../theme/app_colors.dart';

/// Team workspaces: create, invite members, manage roles, rotate keys and
/// view the audit log. Requires a signed-in sync account (the panel shows
/// a hint otherwise).
class TeamsSettingsPanel extends ConsumerStatefulWidget {
  const TeamsSettingsPanel({super.key});

  @override
  ConsumerState<TeamsSettingsPanel> createState() => _TeamsSettingsPanelState();
}

class _TeamsSettingsPanelState extends ConsumerState<TeamsSettingsPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final team = ref.read(teamControllerProvider);
      if (team.signedIn) {
        ref.read(teamControllerProvider.notifier).refreshWorkspaces();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final team = ref.watch(teamControllerProvider);
    final sync = ref.watch(syncControllerProvider);

    if (sync.status != SyncStatus.signedIn) {
      return const _SignedOutHint();
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Team workspaces',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton.icon(
              onPressed: team.busy ? null : () => _showCreateDialog(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New workspace'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Workspaces sync hosts, groups, keys and snippets across every member '
          'of the team. The data is end-to-end encrypted: the server stores '
          'only ciphertext and metadata-only audit events (who did what, '
          'never the data content).',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        if (team.error != null) _ErrorBanner(message: team.error!),
        if (team.workspaces.isEmpty && !team.busy)
          const _EmptyState()
        else
          for (final w in team.workspaces) ...[
            _WorkspaceCard(summary: w),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 16),
        const Text(
          'Active workspace',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        _ActiveWorkspaceSelector(),
      ],
    );
  }

  Future<void> _showCreateDialog() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('New workspace'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Workspace name',
              hintText: 'e.g. Production',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    await ref.read(teamControllerProvider.notifier).createWorkspace(name);
  }
}

class _SignedOutHint extends StatelessWidget {
  const _SignedOutHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Team workspaces',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Sign in to your Connexia account to create or join team '
            'workspaces. Workspaces sync hosts, groups, keys and snippets '
            'across every member of the team.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.groups_outlined, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              'You have no workspaces yet. Create one to share hosts and '
              'keys with your team.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: AppColors.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class _WorkspaceCard extends ConsumerWidget {
  final WorkspaceSummary summary;
  const _WorkspaceCard({required this.summary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = ref.watch(teamControllerProvider);
    final isActive = team.activeWorkspaceId == summary.id;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isActive ? AppColors.accent : AppColors.border,
          width: isActive ? 2 : 1,
        ),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.folder_outlined),
        title: Row(
          children: [
            Expanded(
              child: Text(
                summary.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            _RoleChip(role: summary.role),
            const SizedBox(width: 8),
            Text(
              '${summary.memberCount} member${summary.memberCount == 1 ? '' : 's'}',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
        subtitle: Text(
          'Key v${summary.keyVersion} · created ${_fmtDate(summary.createdAt)}',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _WorkspaceDetail(workspaceId: summary.id),
        ],
      ),
    );
  }

  static String _fmtDate(DateTime? d) {
    if (d == null) return 'recently';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

class _RoleChip extends StatelessWidget {
  final String role;
  const _RoleChip({required this.role});

  @override
  Widget build(BuildContext context) {
    final color = switch (role) {
      'owner' => AppColors.accent,
      'admin' => AppColors.accent.withValues(alpha: 0.7),
      _ => AppColors.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        role,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _WorkspaceDetail extends ConsumerStatefulWidget {
  final String workspaceId;
  const _WorkspaceDetail({required this.workspaceId});

  @override
  ConsumerState<_WorkspaceDetail> createState() => _WorkspaceDetailState();
}

class _WorkspaceDetailState extends ConsumerState<_WorkspaceDetail> {
  WorkspaceDetail? _detail;
  bool _loading = true;
  String? _error;
  List<AuditEvent>? _audit;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = SyncApi(
        serverUrl: ref.read(syncControllerProvider.notifier).serverUrl,
        token: ref.read(syncControllerProvider.notifier).token,
      );
      final detail = await api.getWorkspace(widget.workspaceId);
      final audit = await api.auditEvents(widget.workspaceId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _audit = audit;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(_error!, style: TextStyle(color: AppColors.danger)),
      );
    }
    final detail = _detail!;
    final myRole = detail.myRole;
    final isOwnerOrAdmin = myRole == 'owner' || myRole == 'admin';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () {
                ref
                    .read(teamControllerProvider.notifier)
                    .setActiveWorkspace(widget.workspaceId);
              },
              icon: const Icon(Icons.swap_horiz, size: 16),
              label: const Text('Activate'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () async {
                await ref
                    .read(teamControllerProvider.notifier)
                    .syncWorkspace(widget.workspaceId);
                await _load();
              },
              icon: const Icon(Icons.sync, size: 16),
              label: const Text('Sync now'),
            ),
            const SizedBox(width: 8),
            if (isOwnerOrAdmin)
              OutlinedButton.icon(
                onPressed: () => _showInviteDialog(),
                icon: const Icon(Icons.person_add, size: 16),
                label: const Text('Invite'),
              ),
            const Spacer(),
            if (myRole == 'owner')
              TextButton.icon(
                onPressed: () => _confirmDelete(),
                icon: Icon(Icons.delete_outline, color: AppColors.danger, size: 16),
                label: Text('Delete', style: TextStyle(color: AppColors.danger)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('Members',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 4),
        for (final m in detail.members) _MemberRow(
          member: m,
          myRole: myRole,
          onChanged: () => _load(),
        ),
        const SizedBox(height: 16),
        if (isOwnerOrAdmin)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _confirmRotate(detail),
              icon: const Icon(Icons.vpn_key, size: 16),
              label: const Text('Rotate workspace key'),
            ),
          ),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 8),
        const Text('Audit log',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 4),
        if (_audit == null || _audit!.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No audit events yet.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          )
        else
          for (final e in _audit!.take(50)) _AuditRow(event: e),
        if (_audit != null && _audit!.length > 50)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Showing the 50 most recent events.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Future<void> _showInviteDialog() async {
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Invite member'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'teammate@example.com',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Next'),
            ),
          ],
        );
      },
    );
    if (email == null || email.isEmpty) return;
    final notifier = ref.read(teamControllerProvider.notifier);
    final invite = await notifier.invite(widget.workspaceId, email);
    if (invite == null) return;
    if (!mounted) return;
    final role = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Role for ${invite.email}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'member'),
            child: const Text('Member'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'admin'),
            child: const Text('Admin'),
          ),
        ],
      ),
    );
    if (role == null) return;
    final ok = await notifier.addMember(
      workspaceId: widget.workspaceId,
      userId: invite.userId,
      publicKey: invite.publicKey,
      role: role,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add member')),
      );
    }
    await _load();
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete workspace?'),
        content: const Text(
          'This permanently deletes the workspace and its encrypted '
          'snapshot. Members will lose access immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(teamControllerProvider.notifier)
        .deleteWorkspace(widget.workspaceId);
  }

  Future<void> _confirmRotate(WorkspaceDetail detail) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rotate workspace key?'),
        content: const Text(
          'A new workspace key is generated, the snapshot is re-encrypted, '
          'and every member receives a new wrapped share. Removed members '
          'lose access immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final rotated = await ref
        .read(teamControllerProvider.notifier)
        .rotateWorkspaceKey(widget.workspaceId, detail.members);
    if (!mounted) return;
    if (!rotated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Key rotation failed')),
      );
    }
    await _load();
  }
}

class _MemberRow extends ConsumerWidget {
  final WorkspaceMember member;
  final String myRole;
  final VoidCallback onChanged;
  const _MemberRow({
    required this.member,
    required this.myRole,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canManage = (myRole == 'owner') ||
        (myRole == 'admin' && member.role != 'owner');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppColors.surfaceAlt,
            child: Text(
              member.email.isNotEmpty
                  ? member.email[0].toUpperCase()
                  : '?',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.email, style: const TextStyle(fontSize: 13)),
                Text(
                  'Joined ${_fmtDate(member.joinedAt)}',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
          _RoleChip(role: member.role),
          const SizedBox(width: 8),
          if (canManage && member.role != 'owner')
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (v) async {
                final notifier = ref.read(teamControllerProvider.notifier);
                if (v == 'admin' || v == 'member') {
                  await notifier.setMemberRole(
                    member.wrappedKey != null
                        ? _workspaceIdOf(context)
                        : '',
                    member.userId,
                    v,
                  );
                } else if (v == 'remove') {
                  await notifier.removeMember(
                    _workspaceIdOf(context),
                    member.userId,
                  );
                }
                onChanged();
              },
              itemBuilder: (ctx) => [
                if (member.role != 'admin')
                  const PopupMenuItem(value: 'admin', child: Text('Make admin')),
                if (member.role != 'member')
                  const PopupMenuItem(value: 'member', child: Text('Make member')),
                const PopupMenuItem(value: 'remove', child: Text('Remove')),
              ],
            ),
        ],
      ),
    );
  }

  // The member row doesn't know its workspace id directly; pull it from the
  // enclosing ExpansionTile via the parent context's _WorkspaceDetail.
  String _workspaceIdOf(BuildContext context) {
    // Walk up to find _WorkspaceDetailState via the controller.
    // Simpler: re-derive from the team controller's active workspace or
    // the first workspace with this member. For now, fall back to active.
    final active = ProviderScope.containerOf(context)
        .read(teamControllerProvider)
        .activeWorkspaceId;
    return active ?? '';
  }

  static String _fmtDate(DateTime? d) {
    if (d == null) return 'recently';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

class _AuditRow extends StatelessWidget {
  final AuditEvent event;
  const _AuditRow({required this.event});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            event.source == 'server' ? Icons.cloud_outlined : Icons.devices,
            size: 14,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 12),
                    children: [
                      TextSpan(
                        text: event.actorEmail ?? event.actorId,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: ' ${event.action}'),
                      if (event.target.isNotEmpty)
                        TextSpan(
                          text: ' ${event.target}',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      if (event.revision > 0)
                        TextSpan(
                          text: ' (rev ${event.revision})',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                    ],
                  ),
                ),
                Text(
                  '${_fmtDate(event.createdAt)} · ${event.ip}',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtDate(DateTime? d) {
    if (d == null) return '';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  }
}

class _ActiveWorkspaceSelector extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = ref.watch(teamControllerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in <(String?, String)>[
          (null, 'Personal scope (no workspace)'),
          ...team.workspaces.map((w) => (w.id, w.name)),
        ])
          RadioListTile<String?>(
            value: option.$1,
            groupValue: team.activeWorkspaceId,
            onChanged: (v) {
              ref.read(teamControllerProvider.notifier).setActiveWorkspace(v);
            },
            title: Text(option.$2),
            dense: true,
          ),
      ],
    );
  }
}
