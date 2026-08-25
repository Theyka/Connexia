import 'dart:convert';

import 'package:http/http.dart' as http;

/// Errors surfaced to the UI with a user-facing message.
class SyncApiException implements Exception {
  final String message;
  final int? statusCode;

  SyncApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// The account exists but has not verified its email yet; the UI should
/// show the verification-code step.
class EmailNotVerifiedException implements Exception {
  @override
  String toString() => 'emailNotVerified';
}

/// Result of a password login: either a session, or a 2FA challenge that
/// must be completed with a code from the authenticator app.
class LoginResult {
  final String? token;
  final String? userId;
  final String? challengeToken;

  const LoginResult({
    this.token,
    this.userId,
    this.challengeToken,
  });

  bool get needsTotp => challengeToken != null;
}

class AccountInfo {
  final bool emailVerified;
  final bool totpEnabled;

  const AccountInfo({required this.emailVerified, required this.totpEnabled});
}

class SyncSnapshot {
  final int revision;
  final String? blob;
  final DateTime? updatedAt;

  const SyncSnapshot({
    required this.revision,
    required this.blob,
    required this.updatedAt,
  });
}

/// HTTP client for the Connexia sync server.
class SyncApi {
  final String serverUrl;
  final String? token;

  SyncApi({required this.serverUrl, this.token});

  /// Joins a path onto the server URL. Trailing slashes on the server URL
  /// (e.g. `https://sync.connexia.run/`) are stripped so the path is never
  /// prefixed with `//`.
  Uri _uri(String path) =>
      Uri.parse('${serverUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<http.Response> _post(String path, Map<String, Object?> body) {
    return http
        .post(_uri(path), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
  }

  Future<http.Response> _put(String path, Map<String, Object?> body) {
    return http
        .put(_uri(path), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
  }

  Future<http.Response> _patch(String path, Map<String, Object?> body) {
    return http
        .patch(_uri(path), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
  }

  Future<http.Response> _delete(String path) {
    return http
        .delete(_uri(path), headers: _headers)
        .timeout(const Duration(seconds: 15));
  }

  /// Registers a new account. Returns the account id. The account must be
  /// verified by email before it can sign in.
  Future<String> register(String email, String password) async {
    final res = await _post('/api/register', {
      'email': email,
      'password': password,
    });
    if (res.statusCode == 201) {
      return (jsonDecode(res.body) as Map<String, dynamic>)['userId'] as String;
    }
    throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
  }

  /// Logs in with a password. Returns a session or a 2FA challenge.
  Future<LoginResult> login(String email, String password) async {
    final res = await _post('/api/login', {
      'email': email,
      'password': password,
    });
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['needsTotp'] == true) {
        return LoginResult(challengeToken: body['challengeToken'] as String);
      }
      return LoginResult(
        token: body['token'] as String,
        userId: body['userId'] as String,
      );
    }
    if (res.statusCode == 403 && _errorOf(res) == 'emailNotVerified') {
      throw EmailNotVerifiedException();
    }
    throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
  }

  /// Completes a 2FA login with the code from the authenticator app.
  Future<(String, String)> login2fa(String challengeToken, String code) async {
    final res = await _post('/api/login/2fa', {
      'challengeToken': challengeToken,
      'code': code,
    });
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return (body['token'] as String, body['userId'] as String);
    }
    throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
  }

  /// Confirms the 6-digit email verification code.
  Future<void> verifyEmail(String email, String code) async {
    final res = await _post('/api/verify-email', {
      'email': email,
      'code': code,
    });
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Requests a fresh verification code for [email].
  Future<void> resendVerification(String email) async {
    final res = await _post('/api/resend-verification', {'email': email});
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Fetches verification and 2FA status for the signed-in account.
  Future<AccountInfo> fetchAccount() async {
    final res = await http
        .get(_uri('/api/account'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return AccountInfo(
      emailVerified: body['emailVerified'] == true,
      totpEnabled: body['totpEnabled'] == true,
    );
  }

  /// Starts 2FA enrollment: generates a fresh TOTP secret. The secret only
  /// takes effect once confirmed with a code from the authenticator app.
  Future<(String secret, String otpauthUrl)> enable2fa() async {
    final res = await _post('/api/enable-2fa', const {});
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return (body['secret'] as String, body['otpauthUrl'] as String);
    }
    throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
  }

  /// Confirms 2FA enrollment with a code from the authenticator app.
  Future<void> confirm2fa(String code) async {
    final res = await _post('/api/confirm-2fa', {'code': code});
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Disables 2FA after validating a code from the authenticator app.
  Future<void> disable2fa(String code) async {
    final res = await _post('/api/disable-2fa', {'code': code});
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Permanently deletes the account and all of its data on the server.
  Future<void> deleteAccount() async {
    final res = await _post('/api/account/delete', const {});
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Pings the liveness endpoint. Returns false when the server does not
  /// answer in time — used to warn the user before signing out, since the
  /// session token would otherwise stay valid server-side until it expires.
  Future<bool> checkHealth() async {
    try {
      final res = await http
          .get(_uri('/api/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fetches the latest snapshot from the server.
  Future<SyncSnapshot> fetchSnapshot() async {
    final res = await http
        .get(_uri('/api/sync'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return SyncSnapshot(
      revision: (body['revision'] as num).toInt(),
      blob: body['blob'] as String?,
      updatedAt: body['updatedAt'] == null
          ? null
          : DateTime.tryParse(body['updatedAt'] as String),
    );
  }

  /// Uploads the next revision. Throws a 409 conflict error when the
  /// revision does not match the server's latest (fetch first).
  Future<void> pushSnapshot(int revision, String blob) async {
    final res = await _post('/api/sync', {
      'revision': revision,
      'blob': blob,
    });
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  // ---------- Team (workspace) endpoints ----------

  /// Fetches the current account's per-user keypair record (public key only;
  /// the private key stays on the client).
  Future<({bool hasKey, String? publicKey})> getUserKey() async {
    final res = await http
        .get(_uri('/api/me/key'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      hasKey: body['hasKey'] == true,
      publicKey: body['publicKey'] as String?,
    );
  }

  /// Uploads the account's keypair (public + password-wrapped private).
  Future<void> setUserKey({
    required String publicKey,
    required String wrappedPrivateKey,
  }) async {
    final res = await _post('/api/me/key', {
      'publicKey': publicKey,
      'wrappedPrivateKey': wrappedPrivateKey,
    });
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Lists workspaces the signed-in account is a member of.
  Future<List<WorkspaceSummary>> listWorkspaces() async {
    final res = await http
        .get(_uri('/api/workspaces'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (body['workspaces'] as List<dynamic>? ?? const [])
        .map((e) => _parseWorkspaceSummary(e as Map<String, dynamic>))
        .toList();
    return list;
  }

  /// Creates a workspace. The creator becomes the owner and must provide
  /// their own wrapped workspace key (the data key wrapped to their own
  /// public key).
  Future<({String id, String name, String role, int keyVersion})>
      createWorkspace({required String name, required String wrappedKey}) async {
    final res = await _post('/api/workspaces', {
      'name': name,
      'wrappedKey': wrappedKey,
    });
    if (res.statusCode != 201) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      id: body['id'] as String,
      name: body['name'] as String,
      role: body['role'] as String,
      keyVersion: (body['keyVersion'] as num).toInt(),
    );
  }

  /// Fetches the workspace detail (members, public keys, the caller's own
  /// wrapped workspace key).
  Future<WorkspaceDetail> getWorkspace(String id) async {
    final res = await http
        .get(_uri('/api/workspaces/$id'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _parseWorkspaceDetail(body);
  }

  /// Renames a workspace (owner/admin).
  Future<void> renameWorkspace(String id, String name) async {
    final res = await _patch('/api/workspaces/$id', {'name': name});
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Deletes a workspace (owner only).
  Future<void> deleteWorkspace(String id) async {
    final res = await _delete('/api/workspaces/$id');
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Looks up an account by email and returns its public key (for wrapping
  /// the workspace key).
  Future<({String userId, String publicKey, String email})> invite(
    String workspaceId,
    String email,
  ) async {
    final res = await _post('/api/workspaces/$workspaceId/invites', {
      'email': email,
    });
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      userId: body['userId'] as String,
      publicKey: body['publicKey'] as String,
      email: body['email'] as String,
    );
  }

  /// Adds or updates a member with the given role and wrapped key.
  Future<void> addMember(
    String workspaceId,
    String userId, {
    required String role,
    required String wrappedKey,
  }) async {
    final res = await _put('/api/workspaces/$workspaceId/members/$userId', {
      'role': role,
      'wrappedKey': wrappedKey,
    });
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Sets a member's role (owner only).
  Future<void> setMemberRole(
    String workspaceId,
    String userId,
    String role,
  ) async {
    final res = await _patch('/api/workspaces/$workspaceId/members/$userId', {
      'role': role,
    });
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Removes a member (owner/admin) or self-leave.
  Future<void> removeMember(String workspaceId, String userId) async {
    final res = await _delete('/api/workspaces/$workspaceId/members/$userId');
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Rotates the workspace key: replaces the member list with new wrapped
  /// shares and bumps keyVersion on the server.
  Future<int> keyRotate(
    String workspaceId,
    List<({String userId, String role, String wrappedKey})> members,
  ) async {
    final res = await _post('/api/workspaces/$workspaceId/key-rotate', {
      'members': members
          .map((m) => {
                'userId': m.userId,
                'role': m.role,
                'wrappedKey': m.wrappedKey,
              })
          .toList(),
    });
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['keyVersion'] as num).toInt();
  }

  /// Fetches the workspace's encrypted snapshot.
  Future<SyncSnapshot> fetchWorkspaceSnapshot(String workspaceId) async {
    final res = await http
        .get(_uri('/api/workspaces/$workspaceId/sync'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return SyncSnapshot(
      revision: (body['revision'] as num).toInt(),
      blob: body['blob'] as String?,
      updatedAt: body['updatedAt'] == null
          ? null
          : DateTime.tryParse(body['updatedAt'] as String),
    );
  }

  /// Uploads the next workspace revision. [actions] is an optional list of
  /// plaintext metadata (action type + target) reported by the client to be
  /// recorded in the audit log alongside the server-recorded push event.
  Future<void> pushWorkspaceSnapshot(
    String workspaceId,
    int revision,
    String blob, {
    List<({String action, String target})> actions = const [],
  }) async {
    final res = await _post('/api/workspaces/$workspaceId/sync', {
      'revision': revision,
      'blob': blob,
      'actions': actions
          .map((a) => {'action': a.action, 'target': a.target})
          .toList(),
    });
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
  }

  /// Lists audit events for a workspace (owner/admin).
  Future<List<AuditEvent>> auditEvents(
    String workspaceId, {
    String? actor,
    String? action,
    int limit = 100,
    int offset = 0,
  }) async {
    final qp = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
    };
    if (actor != null) qp['actor'] = actor;
    if (action != null) qp['action'] = action;
    final uri = _uri('/api/workspaces/$workspaceId/audit')
        .replace(queryParameters: qp);
    final res = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw SyncApiException(_errorOf(res), statusCode: res.statusCode);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (body['events'] as List<dynamic>? ?? const [])
        .map((e) => _parseAuditEvent(e as Map<String, dynamic>))
        .toList();
    return list;
  }

  static String _errorOf(http.Response res) {
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final message = body['error'] as String?;
      if (message != null && message.isNotEmpty) return message;
    } catch (_) {}
    return 'Server error (HTTP ${res.statusCode})';
  }
}

// ---------- Workspace data classes ----------

class WorkspaceSummary {
  final String id;
  final String name;
  final String role;
  final int memberCount;
  final int keyVersion;
  final DateTime? createdAt;
  final String? createdBy;

  const WorkspaceSummary({
    required this.id,
    required this.name,
    required this.role,
    required this.memberCount,
    required this.keyVersion,
    this.createdAt,
    this.createdBy,
  });
}

class WorkspaceMember {
  final String userId;
  final String email;
  final String role;
  final DateTime? joinedAt;
  final String? publicKey;
  final String? wrappedKey;

  const WorkspaceMember({
    required this.userId,
    required this.email,
    required this.role,
    this.joinedAt,
    this.publicKey,
    this.wrappedKey,
  });
}

class WorkspaceDetail {
  final String id;
  final String name;
  final String? createdBy;
  final DateTime? createdAt;
  final int keyVersion;
  final String myRole;
  final List<WorkspaceMember> members;

  const WorkspaceDetail({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdAt,
    required this.keyVersion,
    required this.myRole,
    required this.members,
  });
}

class AuditEvent {
  final String id;
  final String workspaceId;
  final String actorId;
  final String? actorEmail;
  final String action;
  final String target;
  final int revision;
  final String ip;
  final String source;
  final DateTime? createdAt;

  const AuditEvent({
    required this.id,
    required this.workspaceId,
    required this.actorId,
    required this.actorEmail,
    required this.action,
    required this.target,
    required this.revision,
    required this.ip,
    required this.source,
    required this.createdAt,
  });
}

WorkspaceSummary _parseWorkspaceSummary(Map<String, dynamic> json) {
  return WorkspaceSummary(
    id: json['id'] as String,
    name: json['name'] as String,
    role: json['role'] as String,
    memberCount: (json['memberCount'] as num).toInt(),
    keyVersion: (json['keyVersion'] as num).toInt(),
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    createdBy: json['createdBy'] as String?,
  );
}

WorkspaceDetail _parseWorkspaceDetail(Map<String, dynamic> json) {
  final members = (json['members'] as List<dynamic>? ?? const [])
      .map((e) {
        final m = e as Map<String, dynamic>;
        return WorkspaceMember(
          userId: m['userId'] as String,
          email: m['email'] as String,
          role: m['role'] as String,
          joinedAt: DateTime.tryParse(m['joinedAt'] as String? ?? ''),
          publicKey: m['publicKey'] as String?,
          wrappedKey: m['wrappedKey'] as String?,
        );
      })
      .toList();
  return WorkspaceDetail(
    id: json['id'] as String,
    name: json['name'] as String,
    createdBy: json['createdBy'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    keyVersion: (json['keyVersion'] as num).toInt(),
    myRole: json['myRole'] as String,
    members: members,
  );
}

AuditEvent _parseAuditEvent(Map<String, dynamic> json) {
  return AuditEvent(
    id: json['id'] as String,
    workspaceId: json['workspaceId'] as String,
    actorId: json['actorId'] as String,
    actorEmail: json['actorEmail'] as String?,
    action: json['action'] as String,
    target: json['target'] as String,
    revision: (json['revision'] as num).toInt(),
    ip: json['ip'] as String,
    source: json['source'] as String,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
  );
}
