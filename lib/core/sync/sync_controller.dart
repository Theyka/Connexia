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

enum SyncStatus { signedOut, signedIn }

const String defaultSyncServerUrl = 'https://sync.connexia.run/';

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

  final bool pendingVerification;

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

class SyncController extends Notifier<SyncState> {
  static const _tokenKey = 'connexia_sync_token';
  static const _keyKey = 'connexia_sync_key';
  static const _accountKey = 'connexia_sync_account';
  static const _hashKey = 'syncLastPayloadHash';
  static const _vaultKeySetting = 'vaultMasterKey';

  String? _token;
  SecretKey? _key;
  bool _importing = false;
  Timer? _pushTimer;

  static const Duration syncPollInterval = Duration(seconds: 30);

  Timer? _syncTimer;
  DateTime _suppressEmissionsUntil = DateTime.fromMillisecondsSinceEpoch(0);

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

    ref.listen(watchTunnelsProvider, (_, _) => _onLocalDataChange());
    return const SyncState();
  }

  void setServerUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    state = state.copyWith(serverUrl: trimmed, error: null);
    if (state.status == SyncStatus.signedOut) {
      _db.setSetting('syncServerUrl', trimmed);
    }
  }

  Future<void> _loadSession() async {
    var url = await _db.getSetting('syncServerUrl') ?? '';
    var email = await _db.getSetting('syncEmail');
    var userId = await _db.getSetting('syncUserId');
    final revision =
        int.tryParse(await _db.getSetting('syncRevision') ?? '') ?? 0;
    _token = await _storage.read(_tokenKey);
    final wrapped = await _storage.read(_keyKey);
    if (email == null || userId == null || url.isEmpty) {
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
      if (email == null && userId == null) {
        if (url.isEmpty) url = defaultSyncServerUrl;
        state = SyncState(serverUrl: url);
        return;
      }

      await _clearSessionMeta();
      state = SyncState(serverUrl: url);
      return;
    }
    try {
      final clear = await _vault.decrypt(wrapped);
      _key = SecretKey(base64Decode(clear));
    } catch (_) {
      await _clearSessionMeta();
      return;
    }

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
    _startSyncTimer();

    Future.delayed(
      const Duration(milliseconds: 1200),
      () => _serialize(_reconcile),
    );
  }

  bool get _signedIn => state.status == SyncStatus.signedIn && _key != null;

  String get _effectiveServerUrl {
    final url = state.serverUrl.trim();
    return url.isEmpty ? defaultSyncServerUrl : url;
  }

  String get serverUrl => _effectiveServerUrl;

  String? get token => _token;

  SecretKey? get syncKey => _key;

  SyncApi _api() => SyncApi(serverUrl: _effectiveServerUrl, token: _token);

  String? _pendingEmail;
  String? _pendingPassword;
  String? _challengeToken;

  Future<void> register(String email, String password) async {
    final address = email.trim();
    if (state.busy) return;
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

  Future<void> login(String email, String password) async {
    final address = email.trim();
    if (state.busy) return;
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
        'url': _effectiveServerUrl,
        'email': email.trim().toLowerCase(),
        'userId': userId,
      }),
    );
    await _db.setSetting('syncServerUrl', _effectiveServerUrl);
    await _db.setSetting('syncEmail', email.trim().toLowerCase());
    await _db.setSetting('syncUserId', userId);
    _pendingEmail = null;
    _pendingPassword = null;
    _challengeToken = null;
    state = SyncState(
      status: SyncStatus.signedIn,
      serverUrl: _effectiveServerUrl,
      email: email.trim().toLowerCase(),
      userId: userId,
    );
    _loadAccountInfo();
    _startSyncTimer();
    await _serialize(_reconcile);
  }

  Future<void> _loadAccountInfo() async {
    try {
      final info = await _api().fetchAccount();
      state = state.copyWith(
        emailVerified: info.emailVerified,
        totpEnabled: info.totpEnabled,
      );
    } catch (_) {}
  }

  Future<(String secret, String otpauthUrl)?> enable2fa() async {
    if (!_signedIn) return null;
    try {
      return await _api().enable2fa();
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
      return null;
    }
  }

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

  Future<bool> signOut({bool force = false}) async {
    if (!force && _signedIn && state.serverUrl.isNotEmpty) {
      if (!await _api().checkHealth()) return false;
    }
    await _clearLocalSession();
    return true;
  }

  Future<bool> deleteAccount() async {
    if (!_signedIn) return false;
    try {
      await _api().deleteAccount();
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
      return false;
    }
    await _clearLocalSession();
    return true;
  }

  Future<void> _clearLocalSession() async {
    _pushTimer?.cancel();
    _syncTimer?.cancel();
    await _storage.delete(_tokenKey);
    await _storage.delete(_keyKey);
    await _storage.delete(_accountKey);
    await _clearSessionMeta();
    _token = null;
    _key = null;
    state = const SyncState();
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(syncPollInterval, (_) {
      if (_signedIn) _serialize(_reconcile);
    });
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

  Future<void> _seedVaultKey() async {
    if (await _db.getSetting(_vaultKeySetting) != null) return;
    final key = await _vault.exportKey();
    if (key == null) return;
    await _db.setSetting(_vaultKeySetting, key);
  }

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
          HostsCompanion(id: Value(host.id), encryptedPassword: Value(blob)),
        );
      }
    }
    for (final group in await _db.allGroups()) {
      final blob = await reencrypt(group.encryptedPassword);
      if (blob != group.encryptedPassword) {
        await _db.upsertGroup(
          GroupsCompanion(id: Value(group.id), encryptedPassword: Value(blob)),
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

    final key = _key;
    if (key != null) {
      final bytes = await key.extractBytes();
      await _storage.write(_keyKey, await _vault.encrypt(base64Encode(bytes)));
    }
  }

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

    await _seedVaultKey();
    final local = await exportSnapshot(_db);
    final localRev = await _getInt('syncRevision');
    final remote = await _api().fetchSnapshot();

    if (remote.revision == localRev) {
      if (await _isDirty()) {
        await _push(local, remote.revision);
      } else if (remote.blob == null || remote.updatedAt == null) {
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
        await _setSetting(
          'syncLastPulledAt',
          remote.updatedAt!.toIso8601String(),
        );
        state = state.copyWith(
          lastSyncedAt: remote.updatedAt,
          revision: remote.revision,
          pendingSync: false,
          error: null,
        );
      }
      return;
    }

    if (remote.blob == null || remote.revision == 0) {
      if (!local.isEmpty) {
        await _push(local, 0);
      } else {
        await _setInt('syncRevision', 0);
        await _setDirty(false);
        state = state.copyWith(revision: 0, pendingSync: false, error: null);
      }
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
      if (unchanged) {
        await _setInt('syncRevision', remote.revision);
        await _setSetting(
          'syncLastPulledAt',
          remote.updatedAt?.toIso8601String() ?? '',
        );
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
  }

  Future<void> _import(SyncSnapshotData data, SyncSnapshot fetchResult) async {
    _importing = true;
    try {
      await importSnapshot(_db, data);
      await ref.read(settingsControllerProvider).load();
    } finally {
      _importing = false;
    }

    await _adoptVaultKeyIfNeeded();
    await _setInt('syncRevision', fetchResult.revision);
    await _setSetting(
      'syncLastPulledAt',
      fetchResult.updatedAt?.toIso8601String() ?? '',
    );
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

    final encrypted = await Isolate.run(
      () => SyncCrypto.encryptString(encoded, SecretKey(keyBytes)),
    );
    try {
      await _api().pushSnapshot(baseRevision, encrypted);
    } on SyncApiException catch (e) {
      if (e.statusCode == 409) {
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
    if (!_signedIn || _importing) return;

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
        await _setDirty(false);
        state = state.copyWith(pendingSync: false, error: null);
        return;
      }
      await _push(local, remote.revision);
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
    }
  }

  Future<bool> _isDirty() async => await _db.getSetting('syncDirty') == 'true';

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

  Future<String> _hashData(SyncSnapshotData data) async {
    final json = jsonEncode(data.toJson());
    return Isolate.run(() async {
      final hash = await Sha256().hash(utf8.encode(json));
      return base64Encode(hash.bytes);
    });
  }

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

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);
