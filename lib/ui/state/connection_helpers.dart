import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/ssh/host_credentials.dart';
import '../../core/ssh/session_manager.dart';
import '../theme/app_colors.dart';
import 'nav.dart';
import 'providers.dart';

export '../../core/ssh/host_credentials.dart' show ResolvedCredentials;

/// Resolves credentials for [host], honouring group inheritance. Returns
/// null when nothing usable is saved (the user must be prompted).
Future<ResolvedCredentials?> resolveCredentials(WidgetRef ref, Host host) =>
    resolveHostCredentials(
      ref.read(appDatabaseProvider),
      ref.read(vaultProvider),
      host,
    );

/// Opens a terminal session for a saved host. Uses the host's own
/// credentials, falls back to the group's credentials, and prompts the user
/// for credentials when nothing is configured.
Future<void> connectSavedHost(BuildContext context, WidgetRef ref, Host host) =>
    _connectSavedHost(context, ref, host);

/// Loads the private key PEMs and passphrase for the given identity.
Future<(List<String>, String?)> resolveKeyMaterial(
  WidgetRef ref,
  String? identityId,
) async {
  if (identityId == null) return (const <String>[], null);
  final db = ref.read(appDatabaseProvider);
  final vault = ref.read(vaultProvider);
  final identity = await db.findIdentityById(identityId);
  if (identity == null) return (const <String>[], null);
  final pem = await vault.decrypt(identity.encryptedKeyPem);
  String? passphrase;
  if (identity.encryptedPassphrase != null) {
    passphrase = await vault.decrypt(identity.encryptedPassphrase!);
  }
  return ([pem], passphrase);
}

Future<void> _connectSavedHost(
  BuildContext context,
  WidgetRef ref,
  Host host,
) async {
  final db = ref.read(appDatabaseProvider);
  await db.updateHostLastConnected(host.id, DateTime.now());

  var resolved = await resolveCredentials(ref, host);
  String? username = resolved?.username;
  String? password = resolved?.password;
  String? keyId = resolved?.keyId;

  if (username == null || username.isEmpty) {
    if (!context.mounted) return;
    final result = await promptCredentials(context, ref, host);
    if (result == null || !context.mounted) return;
    username = result.username;
    password = result.password;
  }

  ref
      .read(sessionManagerProvider)
      .openSession(
        HostConnectionRequest(
          displayName: host.name,
          address: host.address,
          port: host.port,
          username: username,
          password: password,
          identityId: keyId,
          os: host.os,
        ),
      );

  ref.read(appSectionProvider.notifier).state = AppSection.terminals;
}

class PromptResult {
  final String username;
  final String password;

  const PromptResult(this.username, this.password);
}

Future<PromptResult?> promptCredentials(
  BuildContext context,
  WidgetRef ref,
  Host host,
) async {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();

  void submit(BuildContext dialogContext) {
    final username = usernameController.text.trim();
    if (username.isEmpty) return;
    Navigator.of(
      dialogContext,
    ).pop(PromptResult(username, passwordController.text));
  }

  final result = await showDialog<PromptResult>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.lock_outline, color: AppColors.warning),
      title: Text('Credentials for ${host.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'No saved credentials for this host. Enter them to connect.',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: usernameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (_) => submit(context),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => submit(context),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
  return result;
}

/// Opens a terminal session for a quick-connect request.
Future<void> quickConnect(WidgetRef ref, HostConnectionRequest request) async {
  ref.read(sessionManagerProvider).openSession(request);
  ref.read(appSectionProvider.notifier).state = AppSection.terminals;
}
