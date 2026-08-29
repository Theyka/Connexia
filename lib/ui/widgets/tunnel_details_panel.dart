import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/db/database.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';

class TunnelDetailsPanel extends ConsumerStatefulWidget {
  final Tunnel? tunnel;
  final bool creating;
  final VoidCallback onClose;

  const TunnelDetailsPanel({
    super.key,
    this.tunnel,
    this.creating = false,
    required this.onClose,
  });

  @override
  ConsumerState<TunnelDetailsPanel> createState() =>
      _TunnelDetailsPanelState();
}

class _TunnelDetailsPanelState extends ConsumerState<TunnelDetailsPanel> {
  late final TextEditingController _name;
  late final TextEditingController _bindAddress;
  late final TextEditingController _bindPort;
  late final TextEditingController _targetHost;
  late final TextEditingController _targetPort;
  late String _type; // 'local' | 'dynamic' | 'remote'
  late bool _autoStart;
  String? _hostId; // null = standalone (inline credentials)
  late final TextEditingController _username;
  late String _authType; // '' | 'password' | 'key'
  String? _keyId;
  late final TextEditingController _password;
  late final TextEditingController _serverAddress;
  late final TextEditingController _serverPort;
  late final TextEditingController _notes;
  int? _color;

  @override
  void initState() {
    super.initState();
    final t = widget.tunnel;
    _name = TextEditingController(text: t?.name ?? '');
    _bindAddress =
        TextEditingController(text: t?.bindAddress ?? '127.0.0.1');
    _bindPort = TextEditingController(text: t?.bindPort?.toString() ?? '');
    _targetHost = TextEditingController(text: t?.targetHost ?? '');
    _targetPort = TextEditingController(
      text: t?.targetPort?.toString() ?? '',
    );
    _type = t?.type ?? 'local';
    _autoStart = t?.autoStart ?? false;
    _hostId = t?.hostId;
    _username = TextEditingController(text: t?.username ?? '');
    _authType = t?.authType ?? '';
    _keyId = t?.keyId;
    _password = TextEditingController(text: '');
    _serverAddress = TextEditingController(text: t?.address ?? '');
    _serverPort = TextEditingController(text: t?.port.toString());
    _notes = TextEditingController(text: t?.notes ?? '');
    _color = t?.color;
  }

  @override
  void dispose() {
    _name.dispose();
    _bindAddress.dispose();
    _bindPort.dispose();
    _targetHost.dispose();
    _targetPort.dispose();
    _username.dispose();
    _password.dispose();
    _serverAddress.dispose();
    _serverPort.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;

    final bindAddr = _bindAddress.text.trim().isEmpty
        ? '127.0.0.1'
        : _bindAddress.text.trim();
    final bindPort = int.tryParse(_bindPort.text.trim());
    final targetPort = int.tryParse(_targetPort.text.trim());

    String? encryptedPassword;
    if (_authType == 'password' && _password.text.isNotEmpty) {
      try {
        encryptedPassword = await ref
            .read(vaultProvider)
            .encrypt(_password.text);
      } catch (_) {}
    } else if (widget.tunnel != null &&
        _authType == 'password' &&
        _password.text.isEmpty) {
      // Preserve existing password when the user didn't type a new one.
      encryptedPassword = widget.tunnel!.encryptedPassword;
    }

    // Standalone tunnels connect to the inline server address and use the
    // inline credentials; host-linked tunnels inherit everything from the
    // host, so any previously saved inline values are cleared.
    final standalone = _hostId == null;
    final serverAddr = standalone
        ? (_serverAddress.text.trim().isEmpty
            ? null
            : _serverAddress.text.trim())
        : null;
    final serverPort =
        standalone ? (int.tryParse(_serverPort.text.trim()) ?? 22) : 22;
    final inlineUsername =
        standalone && _username.text.trim().isNotEmpty
            ? _username.text.trim()
            : null;
    final inlineAuthType =
        standalone && _authType.isNotEmpty ? _authType : null;
    final inlineKeyId = standalone ? _keyId : null;
    final inlinePassword = standalone ? encryptedPassword : null;

    await ref.read(appDatabaseProvider).upsertTunnel(
          TunnelsCompanion(
            id: drift.Value(widget.tunnel?.id ?? const Uuid().v4()),
            name: drift.Value(name),
            hostId: drift.Value(_hostId),
            type: drift.Value(_type),
            address: drift.Value(serverAddr),
            port: drift.Value(serverPort),
            username: drift.Value(inlineUsername),
            authType: drift.Value(inlineAuthType),
            keyId: drift.Value(inlineKeyId),
            encryptedPassword: drift.Value(inlinePassword),
            bindAddress: drift.Value(bindAddr),
            bindPort: drift.Value(bindPort),
            targetHost: drift.Value(
              _targetHost.text.trim().isEmpty ? null : _targetHost.text.trim(),
            ),
            targetPort: drift.Value(targetPort),
            autoStart: drift.Value(_autoStart),
            color: drift.Value(_color),
            notes: drift.Value(_notes.text),
            createdAt:
                drift.Value(widget.tunnel?.createdAt ?? DateTime.now()),
          ),
        );
    if (!mounted) return;
    widget.onClose();
  }

  Future<List<Host>> _loadHosts() async {
    final db = ref.read(appDatabaseProvider);
    return db.allHosts();
  }

  Future<List<Identity>> _loadIdentities() async {
    final db = ref.read(appDatabaseProvider);
    return db.allIdentities();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Theme(
        data: theme.copyWith(
          textTheme: theme.textTheme.copyWith(
            bodyLarge: TextStyle(fontSize: 13, color: AppColors.textPrimary),
            bodyMedium:
                TextStyle(fontSize: 13, color: AppColors.textPrimary),
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
                          widget.creating ? 'New tunnel' : 'Edit tunnel',
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
                  _SectionLabel('General'),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _type,
                    items: const [
                      DropdownMenuItem(
                        value: 'local',
                        child: Text('Local forward (-L)'),
                      ),
                      DropdownMenuItem(
                        value: 'dynamic',
                        child: Text('Dynamic / SOCKS5 (-D)'),
                      ),
                      DropdownMenuItem(
                        value: 'remote',
                        child: Text('Remote forward (-R)'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _type = v ?? 'local'),
                    decoration: const InputDecoration(labelText: 'Type'),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto-start at launch'),
                    subtitle: Text(
                      'Connect this tunnel automatically when Connexia opens.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    value: _autoStart,
                    onChanged: (v) => setState(() => _autoStart = v),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel('Connection source'),
                  const SizedBox(height: 6),
                  FutureBuilder<List<Host>>(
                    future: _loadHosts(),
                    builder: (context, snap) {
                      final hosts = snap.data ?? const <Host>[];
                      return DropdownButtonFormField<String?>(
                        initialValue: _hostId,
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Standalone (no host)'),
                          ),
                          for (final h in hosts)
                            DropdownMenuItem<String?>(
                              value: h.id,
                              child: Text(
                                '${h.name} — ${h.address}:${h.port}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _hostId = v),
                        decoration: const InputDecoration(
                          labelText: 'Linked host',
                          helperText:
                              'Inherit credentials from this saved host.',
                        ),
                      );
                    },
                  ),
                  if (_hostId == null) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _serverAddress,
                      decoration: const InputDecoration(
                        labelText: 'Server address',
                        helperText: 'SSH server the tunnel connects to.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _serverPort,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Server port',
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _authType.isEmpty ? null : _authType,
                      items: const [
                        DropdownMenuItem(value: 'password', child: Text('Password')),
                        DropdownMenuItem(value: 'key', child: Text('Private key')),
                      ],
                      onChanged: (v) => setState(() {
                        _authType = v ?? '';
                        if (_authType != 'key') _keyId = null;
                      }),
                      decoration: const InputDecoration(
                        labelText: 'Authentication',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _username,
                      decoration: const InputDecoration(labelText: 'Username'),
                    ),
                    if (_authType == 'password') ...[
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _password,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: widget.tunnel?.encryptedPassword != null
                              ? 'New password (leave blank to keep)'
                              : 'Password',
                        ),
                      ),
                    ] else if (_authType == 'key') ...[
                      const SizedBox(height: 10),
                      FutureBuilder<List<Identity>>(
                        future: _loadIdentities(),
                        builder: (context, snap) {
                          final ids = snap.data ?? const <Identity>[];
                          return DropdownButtonFormField<String?>(
                            initialValue: _keyId,
                            items: [
                              for (final i in ids)
                                DropdownMenuItem<String?>(
                                  value: i.id,
                                  child: Text(i.name),
                                ),
                            ],
                            onChanged: (v) => setState(() => _keyId = v),
                            decoration: const InputDecoration(
                              labelText: 'Identity',
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                  const SizedBox(height: 18),
                  _SectionLabel('Forward rule'),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _bindAddress,
                    decoration: const InputDecoration(
                      labelText: 'Bind address',
                      helperText:
                          '127.0.0.1 = loopback only; 0.0.0.0 = all interfaces.',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _bindPort,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Bind port',
                      helperText: 'Leave blank to let the OS pick.',
                    ),
                  ),
                  if (_type == 'local' || _type == 'remote') ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _targetHost,
                      decoration: const InputDecoration(
                        labelText: 'Target host',
                        helperText: 'Hostname or IP on the remote side.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _targetPort,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Target port',
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _SectionLabel('Notes'),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Optional notes…',
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
                label: const Text('Save tunnel'),
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

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: AppColors.textFaint,
      ),
    );
  }
}
