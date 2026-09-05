import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/ssh/session_manager.dart';
import '../state/connection_helpers.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import 'key_select_field.dart';
import 'select_field.dart';

class QuickConnectSheet extends ConsumerStatefulWidget {
  const QuickConnectSheet({super.key});

  @override
  ConsumerState<QuickConnectSheet> createState() => _QuickConnectSheetState();
}

class _QuickConnectSheetState extends ConsumerState<QuickConnectSheet> {
  final _formKey = GlobalKey<FormState>();

  final _address = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  String _authType = 'password';
  String? _keyId;
  bool _saveHost = false;

  List<Identity> _identities = [];

  @override
  void initState() {
    super.initState();
    _loadIdentities();
  }

  Future<void> _loadIdentities() async {
    final identities = await ref.read(appDatabaseProvider).allIdentities();
    if (mounted) setState(() => _identities = identities);
  }

  @override
  void dispose() {
    _address.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;

    final port = int.tryParse(_port.text) ?? 22;
    final request = HostConnectionRequest(
      displayName: _name.text.trim().isNotEmpty
          ? _name.text.trim()
          : '${_username.text.trim()}@${_address.text.trim()}',
      address: _address.text.trim(),
      port: port,
      username: _username.text.trim(),
      password: _authType == 'password' ? _password.text : null,
      identityId: _authType == 'key' ? _keyId : null,
    );

    if (_saveHost) {
      final db = ref.read(appDatabaseProvider);
      final vault = ref.read(vaultProvider);
      String? encryptedPassword;
      if (request.password != null) {
        encryptedPassword = await vault.encrypt(request.password!);
      }
      await db.upsertHost(
        HostsCompanion.insert(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: request.displayName,
          address: request.address,
          username: request.username,
          port: drift.Value(port),
          authType: drift.Value(_authType),
          keyId: drift.Value(request.identityId),
          encryptedPassword: drift.Value(encryptedPassword),
        ),
      );
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    await quickConnect(ref, request);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.accentMuted,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: AppColors.accentBorder),
                    ),
                    child: Icon(
                      Icons.bolt,
                      size: 18,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Quick connect',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _address,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  hintText: 'host.example.com',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Address is required' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _username,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Required'
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SelectField<String>(
                value: _authType,
                label: 'Authentication',
                icon: Icons.lock_outline,
                options: const [
                  SelectOption('password', 'Password'),
                  SelectOption('key', 'Private key'),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _authType = v);
                },
              ),
              const SizedBox(height: 12),
              if (_authType == 'password')
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                  ),
                )
              else
                KeySelectField(
                  key: ValueKey('key-$_keyId'),
                  value: _keyId,
                  identities: _identities,
                  onChanged: (v) => setState(() => _keyId = v),
                  validator: (v) => v == null ? 'Select a key' : null,
                ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _saveHost,
                onChanged: (v) => setState(() => _saveHost = v ?? false),
                title: const Text('Save this host'),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              if (_saveHost)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Connect'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showQuickConnect(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Container(
      decoration: BoxDecoration(
        color: AppColors.elevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: const QuickConnectSheet(),
    ),
  );
}
