import '../crypto/vault.dart';
import '../db/database.dart';

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

Future<ResolvedCredentials?> resolveHostCredentials(
  AppDatabase db,
  Vault vault,
  Host host,
) async {
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

  final username = host.username.isNotEmpty
      ? host.username
      : (group?.username ?? '');
  final authType = host.authType.isNotEmpty
      ? host.authType
      : (group?.authType ?? '');

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
