import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/state/providers.dart';
import '../crypto/secret_storage.dart';
import '../crypto/vault.dart';
import '../db/database.dart';
import 'snapshot.dart';
import 'sync_api.dart';
import 'sync_crypto.dart';

/// Account/sync state shown in the settings UI.
enum SyncStatus { signedOut, signedIn }

class SyncState {
  final SyncStatus status;
  final String serverUrl;
  final String? email;
  final String? userId;
  final bool busy;
  final bool pendingSync;
  final String? error;
  final DateTime? lastSyncedAt;
  final int revision;

  /// True while a just-registered (or just-logged-in) account still needs
  /// its email verification code to be entered.
  final bool pendingVerification;

  /// True while a login is waiting for the 2FA code.
  final bool totpChallenge;

  final bool emailVerified;
  final bool totpEnabled;

  const SyncState({
    this.status = SyncStatus.signedOut,
    this.serverUrl = '',
    this.email,
    this.userId,
    this.busy = false,
    this.pendingSync = false,
    this.error,
    this.lastSyncedAt,
    this.revision = 0,
    this.pendingVerification = false,
    this.totpChallenge = false,
    this.emailVerified = false,
    this.totpEnabled = false,
  });

  SyncState copyWith({
    SyncStatus? status,
    String? serverUrl,
    String? email,
    String? userId,
    bool? busy,
    bool? pendingSync,
    String? error,
    DateTime? lastSyncedAt,
    int? revision,
    bool? pendingVerification,
    bool? totpChallenge,
    bool? emailVerified,
    bool? totpEnabled,
  }) {
    return SyncState(
      status: status ?? this.status,
      serverUrl: serverUrl ?? this.serverUrl,
      email: email ?? this.email,
      userId: userId ?? this.userId,
      busy: busy ?? this.busy,
      pendingSync: pendingSync ?? this.pendingSync,
      error: error ?? this.error,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      revision: revision ?? this.revision,
      pendingVerification: pendingVerification ?? this.pendingVerification,
      totpChallenge: totpChallenge ?? this.totpChallenge,
      emailVerified: emailVerified ?? this.emailVerified,
      totpEnabled: totpEnabled ?? this.totpEnabled,
    );
  }
}

/// Owns the optional cloud-sync account: session persistence, encryption
/// key derivation and the pull/push reconcile loop.
///
/// Local-first: without an account nothing changes. With an account, local
/// edits are pushed automatically (debounced) and the server's snapshot is
/// pulled at startup. Conflicts resolve last-write-wins by timestamp.
class SyncController extends Notifier<SyncState> {
  static const _tokenKey = 'connexia_sync_token';
  static const _keyKey = 'connexia_sync_key';
  static const _accountKey = 'connexia_sync_account';
  static const _hashKey = 'syncLastPayloadHash';
  static const _vaultKeySetting = 'vaultMasterKey';

  String? _token;
  SecretKey? _key;
  bool _importing = false;
  bool _settled = false;
  Timer? _pushTimer;
  DateTime _suppressEmissionsUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Chains sync operations so pulls and pushes never interleave. Without
  /// this, overlapping operations (startup reconcile + debounced push, or
  /// several pushes during a burst of local edits) hit 409 conflicts and
  /// re-import the whole snapshot, rebuilding every table on a UI thread
  /// that is already busy connecting sessions.
  Future<void> _syncQueue = Future.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _syncQueue.then((_) => action());
    _syncQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  AppDatabase get _db => ref.read(appDatabaseProvider);
  Vault get _vault => ref.read(vaultProvider);
  SecretStorage get _storage => ref.read(secretStorageProvider);

  @override
  SyncState build() {
    _loadSession();
    ref.listen(hostsProvider, (_, _) => _onLocalDataChange());
    ref.listen(groupsProvider, (_, _) => _onLocalDataChange());
    ref.listen(identitiesProvider, (_, _) => _onLocalDataChange());
    ref.listen(knownHostsProvider, (_, _) => _onLocalDataChange());
    ref.listen(snippetsProvider, (_, _) => _onLocalDataChange());
    ref.listen(themesProvider, (_, _) => _onLocalDataChange());
    ref.listen(sessionLogsProvider, (_, _) => _onLocalDataChange());
    ref.listen(settingsControllerProvider, (_, _) => _onLocalDataChange());
    return const SyncState();
  }

  void setServerUrl(String url) {
    state = state.copyWith(
      serverUrl: url.trim(),
      error: null,
    );
    if (state.status == SyncStatus.signedOut && state.serverUrl.isNotEmpty) {
      _db.setSetting('syncServerUrl', state.serverUrl);
    }
  }

  Future<void> _loadSession() async {
    var url = await _db.getSetting('syncServerUrl') ?? '';
    var email = await _db.getSetting('syncEmail');
    var userId = await _db.getSetting('syncUserId');
    final revision = int.tryParse(await _db.getSetting('syncRevision') ?? '') ?? 0;
    _token = await _storage.read(_tokenKey);
    final wrapped = await _storage.read(_keyKey);
    if (email == null || userId == null || url.isEmpty) {
      // Settings may have been wiped by an import on an older build; the
      // account info is also kept in secret storage as a fallback.
      final account = await _storage.read(_accountKey);
      if (account != null) {
        try {
          final map = jsonDecode(account) as Map<String, dynamic>;
          url = map['url'] as String? ?? url;
          email ??= map['email'] as String?;
          userId ??= map['userId'] as String?;
          await _db.setSetting('syncServerUrl', url);
          if (email != null) await _db.setSetting('syncEmail', email);
          if (userId != null) await _db.setSetting('syncUserId', userId);
        } catch (_) {}
      }
    }
    if (_token == null || wrapped == null || email == null || userId == null) {
      if (email == null && userId == null) return;
      // Session meta exists but secrets are gone: require a fresh login.
      await _clearSessionMeta();
      return;
    }
    try {
      final clear = await _vault.decrypt(wrapped);
      _key = SecretKey(base64Decode(clear));
    } catch (_) {
      await _clearSessionMeta();
      return;
    }
    // Adopt the synced vault key (if another device seeded one) so vault-
    // encrypted secrets decrypt on this device too. The adoption re-wraps
    // the sync key above, so the session survives the switch.
    try {
      await _adoptVaultKeyIfNeeded();
    } catch (_) {}
    state = SyncState(
      status: SyncStatus.signedIn,
      serverUrl: url,
      email: email,
      userId: userId,
      revision: revision,
    );
    _loadAccountInfo();
    // Pull the server snapshot shortly after startup.
    Future.delayed(
      const Duration(milliseconds: 1200),
      () => _serialize(_reconcile),
    );
  }

  bool get _signedIn => state.status == SyncStatus.signedIn && _key != null;

  SyncApi _api() => SyncApi(serverUrl: state.serverUrl, token: _token);

  /// Pending auth credentials, kept in memory only for the verification and
  /// 2FA steps (never persisted) and cleared when the flow finishes.
  String? _pendingEmail;
  String? _pendingPassword;
  String? _challengeToken;

  /// Registers a new account. The account must verify its email before it
  /// can sign in; the UI then shows the verification step.
  Future<void> register(String email, String password) async {
    final address = email.trim();
    if (state.busy) return;
    if (state.serverUrl.trim().isEmpty) {
      state = state.copyWith(error: 'Enter your sync server URL first');
      return;
    }
    state = state.copyWith(busy: true, error: null);
    try {
      await _api().register(address, password);
      _pendingEmail = address;
      _pendingPassword = password;
      state = state.copyWith(busy: false, pendingVerification: true);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  /// Signs in with an email and password. May transition into the email
  /// verification step (new/unverified account) or the 2FA step.
  Future<void> login(String email, String password) async {
    final address = email.trim();
    await _authenticate(
      () => _api().login(address, password),
      address,
      password,
    );
  }

  Future<void> _authenticate(
    Future<LoginResult> Function() authCall,
    String email,
    String password,
  ) async {
    if (state.busy) return;
    if (state.serverUrl.trim().isEmpty) {
      state = state.copyWith(error: 'Enter your sync server URL first');
      return;
    }
    state = state.copyWith(busy: true, error: null);
    try {
      final result = await authCall();
      if (result.needsTotp) {
        _pendingEmail = email;
        _pendingPassword = password;
        _challengeToken = result.challengeToken;
        state = state.copyWith(busy: false, totpChallenge: true, error: null);
        return;
      }
      await _completeSession(result.token!, result.userId!, email, password);
    } on EmailNotVerifiedException {
      _pendingEmail = email;
      _pendingPassword = password;
      state = state.copyWith(busy: false, pendingVerification: true);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  /// Completes the email verification step with the 6-digit code and signs
  /// in with the pending credentials.
  Future<void> verifyEmail(String code) async {
    final email = _pendingEmail;
    final password = _pendingPassword;
    if (email == null || password == null) return;
    state = state.copyWith(busy: true, error: null);
    try {
      await _api().verifyEmail(email, code);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
      return;
    }
    await _authenticate(() => _api().login(email, password), email, password);
  }

  /// Requests a fresh email verification code.
  Future<void> resendVerification() async {
    final email = _pendingEmail;
    if (email == null || state.busy) return;
    state = state.copyWith(busy: true, error: null);
    try {
      await _api().resendVerification(email);
      state = state.copyWith(busy: false, error: null);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  /// Completes the 2FA login step with the code from the authenticator app.
  Future<void> completeTotpLogin(String code) async {
    final email = _pendingEmail;
    final password = _pendingPassword;
    final challenge = _challengeToken;
    if (email == null || password == null || challenge == null) return;
    state = state.copyWith(busy: true, error: null);
    try {
      final (token, userId) = await _api().login2fa(challenge, code);
      await _completeSession(token, userId, email, password);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  /// Abandons a pending verification or 2FA login and returns to the form.
  void cancelPendingAuth() {
    _pendingEmail = null;
    _pendingPassword = null;
    _challengeToken = null;
    state = state.copyWith(
      busy: false,
      pendingVerification: false,
      totpChallenge: false,
      error: null,
    );
  }

  /// Stores the session after a successful login.
  Future<void> _completeSession(
    String token,
    String userId,
    String email,
    String password,
  ) async {
    _token = token;
    _key = await SyncCrypto.deriveKey(password, userId);
    final bytes = await _key!.extractBytes();
    final wrapped = await _vault.encrypt(base64Encode(bytes));
    await _storage.write(_tokenKey, token);
    await _storage.write(_keyKey, wrapped);
    await _storage.write(
      _accountKey,
      jsonEncode({
        'url': state.serverUrl.trim(),
        'email': email.trim().toLowerCase(),
        'userId': userId,
      }),
    );
    await _db.setSetting('syncServerUrl', state.serverUrl.trim());
    await _db.setSetting('syncEmail', email.trim().toLowerCase());
    await _db.setSetting('syncUserId', userId);
    _pendingEmail = null;
    _pendingPassword = null;
    _challengeToken = null;
    state = SyncState(
      status: SyncStatus.signedIn,
      serverUrl: state.serverUrl.trim(),
      email: email.trim().toLowerCase(),
      userId: userId,
    );
    _loadAccountInfo();
    await _serialize(_reconcile);
  }

  /// Refreshes email-verification and 2FA status from the server.
  Future<void> _loadAccountInfo() async {
    try {
      final info = await _api().fetchAccount();
      state = state.copyWith(
        emailVerified: info.emailVerified,
        totpEnabled: info.totpEnabled,
      );
    } catch (_) {
      // The account endpoints are best-effort; a transient failure must
      // never break the signed-in flow.
    }
  }

  /// Starts 2FA enrollment. Returns the generated secret and its
  /// otpauth:// URL for the authenticator app, or null on failure (the
  /// error is already surfaced in [SyncState.error]).
  Future<(String secret, String otpauthUrl)?> enable2fa() async {
    if (!_signedIn) return null;
    try {
      return await _api().enable2fa();
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
      return null;
    }
  }

  /// Confirms 2FA enrollment with a code from the authenticator app.
  Future<bool> confirm2fa(String code) async {
    if (!_signedIn) return false;
    try {
      await _api().confirm2fa(code);
      state = state.copyWith(totpEnabled: true, error: null);
      return true;
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
      return false;
    }
  }

  /// Disables 2FA after validating a code from the authenticator app.
  Future<bool> disable2fa(String code) async {
    if (!_signedIn) return false;
    try {
      await _api().disable2fa(code);
      state = state.copyWith(totpEnabled: false, error: null);
      return true;
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
      return false;
    }
  }

  Future<void> signOut() async {
    _pushTimer?.cancel();
    await _storage.delete(_tokenKey);
    await _storage.delete(_keyKey);
    await _storage.delete(_accountKey);
    await _clearSessionMeta();
    _token = null;
    _key = null;
    _settled = false;
    state = const SyncState();
  }

  Future<void> _clearSessionMeta() async {
    await _db.setSetting('syncServerUrl', state.serverUrl);
    await _db.setSetting('syncEmail', '');
    await _db.setSetting('syncUserId', '');
    await _db.setSetting('syncRevision', '0');
    await _db.setSetting('syncLastPulledAt', '');
    await _db.setSetting('syncLastLocalWriteAt', '');
    await _db.setSetting('syncDirty', 'false');
  }

  /// Writes this device's vault master key into the synced settings (once)
  /// so the key can reach every other device sharing the account.
  Future<void> _seedVaultKey() async {
    if (await _db.getSetting(_vaultKeySetting) != null) return;
    final key = await _vault.exportKey();
    if (key == null) return;
    await _db.setSetting(_vaultKeySetting, key);
  }

  /// After a snapshot import, switch the vault to the other device's master
  /// key and re-encrypt any secrets that were created on this device with
  /// this device's old key, so both decrypt on both devices.
  Future<void> _adoptVaultKeyIfNeeded() async {
    final remoteKey = await _db.getSetting(_vaultKeySetting);
    if (remoteKey == null || remoteKey.isEmpty) return;
    final localKey = await _vault.exportKey();
    if (localKey == remoteKey) return;

    Future<String?> reencrypt(String? blob) async {
      if (blob == null || blob.isEmpty) return blob;
      await _vault.adoptKey(remoteKey);
      try {
        await _vault.decrypt(blob);
        return blob;
      } catch (_) {}
      if (localKey == null) return blob;
      await _vault.adoptKey(localKey);
      String clear;
      try {
        clear = await _vault.decrypt(blob);
      } catch (_) {
        await _vault.adoptKey(remoteKey);
        return blob;
      }
      await _vault.adoptKey(remoteKey);
      return _vault.encrypt(clear);
    }

    for (final host in await _db.allHosts()) {
      final blob = await reencrypt(host.encryptedPassword);
      if (blob != host.encryptedPassword) {
        await _db.upsertHost(
          HostsCompanion(
            id: Value(host.id),
            encryptedPassword: Value(blob),
          ),
        );
      }
    }
    for (final group in await _db.allGroups()) {
      final blob = await reencrypt(group.encryptedPassword);
      if (blob != group.encryptedPassword) {
        await _db.upsertGroup(
          GroupsCompanion(
            id: Value(group.id),
            encryptedPassword: Value(blob),
          ),
        );
      }
    }
    for (final identity in await _db.allIdentities()) {
      final keyBlob = await reencrypt(identity.encryptedKeyPem);
      final passBlob = await reencrypt(identity.encryptedPassphrase);
      if (keyBlob != identity.encryptedKeyPem ||
          passBlob != identity.encryptedPassphrase) {
        await _db.upsertIdentity(
          IdentitiesCompanion(
            id: Value(identity.id),
            encryptedKeyPem: Value(keyBlob ?? ''),
            encryptedPassphrase: Value(passBlob),
          ),
        );
      }
    }
    await _vault.adoptKey(remoteKey);
    // The stored sync key was wrapped with the old vault key: re-wrap it so
    // the session survives the switch.
    final key = _key;
    if (key != null) {
      final bytes = await key.extractBytes();
      await _storage.write(
        _keyKey,
        await _vault.encrypt(base64Encode(bytes)),
      );
    }
  }

  /// Full pull-then-push reconciliation. Also used by "Sync now".
  Future<void> syncNow() async {
    if (!_signedIn) return;
    state = state.copyWith(busy: true, error: null);
    try {
      await _serialize(() async {
        await _reconcile();
        if (await _isDirty() && !_importing) {
          await _pushChanges();
        }
      });
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> _reconcile() async {
    if (!_signedIn) return;
    // Make sure the snapshot this device exports carries its vault master
    // key, so every device sharing the account can decrypt the same
    // vault-encrypted secrets (host passwords, private keys, ...).
    await _seedVaultKey();
    final local = await exportSnapshot(_db);
    final localRev = await _getInt('syncRevision');
    final remote = await _api().fetchSnapshot();

    if (remote.revision == localRev) {
      if (await _isDirty()) {
        await _push(local, remote.revision);
      } else if (remote.blob == null || remote.updatedAt == null) {
        // Server has no snapshot yet: seed it with local data (first
        // sign-in, or the account was never pushed from any device).
        if (!local.isEmpty) {
          await _push(local, remote.revision);
        } else {
          await _setInt('syncRevision', remote.revision);
          state = state.copyWith(
            revision: remote.revision,
            pendingSync: false,
            error: null,
          );
        }
      } else if (remote.updatedAt != null) {
        await _setInt('syncRevision', remote.revision);
        await _setSetting('syncLastPulledAt', remote.updatedAt!.toIso8601String());
        state = state.copyWith(
          lastSyncedAt: remote.updatedAt,
          revision: remote.revision,
          pendingSync: false,
          error: null,
        );
      }
      _settled = true;
      return;
    }

    if (remote.blob == null || remote.revision == 0) {
      // Server is empty: seed it with whatever is on this device.
      if (!local.isEmpty) {
        await _push(local, 0);
      } else {
        await _setInt('syncRevision', 0);
        await _setDirty(false);
        state = state.copyWith(revision: 0, pendingSync: false, error: null);
      }
      _settled = true;
      return;
    }

    final remotePayload = SyncPayload.decode(
      await _decryptRemote(remote.blob!),
    );
    final remoteModified = remote.updatedAt ?? remotePayload.modifiedAt;
    final dirty = await _isDirty();
    final remoteHash = await _hashData(remotePayload.data);
    final unchanged = remoteHash == await _db.getSetting(_hashKey);

    if (!dirty) {
      // No local edits since the last sync: take the server snapshot.
      if (unchanged) {
        // Same content we already have (echo push from another device):
        // skip the import to avoid wiping and rebuilding every table.
        await _setInt('syncRevision', remote.revision);
        await _setSetting(
            'syncLastPulledAt', remote.updatedAt?.toIso8601String() ?? '');
        state = state.copyWith(
          lastSyncedAt: remote.updatedAt,
          revision: remote.revision,
          pendingSync: false,
          error: null,
        );
      } else {
        await _import(remotePayload.data, remote);
        await _setSetting(_hashKey, remoteHash);
      }
    } else {
      // Conflict: last-write-wins by timestamp.
      final localModified = _maxTime(
        await _getTime('syncLastLocalWriteAt'),
        local.modifiedAt,
      );
      if (remoteModified.isAfter(localModified)) {
        if (unchanged) {
          await _setInt('syncRevision', remote.revision);
          await _setDirty(false);
          state = state.copyWith(
            lastSyncedAt: remote.updatedAt,
            revision: remote.revision,
            pendingSync: false,
            error: null,
          );
        } else {
          await _import(remotePayload.data, remote);
          await _setDirty(false);
          await _setSetting(_hashKey, remoteHash);
        }
      } else {
        await _push(local, remote.revision);
      }
    }
    _settled = true;
  }

  /// Wipes and rebuilds the local tables from the server snapshot, then
  /// refreshes the in-memory settings controllers.
  Future<void> _import(
    SyncSnapshotData data,
    SyncSnapshot fetchResult,
  ) async {
    _importing = true;
    try {
      await importSnapshot(_db, data);
      await ref.read(settingsControllerProvider).load();
    } finally {
      _importing = false;
    }
    // The imported snapshot may carry another device's vault master key:
    // switch to it and re-encrypt locally-created secrets accordingly.
    await _adoptVaultKeyIfNeeded();
    await _setInt('syncRevision', fetchResult.revision);
    await _setSetting(
        'syncLastPulledAt', fetchResult.updatedAt?.toIso8601String() ?? '');
    _suppressEmissionsUntil = DateTime.now().add(const Duration(seconds: 3));
    state = state.copyWith(
      lastSyncedAt: fetchResult.updatedAt,
      revision: fetchResult.revision,
      pendingSync: false,
      error: null,
    );
  }

  Future<void> _push(SyncSnapshotData data, int baseRevision) async {
    final payload = buildPayload(data, modifiedAt: DateTime.now());
    final keyBytes = await _key!.extractBytes();
    final encoded = payload.encode();
    // AES-GCM of the whole snapshot is CPU-heavy: run it off the UI thread
    // so a push never stalls rendering.
    final encrypted = await Isolate.run(
      () => SyncCrypto.encryptString(encoded, SecretKey(keyBytes)),
    );
    try {
      await _api().pushSnapshot(baseRevision, encrypted);
    } on SyncApiException catch (e) {
      if (e.statusCode == 409) {
        // Another device pushed first: re-pull and decide again.
        await _reconcile();
        return;
      }
      rethrow;
    }
    await _setInt('syncRevision', baseRevision + 1);
    await _setSetting(_hashKey, await _hashData(data));
    await _setDirty(false);
    state = state.copyWith(
      lastSyncedAt: DateTime.now(),
      revision: baseRevision + 1,
      pendingSync: false,
      error: null,
    );
  }

  void _onLocalDataChange() {
    if (!_signedIn || _importing || !_settled) return;
    if (DateTime.now().isBefore(_suppressEmissionsUntil)) return;
    _pushTimer?.cancel();
    _db.setSetting('syncDirty', 'true');
    _db.setSetting('syncLastLocalWriteAt', DateTime.now().toIso8601String());
    state = state.copyWith(pendingSync: true, error: null);
    _pushTimer = Timer(const Duration(seconds: 3), () {
      if (!_signedIn) return;
      _serialize(_pushChanges);
    });
  }

  Future<void> _pushChanges() async {
    try {
      final remote = await _api().fetchSnapshot();
      final localRev = await _getInt('syncRevision');
      if (remote.revision != localRev) {
        // Server moved ahead of our view: reconcile instead of pushing.
        await _reconcile();
        return;
      }
      final local = await exportSnapshot(_db);
      if (local.isEmpty) {
        await _setDirty(false);
        state = state.copyWith(pendingSync: false);
        return;
      }
      if (await _hashData(local) == await _db.getSetting(_hashKey)) {
        // Nothing actually changed since the last sync (the "dirty" flag
        // was set by the app's own import/stream echo): drop the push.
        await _setDirty(false);
        state = state.copyWith(pendingSync: false, error: null);
        return;
      }
      await _push(local, remote.revision);
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
    }
  }

  Future<bool> _isDirty() async =>
      await _db.getSetting('syncDirty') == 'true';

  Future<void> _setDirty(bool value) =>
      _db.setSetting('syncDirty', value.toString());

  Future<int> _getInt(String key) =>
      _db.getSetting(key).then((v) => int.tryParse(v ?? '') ?? 0);

  Future<void> _setInt(String key, int value) =>
      _db.setSetting(key, value.toString());

  Future<DateTime?> _getTime(String key) async {
    final raw = await _db.getSetting(key);
    return raw == null || raw.isEmpty ? null : DateTime.tryParse(raw);
  }

  /// Deterministic fingerprint of a snapshot's contents (excludes the
  /// payload wrapper's timestamp), used to detect no-op syncs. Hashing is
  /// CPU-heavy for large snapshots, so it runs off the UI thread.
  Future<String> _hashData(SyncSnapshotData data) async {
    final json = jsonEncode(data.toJson());
    return Isolate.run(() async {
      final hash = await Sha256().hash(utf8.encode(json));
      return base64Encode(hash.bytes);
    });
  }

  /// Decrypts a server snapshot off the UI thread.
  Future<String> _decryptRemote(String blob) async {
    final keyBytes = await _key!.extractBytes();
    return Isolate.run(
      () => SyncCrypto.decryptString(blob, SecretKey(keyBytes)),
    );
  }

  Future<void> _setSetting(String key, String value) =>
      _db.setSetting(key, value);

  DateTime _maxTime(DateTime? a, DateTime b) =>
      a != null && a.isAfter(b) ? a : b;

  String _friendlyError(Object e) {
    if (e is SyncApiException) return e.message;
    if (e is TimeoutException) return 'Connection timed out';
    if (e.toString().contains('SocketException')) {
      return 'Cannot reach the sync server';
    }
    return e.toString();
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncState>(SyncController.new);
