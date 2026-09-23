import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/host_protocol.dart';
import '../../core/ssh/host_credentials.dart';
import '../../core/ssh/session_manager.dart';
import '../theme/app_colors.dart';
import 'nav.dart';
import 'providers.dart';

export '../../core/ssh/host_credentials.dart' show ResolvedCredentials;

Future<ResolvedCredentials?> resolveCredentials(WidgetRef ref, Host host) =>
    resolveHostCredentials(
      ref.read(appDatabaseProvider),
      ref.read(vaultProvider),
      host,
    );

Future<void> connectSavedHost(BuildContext context, WidgetRef ref, Host host) =>
    _connectSavedHost(context, ref, host);

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

/// Opens a graphical (RDP/VNC) session and switches to the remote desktop
/// section.
void openGraphicalSession(
  WidgetRef ref, {
  required String title,
  required HostProtocol protocol,
  required String address,
  required int port,
  String? username,
  String? password,
  String? domain,
}) {
  ref
      .read(remoteManagerProvider)
      .open(
        title: title,
        protocol: protocol,
        address: address,
        port: port,
        username: username,
        password: password,
        domain: domain,
      );
  ref.read(appSectionProvider.notifier).state = AppSection.remotes;
  ref.read(liveSessionViewProvider.notifier).state = true;
}

/// One-time-per-host acknowledgement before connecting to an unencrypted
/// protocol (for example Telnet, which sends credentials in plain text).
Future<bool> confirmInsecureProtocol(
  BuildContext context,
  WidgetRef ref,
  HostProtocol protocol,
  String keySuffix,
) async {
  if (protocol.isEncrypted) return true;

  final db = ref.read(appDatabaseProvider);
  final key = 'insecureConnectAck:${protocol.id}:$keySuffix';
  if (await db.getSetting(key) == 'true') return true;

  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
      title: Text('${protocol.label} is not encrypted'),
      content: Text(
        '${protocol.label} sends everything you type, including passwords, '
        'over the network in plain text. Only continue on a network and host '
        'you trust.',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );

  if (confirmed == true) {
    await db.setSetting(key, 'true');
    return true;
  }
  return false;
}

Future<void> _connectSavedHost(
  BuildContext context,
  WidgetRef ref,
  Host host,
) async {
  final protocol = HostProtocol.fromId(host.protocol);

  if (protocol.isGraphical) {
    final resolved = await resolveCredentials(ref, host);
    var username = resolved?.username;
    var password = resolved?.password;

    final needsUsername =
        protocol == HostProtocol.rdp && (username == null || username.isEmpty);
    final needsPassword = password == null || password.isEmpty;

    if (needsUsername) {
      if (!context.mounted) return;
      final result = await promptCredentials(context, ref, host);
      if (result == null || !context.mounted) return;
      username = result.username;
      password = result.password;
    } else if (needsPassword) {
      if (!context.mounted) return;
      final secret = await promptSecret(
        context,
        title: 'Password for ${host.name}',
        label: 'Password',
      );
      if (secret == null || !context.mounted) return;
      password = secret;
    }

    final db = ref.read(appDatabaseProvider);
    await db.updateHostLastConnected(host.id, DateTime.now());
    openGraphicalSession(
      ref,
      title: host.name,
      protocol: protocol,
      address: host.address,
      port: host.port,
      username: username,
      password: password,
      domain: host.domain,
    );
    return;
  }

  if (!await confirmInsecureProtocol(context, ref, protocol, host.id)) return;
  if (!context.mounted) return;

  final db = ref.read(appDatabaseProvider);
  await db.updateHostLastConnected(host.id, DateTime.now());

  String? username;
  String? password;
  String? keyId;

  if (protocol == HostProtocol.ssh) {
    final resolved = await resolveCredentials(ref, host);
    username = resolved?.username;
    password = resolved?.password;
    keyId = resolved?.keyId;

    if (username == null || username.isEmpty) {
      if (!context.mounted) return;
      final result = await promptCredentials(context, ref, host);
      if (result == null || !context.mounted) return;
      username = result.username;
      password = result.password;
    }
  }

  ref
      .read(sessionManagerProvider)
      .openSession(
        HostConnectionRequest(
          displayName: host.name,
          address: host.address,
          port: host.port,
          username: username ?? '',
          password: password,
          identityId: keyId,
          os: host.os,
          protocol: host.protocol,
          domain: host.domain,
        ),
      );

  ref.read(appSectionProvider.notifier).state = AppSection.terminals;
  ref.read(liveSessionViewProvider.notifier).state = true;
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

Future<String?> promptSecret(
  BuildContext context, {
  required String title,
  required String label,
}) async {
  final controller = TextEditingController();

  void submit(BuildContext dialogContext) {
    if (controller.text.isEmpty) return;
    Navigator.of(dialogContext).pop(controller.text);
  }

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.lock_outline, color: AppColors.warning),
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (_) => submit(context),
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
}

Future<void> quickConnect(WidgetRef ref, HostConnectionRequest request) async {
  ref.read(sessionManagerProvider).openSession(request);
  ref.read(appSectionProvider.notifier).state = AppSection.terminals;
  ref.read(liveSessionViewProvider.notifier).state = true;
}
