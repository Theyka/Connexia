import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/sync_controller.dart';
import '../theme/app_colors.dart';

/// Optional cloud-sync account: register, sign in, email verification,
/// two-factor authentication, sync status and sign out.
///
/// Everything stays local until an account is added. Snapshots are encrypted
/// with a key derived from the account password before upload, so the sync
/// server can never read the data.
class AccountSettingsPanel extends ConsumerStatefulWidget {
  const AccountSettingsPanel({super.key});

  @override
  ConsumerState<AccountSettingsPanel> createState() =>
      _AccountSettingsPanelState();
}

class _AccountSettingsPanelState extends ConsumerState<AccountSettingsPanel> {
  bool _registerMode = false;
  bool _editingServer = false;
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _verifyCode = TextEditingController();
  final _totpCode = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final serverUrl = ref.read(syncControllerProvider).serverUrl;
    _server.text = serverUrl;
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _verifyCode.dispose();
    _totpCode.dispose();
    super.dispose();
  }

  void _submit() {
    final controller = ref.read(syncControllerProvider.notifier);
    controller.setServerUrl(_server.text);
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) return;
    if (_registerMode) {
      if (password.length < 8) {
        _showError('Password must be at least 8 characters');
        return;
      }
      if (password != _confirm.text) {
        _showError('Passwords do not match');
        return;
      }
      controller.register(email, password);
    } else {
      controller.login(email, password);
    }
  }

  void _verifyEmail() {
    if (_verifyCode.text.trim().isEmpty) return;
    ref.read(syncControllerProvider.notifier).verifyEmail(_verifyCode.text.trim());
  }

  void _completeTotp() {
    if (_totpCode.text.trim().isEmpty) return;
    ref
        .read(syncControllerProvider.notifier)
        .completeTotpLogin(_totpCode.text.trim());
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _enable2fa() async {
    final result =
        await ref.read(syncControllerProvider.notifier).enable2fa();
    if (result == null || !mounted) return;
    final (secret, otpauthUrl) = result;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _TotpCodeDialog(
        title: 'Enable two-factor authentication',
        confirmLabel: 'Enable',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add this account to your authenticator app (Google '
              'Authenticator, Authy, 1Password, ...), then enter the '
              '6-digit code it shows to finish.',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            Text(
              'otpauth:// URL',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textFaint),
            ),
            const SizedBox(height: 4),
            SelectableText(
              otpauthUrl,
              style: TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono', color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              'Or enter the secret manually',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textFaint),
            ),
            const SizedBox(height: 4),
            SelectableText(
              secret,
              style: TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: AppColors.accent),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: otpauthUrl)),
              icon: const Icon(Icons.copy, size: 14),
              label: const Text('Copy otpauth URL'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 30),
              ),
            ),
          ],
        ),
        onConfirm: (code) => ref.read(syncControllerProvider.notifier).confirm2fa(code),
      ),
    );
    if (ok == true && mounted) _showError('Two-factor authentication enabled');
  }

  Future<void> _disable2fa() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _TotpCodeDialog(
        title: 'Disable two-factor authentication',
        confirmLabel: 'Disable',
        body: Text(
          'Enter a current code from your authenticator app to confirm '
          'that you are disabling 2FA.',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.textSecondary),
        ),
        onConfirm: (code) => ref.read(syncControllerProvider.notifier).disable2fa(code),
      ),
    );
    if (ok == true && mounted) _showError('Two-factor authentication disabled');
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncControllerProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const _SectionTitle('ACCOUNT'),
        if (sync.status == SyncStatus.signedIn)
          _buildSignedIn(sync)
        else if (sync.pendingVerification)
          _buildVerifyEmail(sync)
        else if (sync.totpChallenge)
          _buildTotpLogin(sync)
        else
          _buildSignedOut(sync),
      ],
    );
  }

  Widget _buildSignedOut(SyncState sync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: AppColors.accent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Optional end-to-end encrypted sync. Your hosts, SSH keys '
                  'and snippets are encrypted on this device before upload - '
                  'the sync server can never read them. Skip this and '
                  'everything stays local.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _SectionTitle('SYNC SERVER'),
        if (!_editingServer)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Icon(Icons.dns_outlined, size: 18, color: AppColors.textFaint),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    sync.serverUrl.isEmpty ? defaultSyncServerUrl : sync.serverUrl,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _editingServer = true;
                      _server.text =
                          sync.serverUrl.isEmpty ? defaultSyncServerUrl : sync.serverUrl;
                    });
                  },
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('Change'),
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _server,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://sync.connexia.run/',
                  prefixIcon: Icon(Icons.dns_outlined, size: 18),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _server.text = sync.serverUrl;
                        _editingServer = false;
                      });
                    },
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () {
                      ref
                          .read(syncControllerProvider.notifier)
                          .setServerUrl(_server.text);
                      setState(() => _editingServer = false);
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        if (!_editingServer)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                _server.text = defaultSyncServerUrl;
                ref
                    .read(syncControllerProvider.notifier)
                    .setServerUrl(defaultSyncServerUrl);
              },
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Reset to default',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        const SizedBox(height: 14),
        _SectionTitle(_registerMode ? 'REGISTER' : 'SIGN IN'),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(Icons.mail_outline, size: 18),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _password,
          obscureText: _obscure,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline, size: 18),
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              icon: Icon(
                _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 16,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        if (_registerMode) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _confirm,
            obscureText: _obscure,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Confirm password',
              prefixIcon: Icon(Icons.lock_outline, size: 18),
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          _registerMode
              ? 'Your password derives the encryption key locally. '
                  'A server leak cannot expose your data. A verification '
                  'code will be emailed to you after registration.'
              : 'Signing in on a new device restores your hosts, keys and '
                  'snippets from the server snapshot.',
          style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
        ),
        const SizedBox(height: 14),
        if (sync.busy)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          FilledButton.icon(
            onPressed: _submit,
            icon: Icon(
              _registerMode ? Icons.person_add_outlined : Icons.login,
              size: 16,
            ),
            label: Text(_registerMode ? 'Create account' : 'Sign in'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
          ),
        if (sync.error != null && sync.error!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            sync.error!,
            style: TextStyle(fontSize: 12, color: AppColors.danger),
          ),
        ],
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => setState(() {
            _registerMode = !_registerMode;
            _confirm.clear();
          }),
          child: Text(
            _registerMode
                ? 'Already have an account? Sign in'
                : 'New to the sync server? Create an account',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );
  }

  Widget _buildVerifyEmail(SyncState sync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.accentMuted,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.accentBorder),
          ),
          child: Row(
            children: [
              Icon(Icons.mark_email_read_outlined, size: 18, color: AppColors.accent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'A 6-digit verification code was sent to '
                  '${_email.text.trim().isEmpty ? 'your email' : _email.text.trim()}. '
                  'Enter it below to activate your account.',
                  style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _SectionTitle('VERIFICATION CODE'),
        TextField(
          controller: _verifyCode,
          keyboardType: TextInputType.number,
          maxLength: 6,
          onSubmitted: (_) => _verifyEmail(),
          decoration: const InputDecoration(
            labelText: '6-digit code',
            prefixIcon: Icon(Icons.pin_outlined, size: 18),
          ),
        ),
        const SizedBox(height: 6),
        if (sync.busy)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else ...[
          FilledButton.icon(
            onPressed: _verifyEmail,
            icon: const Icon(Icons.verified_outlined, size: 16),
            label: const Text('Verify email'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () =>
                ref.read(syncControllerProvider.notifier).resendVerification(),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(38)),
            child: const Text('Resend code'),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () {
              _verifyCode.clear();
              ref.read(syncControllerProvider.notifier).cancelPendingAuth();
            },
            child: const Text('Back'),
          ),
        ],
        if (sync.error != null && sync.error!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            sync.error!,
            style: TextStyle(fontSize: 12, color: AppColors.danger),
          ),
        ],
      ],
    );
  }

  Widget _buildTotpLogin(SyncState sync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.accentMuted,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.accentBorder),
          ),
          child: Row(
            children: [
              Icon(Icons.security_outlined, size: 18, color: AppColors.accent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Two-factor authentication is enabled on this account. '
                  'Enter the 6-digit code from your authenticator app to '
                  'sign in.',
                  style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _SectionTitle('AUTHENTICATOR CODE'),
        TextField(
          controller: _totpCode,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          onSubmitted: (_) => _completeTotp(),
          decoration: const InputDecoration(
            labelText: '6-digit code',
            prefixIcon: Icon(Icons.pin_outlined, size: 18),
          ),
        ),
        const SizedBox(height: 6),
        if (sync.busy)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else ...[
          FilledButton.icon(
            onPressed: _completeTotp,
            icon: const Icon(Icons.login, size: 16),
            label: const Text('Verify and sign in'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () {
              _totpCode.clear();
              ref.read(syncControllerProvider.notifier).cancelPendingAuth();
            },
            child: const Text('Back'),
          ),
        ],
        if (sync.error != null && sync.error!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            sync.error!,
            style: TextStyle(fontSize: 12, color: AppColors.danger),
          ),
        ],
      ],
    );
  }

  Widget _buildSignedIn(SyncState sync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.accentMuted,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.accentBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      Icons.cloud_done_outlined,
                      size: 17,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sync.email ?? '',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          sync.serverUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (sync.pendingSync)
                    Text(
                      'Pending changes...',
                      style: TextStyle(fontSize: 12, color: AppColors.warning),
                    )
                  else if (sync.busy)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      sync.lastSyncedAt == null
                          ? 'Never synced'
                          : 'Synced ${_relative(sync.lastSyncedAt!)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _SectionTitle('SECURITY'),
        Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      sync.emailVerified
                          ? Icons.verified_outlined
                          : Icons.error_outline,
                      size: 17,
                      color: sync.emailVerified ? AppColors.success : AppColors.warning,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Email verification',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    Text(
                      sync.emailVerified ? 'Verified' : 'Pending',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: sync.emailVerified
                            ? AppColors.success
                            : AppColors.warning,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      sync.totpEnabled
                          ? Icons.security_outlined
                          : Icons.security_outlined,
                      size: 17,
                      color: sync.totpEnabled ? AppColors.accent : AppColors.textFaint,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Two-factor authentication',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    Text(
                      sync.totpEnabled ? 'Enabled' : 'Off',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: sync.totpEnabled
                            ? AppColors.accent
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (sync.totpEnabled)
          OutlinedButton.icon(
            onPressed: sync.busy ? null : _disable2fa,
            icon: const Icon(Icons.shield_outlined, size: 15),
            label: const Text('Disable two-factor authentication'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(38)),
          )
        else
          OutlinedButton.icon(
            onPressed: sync.busy ? null : _enable2fa,
            icon: const Icon(Icons.shield_outlined, size: 15),
            label: const Text('Enable two-factor authentication'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(38)),
          ),
        if (sync.error != null && sync.error!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            sync.error!,
            style: const TextStyle(fontSize: 12, color: AppColors.danger),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: sync.busy
              ? null
              : () => ref.read(syncControllerProvider.notifier).syncNow(),
          icon: const Icon(Icons.sync, size: 16),
          label: Text(sync.busy ? 'Syncing...' : 'Sync now'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(40)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: sync.busy
              ? null
              : () => ref.read(syncControllerProvider.notifier).signOut(),
          icon: const Icon(Icons.logout, size: 15),
          label: const Text('Sign out'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(38)),
        ),
        const SizedBox(height: 12),
        Text(
          'This device stays in sync automatically: local changes are pushed '
          'a few seconds after you make them, and the server snapshot is '
          'pulled whenever the app starts. Data is encrypted before upload - '
          'the server cannot read it.',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.5,
            color: AppColors.textFaint,
          ),
        ),
      ],
    );
  }

  static String _relative(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Dialog that asks for a TOTP code and runs an async confirmation.
/// Pops with `true` when the confirmation succeeds.
class _TotpCodeDialog extends StatefulWidget {
  final String title;
  final String confirmLabel;
  final Widget body;
  final Future<bool> Function(String code) onConfirm;

  const _TotpCodeDialog({
    required this.title,
    required this.confirmLabel,
    required this.body,
    required this.onConfirm,
  });

  @override
  State<_TotpCodeDialog> createState() => _TotpCodeDialogState();
}

class _TotpCodeDialogState extends State<_TotpCodeDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.onConfirm(code);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = 'Invalid code. Check your authenticator app and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.body,
            const SizedBox(height: 14),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '6-digit code',
                prefixIcon: Icon(Icons.pin_outlined, size: 18),
                counterText: '',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: AppColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
