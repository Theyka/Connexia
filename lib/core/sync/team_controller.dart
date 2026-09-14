import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/state/providers.dart';
import '../db/database.dart';
import 'snapshot.dart';
import 'sync_api.dart';
import 'sync_controller.dart';
import 'sync_crypto.dart';
import 'team_crypto.dart';

class TeamState {
  final bool signedIn;

  final bool hasKey;

  final List<WorkspaceSummary> workspaces;

  final String? activeWorkspaceId;

  final Map<String, TeamSyncMeta> syncMeta;

  final bool busy;

  final bool syncing;

  final String? error;

  const TeamState({
    this.signedIn = false,
    this.hasKey = false,
    this.workspaces = const [],
    this.activeWorkspaceId,
    this.syncMeta = const {},
    this.busy = false,
    this.syncing = false,
    this.error,
  });

  TeamState copyWith({
    bool? signedIn,
    bool? hasKey,
    List<WorkspaceSummary>? workspaces,
    String? activeWorkspaceId,
    bool clearActive = false,
    Map<String, TeamSyncMeta>? syncMeta,
    bool? busy,
    bool? syncing,
    String? error,
    bool clearError = false,
  }) {
    return TeamState(
      signedIn: signedIn ?? this.signedIn,
      hasKey: hasKey ?? this.hasKey,
      workspaces: workspaces ?? this.workspaces,
      activeWorkspaceId: clearActive
          ? null
          : (activeWorkspaceId ?? this.activeWorkspaceId),
      syncMeta: syncMeta ?? this.syncMeta,
      busy: busy ?? this.busy,
      syncing: syncing ?? this.syncing,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class TeamSyncMeta {
  final int revision;
  final String lastPushedHash;
  final bool dirty;
  final DateTime? lastSyncedAt;

  final Set<String> hostIds;
  final Set<String> groupIds;
  final Set<String> identityIds;
  final Set<String> snippetIds;

  const TeamSyncMeta({
    this.revision = 0,
    this.lastPushedHash = '',
    this.dirty = false,
    this.lastSyncedAt,
    this.hostIds = const {},
    this.groupIds = const {},
    this.identityIds = const {},
    this.snippetIds = const {},
  });

  TeamSyncMeta copyWith({
    int? revision,
    String? lastPushedHash,
    bool? dirty,
    DateTime? lastSyncedAt,
    Set<String>? hostIds,
    Set<String>? groupIds,
    Set<String>? identityIds,
    Set<String>? snippetIds,
  }) {
    return TeamSyncMeta(
      revision: revision ?? this.revision,
      lastPushedHash: lastPushedHash ?? this.lastPushedHash,
      dirty: dirty ?? this.dirty,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      hostIds: hostIds ?? this.hostIds,
      groupIds: groupIds ?? this.groupIds,
      identityIds: identityIds ?? this.identityIds,
      snippetIds: snippetIds ?? this.snippetIds,
    );
  }
}

class TeamController extends Notifier<TeamState> {
  AppDatabase get _db => ref.read(appDatabaseProvider);

  SimpleKeyPair? _keyPair;
  String? _privateKeyB64;
  String? _publicKeyB64;

  final Map<String, SecretKey> _workspaceKeys = {};

  final Map<String, Future<void>> _syncQueues = {};

  DateTime _suppressDirtyUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  TeamState build() {
    ref.listen(syncControllerProvider, (_, next) {
      if (next.status == SyncStatus.signedIn) {
        if (!state.signedIn) {
          _onSignedIn();
        }
      } else {
        if (state.signedIn) {
          _onSignedOut();
        }
      }
    });

    ref.listen(hostsProvider, (_, _) => _onPossibleWorkspaceChange());
    ref.listen(groupsProvider, (_, _) => _onPossibleWorkspaceChange());
    ref.listen(identitiesProvider, (_, _) => _onPossibleWorkspaceChange());
    ref.listen(snippetsProvider, (_, _) => _onPossibleWorkspaceChange());
    ref.listen(watchTunnelsProvider, (_, _) => _onPossibleWorkspaceChange());
    return const TeamState();
  }

  void _onPossibleWorkspaceChange() {
    final ws = ref.read(activeWorkspaceIdProvider);
    if (ws == null || ws.isEmpty) return;
    if (DateTime.now().isBefore(_suppressDirtyUntil)) return;
    markDirty(ws);
  }

  void _onSignedIn() {
    state = state.copyWith(signedIn: true, clearError: true);
    _bootstrap();
  }

  void _onSignedOut() {
    _keyPair = null;
    _privateKeyB64 = null;
    _publicKeyB64 = null;
    _workspaceKeys.clear();
    _syncQueues.clear();
    state = const TeamState();
  }

  Future<void> _bootstrap() async {
    try {
      await _ensureKeypair();
      await refreshWorkspaces();
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
    }
  }

  Future<void> _ensureKeypair() async {
    final api = _api();
    final existing = await api.getUserKey();
    if (existing.hasKey && existing.publicKey != null) {
      _publicKeyB64 = existing.publicKey;

      if (_privateKeyB64 == null) {
        await _loadPrivateKeyFromServer();
      }
      state = state.copyWith(hasKey: true);
      return;
    }

    final syncKey = _syncKey();
    if (syncKey == null) return;
    final kp = await TeamCrypto.generateKeypair();
    final wrapped = await TeamCrypto.wrapPrivateKeyForStorage(
      kp.privateKey,
      syncKey,
    );
    await api.setUserKey(publicKey: kp.publicKey, wrappedPrivateKey: wrapped);
    _publicKeyB64 = kp.publicKey;
    _privateKeyB64 = kp.privateKey;
    await _writeCachedPrivateKey(kp.privateKey);
    await _rebuildKeyPair();
    state = state.copyWith(hasKey: true);
  }

  Future<void> _loadPrivateKeyFromServer() async {
    final stored = await _readCachedPrivateKey();
    if (stored != null) {
      _privateKeyB64 = stored;
      await _rebuildKeyPair();
    }
  }

  Future<String?> _readCachedPrivateKey() async {
    final storage = ref.read(secretStorageProvider);
    return storage.read('connexia_team_private_key');
  }

  Future<void> _writeCachedPrivateKey(String b64) async {
    final storage = ref.read(secretStorageProvider);
    await storage.write('connexia_team_private_key', b64);
  }

  Future<void> _rebuildKeyPair() async {
    final pk = _privateKeyB64;
    if (pk == null) return;
    final x = X25519();
    _keyPair = await x.newKeyPairFromSeed(base64Decode(pk));
  }

  SyncApi _api() {
    final sync = ref.read(syncControllerProvider.notifier);
    return SyncApi(
      serverUrl: sync.serverUrl.isEmpty ? defaultSyncServerUrl : sync.serverUrl,
      token: sync.token,
    );
  }

  SecretKey? _syncKey() {
    return ref.read(syncControllerProvider.notifier).syncKey;
  }

  Future<void> refreshWorkspaces() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final list = await _api().listWorkspaces();
      list.sort((a, b) => a.name.compareTo(b.name));
      state = state.copyWith(workspaces: list, busy: false);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  Future<void> createWorkspace(String name) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _ensureKeypair();
      final syncKey = _syncKey();
      if (syncKey == null || _keyPair == null || _publicKeyB64 == null) {
        throw StateError('not signed in');
      }
      final wsKey = TeamCrypto.generateWorkspaceKey();
      final shared = await TeamCrypto.sharedSecret(
        keyPair: _keyPair!,
        remotePublicKeyB64: _publicKeyB64!,
      );
      final wrapped = await TeamCrypto.wrapWorkspaceKey(
        workspaceKeyB64: wsKey,
        shared: shared,
      );
      final created = await _api().createWorkspace(
        name: name,
        wrappedKey: wrapped,
      );
      _workspaceKeys[created.id] = SecretKey(base64Decode(wsKey));
      await refreshWorkspaces();
      state = state.copyWith(activeWorkspaceId: created.id, busy: false);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  Future<void> setActiveWorkspace(String? id) async {
    state = state.copyWith(
      activeWorkspaceId: id,
      clearActive: id == null,
      clearError: true,
    );
    if (id != null) {
      await syncWorkspace(id);
    }
  }

  Future<void> deleteWorkspace(String id) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _api().deleteWorkspace(id);
      _workspaceKeys.remove(id);
      _syncQueues.remove(id);
      final newMeta = Map<String, TeamSyncMeta>.from(state.syncMeta)
        ..remove(id);
      final newList = state.workspaces.where((w) => w.id != id).toList();
      state = state.copyWith(
        workspaces: newList,
        syncMeta: newMeta,
        activeWorkspaceId: state.activeWorkspaceId == id
            ? null
            : state.activeWorkspaceId,
        clearActive: state.activeWorkspaceId == id,
        busy: false,
      );
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  Future<({String userId, String publicKey, String email})?> invite(
    String workspaceId,
    String email,
  ) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final r = await _api().invite(workspaceId, email);
      state = state.copyWith(busy: false);
      return r;
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
      return null;
    }
  }

  Future<bool> addMember({
    required String workspaceId,
    required String userId,
    required String publicKey,
    required String role,
  }) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _ensureKeypair();
      final wsKey = await _unlockWorkspaceKey(workspaceId);
      if (wsKey == null || _keyPair == null) {
        throw StateError('cannot unlock workspace key');
      }
      final shared = await TeamCrypto.sharedSecret(
        keyPair: _keyPair!,
        remotePublicKeyB64: publicKey,
      );
      final wrapped = await TeamCrypto.wrapWorkspaceKey(
        workspaceKeyB64: base64Encode(await wsKey.extractBytes()),
        shared: shared,
      );
      await _api().addMember(
        workspaceId,
        userId,
        role: role,
        wrappedKey: wrapped,
      );
      state = state.copyWith(busy: false);
      return true;
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
      return false;
    }
  }

  Future<void> setMemberRole(
    String workspaceId,
    String userId,
    String role,
  ) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _api().setMemberRole(workspaceId, userId, role);
      state = state.copyWith(busy: false);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  Future<void> removeMember(String workspaceId, String userId) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _api().removeMember(workspaceId, userId);
      state = state.copyWith(busy: false);
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
    }
  }

  Future<bool> rotateWorkspaceKey(
    String workspaceId,
    List<WorkspaceMember> members,
  ) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _ensureKeypair();
      final oldKey = await _unlockWorkspaceKey(workspaceId);
      if (oldKey == null || _keyPair == null) {
        throw StateError('cannot unlock workspace key');
      }

      final newWsKeyB64 = TeamCrypto.generateWorkspaceKey();
      final newKey = SecretKey(base64Decode(newWsKeyB64));
      final local = await exportWorkspaceSnapshot(_db, workspaceId);
      final payload = buildPayload(local, modifiedAt: DateTime.now());
      final encoded = payload.encode();
      final oldKeyBytes = await oldKey.extractBytes();
      final reEncrypted = await Isolate.run(
        () => SyncCrypto.encryptString(encoded, SecretKey(oldKeyBytes)),
      );

      final decoded = await Isolate.run(
        () => SyncCrypto.decryptString(reEncrypted, SecretKey(oldKeyBytes)),
      );
      final newEncrypted = await Isolate.run(
        () => SyncCrypto.encryptString(decoded, newKey),
      );

      final newMembers = <({String userId, String role, String wrappedKey})>[];
      for (final m in members) {
        final pk = m.publicKey;
        if (pk == null) continue;
        final shared = await TeamCrypto.sharedSecret(
          keyPair: _keyPair!,
          remotePublicKeyB64: pk,
        );
        final wrapped = await TeamCrypto.wrapWorkspaceKey(
          workspaceKeyB64: newWsKeyB64,
          shared: shared,
        );
        newMembers.add((userId: m.userId, role: m.role, wrappedKey: wrapped));
      }

      final meta = state.syncMeta[workspaceId] ?? const TeamSyncMeta();
      await _api().pushWorkspaceSnapshot(
        workspaceId,
        meta.revision,
        newEncrypted,
      );
      await _api().keyRotate(workspaceId, newMembers);

      _workspaceKeys[workspaceId] = newKey;
      final newMeta = Map<String, TeamSyncMeta>.from(state.syncMeta);
      newMeta[workspaceId] = meta.copyWith(
        revision: meta.revision + 1,
        dirty: false,
        lastSyncedAt: DateTime.now(),
        lastPushedHash: '',
        hostIds: local.hosts.map((e) => e['id'] as String).toSet(),
        groupIds: local.groups.map((e) => e['id'] as String).toSet(),
        identityIds: local.identities.map((e) => e['id'] as String).toSet(),
        snippetIds: local.snippets.map((e) => e['id'] as String).toSet(),
      );
      state = state.copyWith(syncMeta: newMeta, busy: false);
      return true;
    } catch (e) {
      state = state.copyWith(busy: false, error: _friendlyError(e));
      return false;
    }
  }

  Future<SecretKey?> _unlockWorkspaceKey(String workspaceId) async {
    final cached = _workspaceKeys[workspaceId];
    if (cached != null) return cached;
    await _ensureKeypair();
    if (_keyPair == null) return null;
    final detail = await _api().getWorkspace(workspaceId);
    final me = detail.members.firstWhere(
      (m) => m.wrappedKey != null && m.wrappedKey!.isNotEmpty,
      orElse: () => const WorkspaceMember(userId: '', email: '', role: ''),
    );
    if (me.wrappedKey == null) return null;
    final shared = await TeamCrypto.sharedSecret(
      keyPair: _keyPair!,
      remotePublicKeyB64: detail.members
          .firstWhere((m) => m.userId == me.userId)
          .publicKey!,
    );
    final wsKeyB64 = await TeamCrypto.unwrapWorkspaceKey(
      wrappedWorkspaceKey: me.wrappedKey!,
      shared: shared,
    );
    final key = SecretKey(base64Decode(wsKeyB64));
    _workspaceKeys[workspaceId] = key;
    return key;
  }

  Future<void> syncWorkspace(String workspaceId) async {
    final existing = _syncQueues[workspaceId] ?? Future.value();
    final next = existing.then((_) => _doSync(workspaceId));
    _syncQueues[workspaceId] = next.catchError((_) {}).then((_) {});
    return next;
  }

  Future<void> _doSync(String workspaceId) async {
    state = state.copyWith(syncing: true, clearError: true);
    try {
      final key = await _unlockWorkspaceKey(workspaceId);
      if (key == null) {
        throw StateError('cannot unlock workspace key');
      }
      final api = _api();
      final local = await exportWorkspaceSnapshot(_db, workspaceId);
      final meta = state.syncMeta[workspaceId] ?? const TeamSyncMeta();
      final remote = await api.fetchWorkspaceSnapshot(workspaceId);

      if (remote.revision == meta.revision) {
        if (meta.dirty) {
          final hash = await _hashData(local);
          if (hash == meta.lastPushedHash) {
            _setMeta(workspaceId, meta.copyWith(dirty: false));
          } else {
            await _pushWorkspace(workspaceId, key, local, remote.revision);
          }
        }
        state = state.copyWith(syncing: false);
        return;
      }
      if (remote.blob == null || remote.revision == 0) {
        if (!local.isEmpty) {
          await _pushWorkspace(workspaceId, key, local, 0);
        } else {
          _setMeta(workspaceId, meta.copyWith(revision: 0, dirty: false));
        }
        state = state.copyWith(syncing: false);
        return;
      }
      final remotePayload = SyncPayload.decode(
        await _decryptRemote(remote.blob!, key),
      );
      final remoteModified = remote.updatedAt ?? remotePayload.modifiedAt;
      if (!meta.dirty) {
        await _importWorkspace(workspaceId, remotePayload.data, remote);
      } else {
        if (remoteModified.isAfter(local.modifiedAt)) {
          await _importWorkspace(workspaceId, remotePayload.data, remote);
        } else {
          await _pushWorkspace(workspaceId, key, local, remote.revision);
        }
      }
      state = state.copyWith(syncing: false);
    } catch (e) {
      state = state.copyWith(syncing: false, error: _friendlyError(e));
    }
  }

  Future<void> _pushWorkspace(
    String workspaceId,
    SecretKey key,
    SyncSnapshotData data,
    int baseRevision,
  ) async {
    final payload = buildPayload(data, modifiedAt: DateTime.now());
    final encoded = payload.encode();
    final keyBytes = await key.extractBytes();
    final encrypted = await Isolate.run(
      () => SyncCrypto.encryptString(encoded, SecretKey(keyBytes)),
    );

    final meta = state.syncMeta[workspaceId] ?? const TeamSyncMeta();
    final actions = _diffActions(meta, data);

    try {
      await _api().pushWorkspaceSnapshot(
        workspaceId,
        baseRevision,
        encrypted,
        actions: actions,
      );
    } on SyncApiException catch (e) {
      if (e.statusCode == 409) {
        await _doSync(workspaceId);
        return;
      }
      rethrow;
    }

    final hash = await _hashData(data);
    _setMeta(
      workspaceId,
      meta.copyWith(
        revision: baseRevision + 1,
        lastPushedHash: hash,
        dirty: false,
        lastSyncedAt: DateTime.now(),
        hostIds: data.hosts.map((e) => e['id'] as String).toSet(),
        groupIds: data.groups.map((e) => e['id'] as String).toSet(),
        identityIds: data.identities.map((e) => e['id'] as String).toSet(),
        snippetIds: data.snippets.map((e) => e['id'] as String).toSet(),
      ),
    );
  }

  Future<void> _importWorkspace(
    String workspaceId,
    SyncSnapshotData data,
    SyncSnapshot fetch,
  ) async {
    _suppressDirtyUntil = DateTime.now().add(const Duration(seconds: 2));
    await importWorkspaceSnapshot(_db, workspaceId, data);
    final meta = state.syncMeta[workspaceId] ?? const TeamSyncMeta();
    _setMeta(
      workspaceId,
      meta.copyWith(
        revision: fetch.revision,
        dirty: false,
        lastSyncedAt: fetch.updatedAt,
        hostIds: data.hosts.map((e) => e['id'] as String).toSet(),
        groupIds: data.groups.map((e) => e['id'] as String).toSet(),
        identityIds: data.identities.map((e) => e['id'] as String).toSet(),
        snippetIds: data.snippets.map((e) => e['id'] as String).toSet(),
      ),
    );
  }

  void _setMeta(String id, TeamSyncMeta meta) {
    final newMeta = Map<String, TeamSyncMeta>.from(state.syncMeta);
    newMeta[id] = meta;
    state = state.copyWith(syncMeta: newMeta);
  }

  void markDirty(String workspaceId) {
    if (DateTime.now().isBefore(_suppressDirtyUntil)) return;
    final meta = state.syncMeta[workspaceId] ?? const TeamSyncMeta();
    _setMeta(workspaceId, meta.copyWith(dirty: true));
  }

  Future<List<AuditEvent>> fetchAudit(String workspaceId) async {
    try {
      return await _api().auditEvents(workspaceId);
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e));
      return const [];
    }
  }

  List<({String action, String target})> _diffActions(
    TeamSyncMeta prev,
    SyncSnapshotData curr,
  ) {
    final actions = <({String action, String target})>[];
    final prevHosts = prev.hostIds;
    final currHosts = {for (final h in curr.hosts) h['id'] as String};
    for (final id in currHosts.difference(prevHosts)) {
      actions.add((action: 'host.create', target: id));
    }
    for (final id in prevHosts.difference(currHosts)) {
      actions.add((action: 'host.delete', target: id));
    }
    final prevGroups = prev.groupIds;
    final currGroups = {for (final g in curr.groups) g['id'] as String};
    for (final id in currGroups.difference(prevGroups)) {
      actions.add((action: 'group.create', target: id));
    }
    for (final id in prevGroups.difference(currGroups)) {
      actions.add((action: 'group.delete', target: id));
    }
    final prevIdentities = prev.identityIds;
    final currIdentities = {for (final i in curr.identities) i['id'] as String};
    for (final id in currIdentities.difference(prevIdentities)) {
      actions.add((action: 'key.create', target: id));
    }
    for (final id in prevIdentities.difference(currIdentities)) {
      actions.add((action: 'key.delete', target: id));
    }
    final prevSnippets = prev.snippetIds;
    final currSnippets = {for (final s in curr.snippets) s['id'] as String};
    for (final id in currSnippets.difference(prevSnippets)) {
      actions.add((action: 'snippet.create', target: id));
    }
    for (final id in prevSnippets.difference(currSnippets)) {
      actions.add((action: 'snippet.delete', target: id));
    }
    return actions;
  }

  Future<String> _hashData(SyncSnapshotData data) async {
    final json = jsonEncode(data.toJson());
    return Isolate.run(() async {
      final hash = await Sha256().hash(utf8.encode(json));
      return base64Encode(hash.bytes);
    });
  }

  Future<String> _decryptRemote(String blob, SecretKey key) async {
    final keyBytes = await key.extractBytes();
    return Isolate.run(
      () => SyncCrypto.decryptString(blob, SecretKey(keyBytes)),
    );
  }

  String _friendlyError(Object e) {
    if (e is SyncApiException) return e.message;
    return e.toString();
  }
}

final teamControllerProvider = NotifierProvider<TeamController, TeamState>(
  TeamController.new,
);

final activeWorkspaceIdProvider = Provider<String?>((ref) {
  return ref.watch(teamControllerProvider).activeWorkspaceId;
});
