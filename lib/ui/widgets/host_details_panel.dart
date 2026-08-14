import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/db/database.dart';
import '../state/connection_helpers.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import 'key_select_field.dart';

/// Right-hand details panel for the hosts section. Shows either a read-only
/// summary of the selected host, the edit/create form for hosts or groups,
/// or an empty prompt.
class HostDetailsPanel extends ConsumerStatefulWidget {
  final Host? host;
  final bool editing;
  final bool creating;
  final Group? group;
  final bool groupCreating;
  final List<Group> groups;
  final List<Identity> identities;
  final String? initialGroupId;
  final VoidCallback onClose;

  const HostDetailsPanel({
    super.key,
    this.host,
    this.editing = false,
    this.creating = false,
    this.group,
    this.groupCreating = false,
    required this.groups,
    required this.identities,
    this.initialGroupId,
    required this.onClose,
  });

  @override
  ConsumerState<HostDetailsPanel> createState() => _HostDetailsPanelState();
}

class _HostDetailsPanelState extends ConsumerState<HostDetailsPanel> {
  @override
  Widget build(BuildContext context) {
    if (widget.groupCreating || widget.group != null) {
      return _GroupFormPanel(
        group: widget.group,
        identities: widget.identities,
        onSaved: widget.onClose,
      );
    }
    if (widget.creating || (widget.editing && widget.host != null)) {
      return _HostFormPanel(
        host: widget.host,
        groups: widget.groups,
        identities: widget.identities,
        initialGroupId: widget.initialGroupId,
        onSaved: widget.onClose,
      );
    }
    return const _PanelScaffold(child: SizedBox.shrink());
  }
}

class _PanelScaffold extends StatelessWidget {
  final Widget child;

  const _PanelScaffold({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 320),
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
        child: child,
      ),
    );
  }
}

class _SaveStatusLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SaveStatusLabel({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: color),
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _SectionCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Icon(icon, size: 15, color: AppColors.accent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

class _HostFormPanel extends ConsumerStatefulWidget {
  final Host? host;
  final List<Group> groups;
  final List<Identity> identities;
  final String? initialGroupId;
  final VoidCallback onSaved;

  const _HostFormPanel({
    required this.host,
    required this.groups,
    required this.identities,
    required this.onSaved,
    this.initialGroupId,
  });

  @override
  ConsumerState<_HostFormPanel> createState() => _HostFormPanelState();
}

class _HostFormPanelState extends ConsumerState<_HostFormPanel> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _tags;

  late String _authType;
  String? _keyId;
  String? _groupId;
  bool _savePassword = true;
  bool _showPassword = false;

  bool _initializing = true;
  Timer? _saveTimer;
  bool _saving = false;
  bool _justSaved = false;
  late final String _draftId;

  bool get _isEditing => widget.host != null;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    _draftId = host?.id ?? const Uuid().v4();
    _name = TextEditingController(text: host?.name ?? '');
    _address = TextEditingController(text: host?.address ?? '');
    _port = TextEditingController(text: (host?.port ?? 22).toString());
    _username = TextEditingController(text: host?.username ?? '');
    _password = TextEditingController();
    _tags = TextEditingController(text: host?.tags ?? '');

    _authType = host?.authType ?? 'password';
    _keyId = host?.keyId;
    _groupId = host?.groupId ?? widget.initialGroupId;

    for (final controller in [_name, _address, _port, _username, _password, _tags]) {
      controller.addListener(_onFormChanged);
    }

    if (host == null) {
      _applyGroupDefaults().whenComplete(() {
        _initializing = false;
        if (mounted) _scheduleSave();
      });
    } else {
      _initializing = false;
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final controller in [_name, _address, _port, _username, _password, _tags]) {
      controller.removeListener(_onFormChanged);
    }
    _name.dispose();
    _address.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _tags.dispose();
    super.dispose();
  }

  void _onFormChanged() {
    if (_initializing) return;
    setState(() => _justSaved = false);
    _scheduleSave();
  }

  void _markDirty() {
    if (_initializing) return;
    setState(() => _justSaved = false);
    _scheduleSave();
  }

  /// Debounced auto-save: any change is persisted shortly after the user
  /// stops typing. New hosts are created on their first auto-save.
  void _scheduleSave() {
    _saveTimer?.cancel();
    setState(() => _saving = true);
    _saveTimer = Timer(const Duration(milliseconds: 700), _saveNow);
  }

  Future<void> _saveNow() async {
    _saveTimer?.cancel();
    final db = ref.read(appDatabaseProvider);
    final vault = ref.read(vaultProvider);

    String? encryptedPassword;
    if (_authType == 'password') {
      final password = _password.text.trim();
      if (password.isNotEmpty) {
        try {
          encryptedPassword = await vault.encrypt(password);
        } catch (_) {
          encryptedPassword = null;
        }
      } else if (!_isEditing && _savePassword) {
        encryptedPassword = await vault.encrypt('');
      }
    }

    final effectiveName = _name.text.trim().isEmpty
        ? _address.text.trim()
        : _name.text.trim();
    final address = _address.text.trim();

    // Never persist an empty host: skip auto-save while the form has no
    // name and no address (new hosts are not created, existing hosts are
    // not overwritten with blank values).
    if (effectiveName.isEmpty && address.isEmpty) {
      if (mounted) {
        setState(() {
          _saving = false;
          _justSaved = false;
        });
      }
      return;
    }

    await db.upsertHost(
        HostsCompanion(
          id: drift.Value(_draftId),
          name: drift.Value(effectiveName),
          address: drift.Value(address),
          port: drift.Value(int.tryParse(_port.text) ?? 22),
          username: drift.Value(
            _authType.isEmpty ? '' : _username.text.trim(),
          ),
          authType: drift.Value(_authType),
          keyId: drift.Value(_authType == 'key' ? _keyId : null),
          encryptedPassword: drift.Value(
            (_authType == 'password' && _savePassword)
                ? encryptedPassword
                : null,
          ),
          groupId: drift.Value(_groupId),
          tags: drift.Value(_tags.text.trim()),
        ),
      );

    if (!mounted) return;
    setState(() {
      _saving = false;
      _justSaved = true;
    });
  }

  Future<void> _saveAndConnect() async {
    await _saveNow();
    if (!mounted) return;
    final address = _address.text.trim();
    final effectiveName = _name.text.trim().isEmpty ? address : _name.text.trim();
    if (address.isEmpty) return;

    final vault = ref.read(vaultProvider);
    String? encryptedPassword;
    if (_authType == 'password') {
      final password = _password.text.trim();
      if (password.isNotEmpty) {
        encryptedPassword = await vault.encrypt(password);
      } else if (!_isEditing && _savePassword) {
        encryptedPassword = await vault.encrypt('');
      }
    }

    if (!mounted) return;

    await connectSavedHost(
      context,
      ref,
      Host(
        id: _draftId,
        name: effectiveName,
        address: address,
        port: int.tryParse(_port.text) ?? 22,
        username: _authType.isEmpty ? '' : _username.text.trim(),
        authType: _authType,
        keyId: _keyId,
        encryptedPassword: encryptedPassword,
        groupId: _groupId,
        tags: _tags.text.trim(),
        favorite: widget.host?.favorite ?? false,
        notes: widget.host?.notes ?? '',
        lastConnected: widget.host?.lastConnected,
        os: widget.host?.os,
      ),
    );
    if (mounted) widget.onSaved();
  }

  /// New hosts created inside a group start with the group's connection
  /// details. Typing anything overrides them for this host - the host never
  /// inherits dynamically.
  Future<void> _applyGroupDefaults() async {
    if (_groupId == null) return;
    Group? group;
    for (final g in widget.groups) {
      if (g.id == _groupId) {
        group = g;
        break;
      }
    }
    if (group == null) return;

    if (group.username != null && group.username!.isNotEmpty) {
      _username.text = group.username!;
    }
    final authType =
        (group.authType == null || group.authType!.isEmpty)
            ? 'password'
            : group.authType!;
    _authType = authType;
    if (authType == 'key') _keyId = group.keyId;

    if (authType == 'password' && group.encryptedPassword != null) {
      try {
        final password = await ref
            .read(vaultProvider)
            .decrypt(group.encryptedPassword!);
        if (mounted) setState(() => _password.text = password);
      } catch (_) {
        // Leave the password blank if it cannot be decrypted.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PanelScaffold(
      child: Form(
        key: _formKey,
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
                          _isEditing ? 'Edit host' : 'New host',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (_saving)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else if (_justSaved)
                        _SaveStatusLabel(
                          icon: Icons.check_circle_outline,
                          label: 'Saved',
                          color: AppColors.accent,
                        ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: widget.onSaved,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SectionCard(
                    icon: Icons.lan_outlined,
                    title: 'ADDRESS',
                    children: [
                      TextFormField(
                        controller: _address,
                        decoration: const InputDecoration(
                          labelText: 'Address',
                          hintText: 'e.g. 192.168.1.10 or host.example.com',
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Address is required'
                            : null,
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ],
                  ),
                  _SectionCard(
                    icon: Icons.folder_outlined,
                    title: 'GENERAL',
                    children: [
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Leave blank to use the address',
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String?>(
                        key: ValueKey('group-$_groupId'),
                        initialValue: _groupId,
                        decoration: const InputDecoration(
                          labelText: 'Group',
                        ),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text(
                              'Ungrouped',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                          for (final group in widget.groups)
                            DropdownMenuItem<String?>(
                              value: group.id,
                              child: Text(
                                group.name,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() {
                          _groupId = v;
                          _markDirty();
                        }),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _tags,
                        decoration: const InputDecoration(
                          labelText: 'Tags (comma separated)',
                        ),
                      ),
                    ],
                  ),
                  _SectionCard(
                    icon: Icons.lock_outline,
                    title: 'CONNECTION',
                    children: [
                      TextFormField(
                        controller: _username,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _AuthSegmented(
                        options: const [
                          (value: 'password', label: 'Password', icon: Icons.key_outlined),
                          (value: 'key', label: 'Key', icon: Icons.vpn_key_outlined),
                        ],
                        selected: _authType,
                        onChanged: (v) => setState(() {
                          _authType = v;
                          _markDirty();
                        }),
                        showInherit: false,
                      ),
                      const SizedBox(height: 12),
                      if (_authType.isEmpty) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.accentMuted,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.accentBorder),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_copy_outlined,
                                size: 15,
                                color: AppColors.accent,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Uses the group credentials. If the group '
                                  'has none, you will be asked when '
                                  'connecting.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.4,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else if (_authType == 'password') ...[
                        TextFormField(
                          controller: _password,
                          obscureText: !_showPassword,
                          decoration: InputDecoration(
                            labelText: _isEditing
                                ? 'Password (leave blank to keep)'
                                : 'Password',
                            suffixIcon: IconButton(
                              tooltip: _showPassword
                                  ? 'Hide password'
                                  : 'Show password',
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 16,
                              ),
                              onPressed: () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                            ),
                          ),
                        ),
                        if (_isEditing)
                          CheckboxListTile(
                            value: _savePassword,
                            onChanged: (v) => setState(() {
                              _savePassword = v ?? true;
                              _markDirty();
                            }),
                            title: const Text('Save password with host'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                      ] else ...[
                        KeySelectField(
                          key: ValueKey('key-$_keyId'),
                          value: _keyId,
                          identities: widget.identities,
                          onChanged: (v) => setState(() {
                            _keyId = v;
                            _markDirty();
                          }),
                          validator: (v) => _authType == 'key' && v == null
                              ? 'Select a key'
                              : null,
                        ),
                        if (widget.identities.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'No keys imported yet. Add one in the Keys '
                              'section.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.warning,
                              ),
                            ),
                          ),
                      ],
                    ],
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
                onPressed: _saveAndConnect,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Connect'),
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

/// Compact, gap-free segment selector (Password / Key / Inherit).
class _AuthSegmented extends StatelessWidget {
  final List<({String value, String label, IconData icon})> options;
  final String selected;
  final ValueChanged<String> onChanged;
  final bool showInherit;

  const _AuthSegmented({
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.showInherit,
  });

  @override
  Widget build(BuildContext context) {
    final visible =
        showInherit ? options : options.where((o) => o.value != '').toList();
    return Container(
      height: 34,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: _SegmentOption(
                label: visible[i].label,
                icon: visible[i].icon,
                selected: selected == visible[i].value,
                onTap: () => onChanged(visible[i].value),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SegmentOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 13,
              color: selected
                  ? const Color(0xFF0B1220)
                  : AppColors.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? const Color(0xFF0B1220)
                    : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupFormPanel extends ConsumerStatefulWidget {
  final Group? group;
  final List<Identity> identities;
  final VoidCallback onSaved;

  const _GroupFormPanel({
    required this.group,
    required this.identities,
    required this.onSaved,
  });

  @override
  ConsumerState<_GroupFormPanel> createState() => _GroupFormPanelState();
}

class _GroupFormPanelState extends ConsumerState<_GroupFormPanel> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _username;
  late final TextEditingController _password;

  late String _authType;
  String? _keyId;
  bool _showPassword = false;

  bool get _isEditing => widget.group != null;

  @override
  void initState() {
    super.initState();
    final group = widget.group;
    _name = TextEditingController(text: group?.name ?? '');
    _username = TextEditingController(text: group?.username ?? '');
    _password = TextEditingController();
    _authType = group?.authType ?? 'password';
    _keyId = group?.keyId;
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final db = ref.read(appDatabaseProvider);
    final vault = ref.read(vaultProvider);

    String? encryptedPassword;
    if (_authType == 'password') {
      final password = _password.text.trim();
      if (password.isNotEmpty) {
        encryptedPassword = await vault.encrypt(password);
      } else if (widget.group?.encryptedPassword != null) {
        encryptedPassword = widget.group!.encryptedPassword;
      }
    }

    await db.upsertGroup(
      GroupsCompanion(
        id: drift.Value(widget.group?.id ?? const Uuid().v4()),
        name: drift.Value(_name.text.trim()),
        username: drift.Value(_username.text.trim().isEmpty
            ? null
            : _username.text.trim()),
        authType: drift.Value(_authType),
        keyId: drift.Value(_authType == 'key' ? _keyId : null),
        encryptedPassword: drift.Value(encryptedPassword),
      ),
    );

    if (!mounted) return;
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return _PanelScaffold(
      child: Form(
        key: _formKey,
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
                          _isEditing ? 'Edit group' : 'New group',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: widget.onSaved,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SectionCard(
                    icon: Icons.folder_outlined,
                    title: 'GENERAL',
                    children: [
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: 'Group name',
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Name is required'
                            : null,
                      ),
                    ],
                  ),
                  _SectionCard(
                    icon: Icons.lock_outline,
                    title: 'GROUP CREDENTIALS',
                    children: [
                      Text(
                        'Used by hosts that do not define their own '
                        'credentials.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: AppColors.textFaint,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _username,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _AuthSegmented(
                        options: const [
                          (value: 'password', label: 'Password', icon: Icons.key_outlined),
                          (value: 'key', label: 'Key', icon: Icons.vpn_key_outlined),
                        ],
                        selected: _authType,
                        onChanged: (v) => setState(() => _authType = v),
                        showInherit: false,
                      ),
                      const SizedBox(height: 12),
                      if (_authType == 'password')
                        TextFormField(
                          controller: _password,
                          obscureText: !_showPassword,
                          decoration: InputDecoration(
                            labelText: _isEditing
                                ? 'Password (leave blank to keep)'
                                : 'Password',
                            suffixIcon: IconButton(
                              tooltip: _showPassword
                                  ? 'Hide password'
                                  : 'Show password',
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 16,
                              ),
                              onPressed: () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                            ),
                          ),
                        )
                      else
                        KeySelectField(
                          key: ValueKey('gkey-$_keyId'),
                          value: _keyId,
                          identities: widget.identities,
                          onChanged: (v) => setState(() => _keyId = v),
                          validator: (v) => v == null
                              ? 'Select a key'
                              : null,
                        ),
                    ],
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
                label: const Text('Save group'),
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

/// Requests the hosts screen to open the editor (new host, or edit [host]).
void showHostEditor(WidgetRef ref, {Host? host, String? groupId}) {
  ref.read(hostEditorRequestProvider.notifier).state =
      HostEditorRequest(hostId: host?.id, groupId: groupId);
}

/// Requests the hosts screen to open the group editor (new group, or edit
/// [group]) in the details panel.
void showGroupEditor(WidgetRef ref, {Group? group}) {
  ref.read(groupEditorRequestProvider.notifier).state =
      GroupEditorRequest(groupId: group?.id);
}
