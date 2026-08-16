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

  static String _errorOf(http.Response res) {
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final message = body['error'] as String?;
      if (message != null && message.isNotEmpty) return message;
    } catch (_) {}
    return 'Server error (HTTP ${res.statusCode})';
  }
}
