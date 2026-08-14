import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/ssh/session_manager.dart';
import '../theme/app_colors.dart';
import 'nav.dart';
import 'providers.dart';

/// Effective credentials resolved for a host, honouring group inheritance.
class ResolvedCredentials {
  final String username;
  final String authType;
  final String? password;
  final String? keyId;

  const ResolvedCredentials({
    required this.username,
    required this.authType,
    this.password,
    this.keyId,
  });
}

/// Resolves credentials for [host]: the host's own credentials win, otherwise
/// the credentials of its group are used. Returns null when no credentials
/// can be resolved (the user must be prompted).
Future<ResolvedCredentials?> resolveCredentials(
  WidgetRef ref,
  Host host,
) async {
  final db = ref.read(appDatabaseProvider);
  final vault = ref.read(vaultProvider);

  Group? group;
  if (host.groupId != null) {
    final groups = await db.allGroups();
    for (final g in groups) {
      if (g.id == host.groupId) {
        group = g;
        break;
      }
    }
  }

  final username =
      host.username.isNotEmpty ? host.username : (group?.username ?? '');
  final authType =
      host.authType.isNotEmpty ? host.authType : (group?.authType ?? '');

  if (username.isEmpty) return null;

  String? password;
  String? keyId;
  if (authType == 'password') {
    final encrypted = host.encryptedPassword ?? group?.encryptedPassword;
    if (encrypted != null) {
      try {
        password = await vault.decrypt(encrypted);
      } catch (_) {
        password = null;
      }
    }
  } else if (authType == 'key') {
    keyId = host.keyId ?? group?.keyId;
  }

  if (authType == 'key' && keyId == null) return null;

  return ResolvedCredentials(
    username: username,
    authType: authType,
    password: password,
    keyId: keyId,
  );
}

/// Opens a terminal session for a saved host. Uses the host's own
/// credentials, falls back to the group's credentials, and prompts the user
/// for credentials when nothing is configured.
Future<void> connectSavedHost(
  BuildContext context,
  WidgetRef ref,
  Host host,
) =>
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

  ref.read(sessionManagerProvider).openSession(
        HostConnectionRequest(
          displayName: host.name,
          address: host.address,
          port: host.port,
          username: username,
          password: password,
          identityId: keyId,
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
    Navigator.of(dialogContext).pop(
      PromptResult(username, passwordController.text),
    );
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
