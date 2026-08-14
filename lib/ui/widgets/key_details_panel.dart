import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:drift/drift.dart' as drift;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/db/database.dart';
import '../state/key_utils.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';

class _PanelScaffold extends StatelessWidget {
  final Widget child;

  const _PanelScaffold({required this.child});

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
        child: child,
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback onClose;
  final List<Widget> actions;

  const _PanelHeader({
    required this.title,
    required this.onClose,
    this.subtitle,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ...actions,
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close, size: 20),
              onPressed: onClose,
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        text,
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

/// Manual SSH key form: label, private key, public key and certificate.
/// Used both for creating a key and for editing an existing one.
class KeyFormPanel extends ConsumerStatefulWidget {
  final Identity? identity;
  final String? initialPrivateKey;
  final VoidCallback onClose;
  final VoidCallback? onDelete;

  const KeyFormPanel({
    super.key,
    this.identity,
    this.initialPrivateKey,
    required this.onClose,
    this.onDelete,
  });

  @override
  ConsumerState<KeyFormPanel> createState() => _KeyFormPanelState();
}

class _KeyFormPanelState extends ConsumerState<KeyFormPanel> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _label;
  late final TextEditingController _privateKey;
  late final TextEditingController _publicKey;
  late final TextEditingController _certificate;
  late final TextEditingController _passphrase;

  bool _loading = true;
  bool _dragging = false;
  bool _obscurePassphrase = true;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.identity?.name ?? '');
    _privateKey = TextEditingController(text: widget.initialPrivateKey ?? '');
    _publicKey = TextEditingController(text: widget.identity?.publicKey ?? '');
    _certificate =
        TextEditingController(text: widget.identity?.certificate ?? '');
    _passphrase = TextEditingController();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final identity = widget.identity;
    if (identity == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final vault = ref.read(vaultProvider);
      final pem = await vault.decrypt(identity.encryptedKeyPem);
      if (!mounted) return;
      setState(() {
        _privateKey.text = pem;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _privateKey.dispose();
    _publicKey.dispose();
    _certificate.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _importFromPicker() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select private key file',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    await _loadFile(path);
  }

  Future<void> _loadFile(String path) async {
    try {
      final content = await File(path).readAsString();
      if (!mounted) return;
      setState(() {
        _privateKey.text = content;
        if (_publicKey.text.trim().isEmpty) {
          _publicKey.text = publicKeyFromPem(content) ?? '';
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not read file: $e')),
      );
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final privateKey = _privateKey.text.trim();
    if (privateKey.isEmpty) return;

    final vault = ref.read(vaultProvider);
    final db = ref.read(appDatabaseProvider);
    final id = widget.identity?.id ?? const Uuid().v4();

    final passphrase = _passphrase.text;
    final existingPassphrase = widget.identity?.encryptedPassphrase;

    await db.upsertIdentity(
      IdentitiesCompanion(
        id: drift.Value(id),
        name: drift.Value(
          _label.text.trim().isEmpty ? 'SSH key' : _label.text.trim(),
        ),
        encryptedKeyPem: drift.Value(await vault.encrypt(privateKey)),
        publicKey: drift.Value(_publicKey.text.trim()),
        certificate: drift.Value(_certificate.text.trim()),
        encryptedPassphrase: passphrase.isNotEmpty
            ? drift.Value(await vault.encrypt(passphrase))
            : (existingPassphrase == null
                ? drift.Value(null)
                : drift.Value.absent()),
      ),
    );
    if (!mounted) return;
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.identity != null;

    return _PanelScaffold(
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                children: [
                  _PanelHeader(
                    title: isEditing ? 'Edit key' : 'New key',
                    subtitle: isEditing
                        ? widget.identity!.comment.isEmpty
                            ? null
                            : widget.identity!.comment
                        : 'Enter a private key manually or import one from a '
                            'file.',
                    onClose: widget.onClose,
                    actions: [
                      if (widget.onDelete != null)
                        IconButton(
                          tooltip: 'Delete key',
                          icon: const Icon(Icons.delete_outline, size: 19),
                          onPressed: widget.onDelete,
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const _SectionLabel('KEY FIELDS'),
                  TextFormField(
                    controller: _label,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      hintText: 'e.g. My Production Key',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _privateKey,
                    maxLines: 10,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Private key *',
                      alignLabelWithHint: true,
                      hintText:
                          'Paste the OpenSSH private key (-----BEGIN ...)',
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Private key is required'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _publicKey,
                    maxLines: 4,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Public key',
                      alignLabelWithHint: true,
                      hintText: 'ssh-ed25519 AAAA... or leave empty',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _certificate,
                    maxLines: 4,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Certificate',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const _SectionLabel('PASSPHRASE'),
                  TextFormField(
                    controller: _passphrase,
                    obscureText: _obscurePassphrase,
                    decoration: InputDecoration(
                      labelText: 'Passphrase (optional)',
                      hintText: 'Leave empty to keep the current one',
                      helperText: widget.identity?.encryptedPassphrase != null
                          ? 'A passphrase is currently set. Empty keeps it.'
                          : 'Protects the private key when connecting.',
                      helperMaxLines: 2,
                      suffixIcon: IconButton(
                        tooltip: _obscurePassphrase
                            ? 'Show passphrase'
                            : 'Hide passphrase',
                        icon: Icon(
                          _obscurePassphrase
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 19,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassphrase = !_obscurePassphrase,
                        ),
                      ),
                    ),
                  ),
                  const _SectionLabel('KEY FILE IMPORT'),
                  _DropArea(
                    dragging: _dragging,
                    onDragChanged: (v) => setState(() => _dragging = v),
                    onFile: (path) => _loadFile(path),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _importFromPicker,
                    icon: const Icon(Icons.upload_file, size: 16),
                    label: const Text('Import from key file'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Save key'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DropArea extends StatefulWidget {
  final bool dragging;
  final ValueChanged<bool> onDragChanged;
  final ValueChanged<String> onFile;

  const _DropArea({
    required this.dragging,
    required this.onDragChanged,
    required this.onFile,
  });

  @override
  State<_DropArea> createState() => _DropAreaState();
}

class _DropAreaState extends State<_DropArea> {
  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => widget.onDragChanged(true),
      onDragExited: (_) => widget.onDragChanged(false),
      onDragDone: (detail) {
        widget.onDragChanged(false);
        final files = detail.files;
        if (files.isNotEmpty) {
          widget.onFile(files.first.path);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 92,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: widget.dragging
              ? AppColors.accentMuted
              : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: widget.dragging
                ? AppColors.accent
                : AppColors.border,
            width: widget.dragging ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.file_download_outlined,
              size: 26,
              color: widget.dragging
                  ? AppColors.accent
                  : AppColors.textFaint,
            ),
            const SizedBox(height: 8),
            Text(
              'Drag and drop a private key file to import',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: widget.dragging
                    ? AppColors.accent
                    : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Key generation form: type, type-specific parameters, passphrase and
/// cipher. Generates the key with OpenSSH `ssh-keygen` and saves it.
class KeyGeneratePanel extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  final ValueChanged<String> onGenerated;

  const KeyGeneratePanel({
    super.key,
    required this.onClose,
    required this.onGenerated,
  });

  @override
  ConsumerState<KeyGeneratePanel> createState() => _KeyGeneratePanelState();
}

class _KeyGeneratePanelState extends ConsumerState<KeyGeneratePanel> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _roundsController = TextEditingController(text: '100');

  GenKeyType _type = GenKeyType.ed25519;
  int _ecdsaCurve = 521;
  int _rsaBits = 4096;
  int _mlDsaParam = 87;
  String _cipher = 'aes256-ctr';
  bool _showPassphrase = false;
  bool _savePassphrase = true;
  bool _generating = false;

  @override
  void dispose() {
    _labelController.dispose();
    _passphraseController.dispose();
    _roundsController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (!_formKey.currentState!.validate()) return;
    if (_type == GenKeyType.mlDsa) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ML-DSA keys require OpenSSH 9.9 or newer, which is not '
            'installed on this system.',
          ),
        ),
      );
      return;
    }

    setState(() => _generating = true);
    try {
      final int? rounds = _type == GenKeyType.ed25519
          ? int.tryParse(_roundsController.text.trim())
          : null;
      final int? bits = switch (_type) {
        GenKeyType.ecdsa => _ecdsaCurve,
        GenKeyType.rsa => _rsaBits,
        _ => null,
      };

      final passphrase = _passphraseController.text;
      final generated = await generateSshKey(
        type: _type,
        bitSize: bits,
        rounds: rounds,
        passphrase: passphrase.isEmpty ? null : passphrase,
        cipher: _cipher,
        comment: _labelController.text.trim().isEmpty
            ? 'connexia'
            : _labelController.text.trim(),
      );

      final vault = ref.read(vaultProvider);
      final db = ref.read(appDatabaseProvider);
      final id = const Uuid().v4();

      String? encryptedPassphrase;
      if (_savePassphrase && passphrase.isNotEmpty) {
        encryptedPassphrase = await vault.encrypt(passphrase);
      }

      await db.upsertIdentity(
        IdentitiesCompanion.insert(
          id: id,
          name: _labelController.text.trim().isEmpty
              ? '${_type.label} key'
              : _labelController.text.trim(),
          encryptedKeyPem: await vault.encrypt(generated.privatePem),
          encryptedPassphrase: drift.Value(encryptedPassphrase),
          comment: drift.Value('${_type.label} (generated)'),
          publicKey: drift.Value(generated.publicKey),
        ),
      );

      if (!mounted) return;
      widget.onGenerated(id);
    } on GenKeyException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not generate key: $e')),
      );
    } finally {
      if (mounted) setState(() => _generating = false);
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
                  _PanelHeader(
                    title: 'Create SSH key',
                    subtitle: 'Generate a new key pair inside Connexia.',
                    onClose: widget.onClose,
                  ),
                  const SizedBox(height: 14),
                  const _SectionLabel('KEY CONFIGURATION'),
                  TextFormField(
                    controller: _labelController,
                    decoration: const InputDecoration(
                      labelText: 'Label (optional)',
                      hintText: 'e.g. My Production Key',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Segmented<String>(
                    options: const [
                      (value: 'ED25519', label: 'ED25519'),
                      (value: 'ECDSA', label: 'ECDSA'),
                      (value: 'RSA', label: 'RSA'),
                      (value: 'ML-DSA', label: 'ML-DSA'),
                    ],
                    selected: _type.label,
                    onChanged: (v) => setState(() {
                      _type = GenKeyType.values
                          .firstWhere((t) => t.label == v);
                    }),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accentMuted,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.accentBorder),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 15,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _type.info,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ..._typeOptions(),
                  const _SectionLabel('PASSPHRASE & ENCRYPTION'),
                  TextFormField(
                    controller: _passphraseController,
                    obscureText: !_showPassphrase,
                    decoration: InputDecoration(
                      labelText: 'Passphrase',
                      hintText: 'Leave empty for no passphrase',
                      suffixIcon: IconButton(
                        tooltip: _showPassphrase
                            ? 'Hide passphrase'
                            : 'Show passphrase',
                        icon: Icon(
                          _showPassphrase
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 16,
                        ),
                        onPressed: () => setState(
                          () => _showPassphrase = !_showPassphrase,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'CIPHER',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: AppColors.textFaint,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _Segmented<String>(
                    options: const [
                      (value: 'aes256-ctr', label: 'AES-256'),
                      (value: 'aes128-ctr', label: 'AES-128'),
                      (value: '3des-cbc', label: '3DES'),
                      (value: 'des-cbc', label: 'DES'),
                    ],
                    selected: _cipher,
                    onChanged: (v) => setState(() => _cipher = v),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    value: _savePassphrase,
                    onChanged: (v) => setState(() => _savePassphrase = v),
                    title: const Text(
                      'Save passphrase',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      'Store the passphrase with the key so you are not '
                      'prompted for it when connecting.',
                      style: TextStyle(fontSize: 12, height: 1.4),
                    ),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
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
                onPressed: _generating ? null : _generate,
                icon: _generating
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.vpn_key_outlined, size: 16),
                label: const Text('Generate & save'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _typeOptions() {
    switch (_type) {
      case GenKeyType.ed25519:
        return [
          TextFormField(
            controller: _roundsController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Rounds',
            ),
            validator: (v) {
              final n = int.tryParse(v?.trim() ?? '');
              if (n == null || n < 1) return 'Enter a valid round count';
              return null;
            },
          ),
          const SizedBox(height: 6),
          Text(
            'Number of KDF rounds when saving ED25519 key. Higher numbers '
            'can increase protection of the private key but slower passphrase '
            'verification.',
            style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.textFaint),
          ),
        ];
      case GenKeyType.ecdsa:
        return [
          Text(
            'ELLIPTIC CURVE SIZE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: AppColors.textFaint,
            ),
          ),
          const SizedBox(height: 6),
          _Segmented<int>(
            options: const [
              (value: 521, label: '521'),
              (value: 384, label: '384'),
              (value: 256, label: '256'),
            ],
            selected: _ecdsaCurve,
            onChanged: (v) => setState(() => _ecdsaCurve = v),
          ),
        ];
      case GenKeyType.rsa:
        return [
          Text(
            'KEY SIZE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: AppColors.textFaint,
            ),
          ),
          const SizedBox(height: 6),
          _Segmented<int>(
            options: const [
              (value: 4096, label: '4096'),
              (value: 2048, label: '2048'),
              (value: 1024, label: '1024'),
            ],
            selected: _rsaBits,
            onChanged: (v) => setState(() => _rsaBits = v),
          ),
        ];
      case GenKeyType.mlDsa:
        return [
          Text(
            'PARAMETER SET',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: AppColors.textFaint,
            ),
          ),
          const SizedBox(height: 6),
          _Segmented<int>(
            options: const [
              (value: 87, label: '87'),
              (value: 65, label: '65'),
              (value: 44, label: '44'),
            ],
            selected: _mlDsaParam,
            onChanged: (v) => setState(() => _mlDsaParam = v),
          ),
        ];
    }
  }
}

/// Compact gap-free segmented selector.
class _Segmented<T> extends StatelessWidget {
  final List<({T value, String label})> options;
  final T selected;
  final ValueChanged<T> onChanged;

  const _Segmented({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
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
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: InkWell(
                onTap: () => onChanged(options[i].value),
                borderRadius: BorderRadius.circular(5),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected == options[i].value
                        ? AppColors.accent
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    options[i].label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: selected == options[i].value
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: selected == options[i].value
                          ? const Color(0xFF0B1220)
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
